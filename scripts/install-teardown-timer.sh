#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install (or update) the nightly EKS teardown timer on n150-2.
#
#   sudo ./scripts/install-teardown-timer.sh
#
# Idempotent: safe to re-run after a repo change or to rotate the key.
#
# What it does, in order:
#   1. eks-teardown system user - no login shell, no real home.
#   2. AWS CLI v2 system-wide in /usr/local/bin, if missing. (The interactive
#      copy in ~swares/.local/bin is invisible to a system service.)
#   3. /opt/HomeLab-aws - a clean clone owned by eks-teardown, separate from
#      your working checkout so the timer never runs half-edited code.
#   4. /etc/eks-sandbox/teardown.env - PROMPTS for the lab-teardown access key
#      (not echoed, never an argv), writes it 0400 owned by eks-teardown.
#      Skipped if the file exists, unless --rotate-key.
#   5. Installs and enables the systemd units, then proves the credentials
#      work by running `aws sts get-caller-identity` AS the service user.
#
# What it does NOT do: create the IAM access key. That is by hand, on
# purpose, so the secret never enters tofu state:
#   aws iam create-access-key --user-name lab-teardown
# (RUNBOOK: "Teardown timer").
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_URL="https://github.com/swares/HomeLab-aws.git"
DEST=/opt/HomeLab-aws
SVC_USER=eks-teardown
ENV_DIR=/etc/eks-sandbox
ENV_FILE=$ENV_DIR/teardown.env
EXPECTED_USER_SUFFIX=":user/homelab-aws/lab-teardown"
ROTATE=0

[[ "${1:-}" = "--rotate-key" ]] && ROTATE=1
[[ "$(id -u)" -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
SRC_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

log() { printf '==> %s\n' "$*"; }

# --- 1. service user ---------------------------------------------------------
if ! id "$SVC_USER" >/dev/null 2>&1; then
  log "Creating system user $SVC_USER"
  useradd --system --user-group --no-create-home \
          --home-dir /var/lib/eks-teardown --shell /usr/sbin/nologin "$SVC_USER"
else
  log "User $SVC_USER exists"
fi
# The unit's StateDirectory creates this too, but only on first start; the
# credential check below runs before that.
install -d -o "$SVC_USER" -g "$SVC_USER" -m 0750 /var/lib/eks-teardown

# --- 2. AWS CLI v2, system-wide -------------------------------------------------
if [[ -x /usr/local/bin/aws ]] && /usr/local/bin/aws --version 2>&1 | grep -q '^aws-cli/2'; then
  log "AWS CLI v2 present: $(/usr/local/bin/aws --version 2>&1 | cut -d' ' -f1)"
else
  log "Installing AWS CLI v2 to /usr/local/bin"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  # --proto '=https': -L follows redirects, and without this a redirect to
  # plain http:// would be followed for a binary about to run as root.
  curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/awscliv2.zip" \
       https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  "$tmp/aws/install" --update --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
fi
for bin in tofu kubectl git; do
  command -v "$bin" >/dev/null || { echo "FATAL: $bin not on PATH" >&2; exit 1; }
done

# --- 3. the timer's own checkout ---------------------------------------------
if [[ -d "$DEST/.git" ]]; then
  log "Updating $DEST"
  # An earlier RUNBOOK revision cloned this as root and chowned it to a user
  # called "lab". Take ownership so the service can pull and run tofu init.
  chown -R "$SVC_USER:$SVC_USER" "$DEST"
  sudo -u "$SVC_USER" git -C "$DEST" pull --ff-only --quiet
else
  log "Cloning $REPO_URL to $DEST"
  install -d -o "$SVC_USER" -g "$SVC_USER" -m 0755 "$DEST"
  sudo -u "$SVC_USER" git clone --quiet "$REPO_URL" "$DEST"
fi
[[ -f "$DEST/tofu/.terraform.lock.hcl" ]] || {
  echo "FATAL: $DEST has no tofu/.terraform.lock.hcl - is main up to date?" >&2; exit 1; }

# --- 4. credentials ------------------------------------------------------------
install -d -o root -g "$SVC_USER" -m 0750 "$ENV_DIR"
if [[ -f "$ENV_FILE" ]] && [[ "$ROTATE" -eq 0 ]]; then
  log "$ENV_FILE exists (use --rotate-key to replace it)"
else
  log "Enter the lab-teardown access key. Input is not echoed."
  read -r -s -p "  Access key ID:     " AKID </dev/tty; echo
  read -r -s -p "  Secret access key: " SAK  </dev/tty; echo
  [[ "$AKID" =~ ^AKIA[A-Z0-9]{16}$ ]] || { echo "FATAL: that is not an AKIA... key ID" >&2; exit 1; }
  [[ "${#SAK}" -eq 40 ]] || { echo "FATAL: secret should be 40 characters" >&2; exit 1; }
  umask 077
  tmpenv=$(mktemp "$ENV_DIR/.teardown.env.XXXXXX")
  printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$AKID" "$SAK" > "$tmpenv"
  unset AKID SAK
  chown "$SVC_USER:$SVC_USER" "$tmpenv"; chmod 0400 "$tmpenv"
  mv -f "$tmpenv" "$ENV_FILE"
  log "Wrote $ENV_FILE (0400, $SVC_USER)"
fi

# --- 5. units -------------------------------------------------------------------
log "Installing systemd units"
install -m 0644 "$SRC_DIR/systemd/eks-teardown.service" /etc/systemd/system/
install -m 0644 "$SRC_DIR/systemd/eks-teardown.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now eks-teardown.timer >/dev/null

# --- prove the identity, as the service user, with the service's env ----------
log "Checking credentials as $SVC_USER"
arn=$(sudo -u "$SVC_USER" env -i PATH=/usr/local/bin:/usr/bin:/bin \
        AWS_EC2_METADATA_DISABLED=true HOME=/var/lib/eks-teardown \
        bash -c "set -a; . '$ENV_FILE'; aws sts get-caller-identity --query Arn --output text" 2>&1) || {
  echo "FATAL: credentials do not work: $arn" >&2; exit 1; }
case "$arn" in
  *"$EXPECTED_USER_SUFFIX") log "Authenticated as $arn" ;;
  *) echo "FATAL: key belongs to $arn, expected ...$EXPECTED_USER_SUFFIX" >&2
     echo "       The timer must never hold an admin key." >&2; exit 1 ;;
esac

echo
systemctl list-timers eks-teardown.timer --no-pager
cat <<'NEXT'

Installed. The key has only been proven to AUTHENTICATE. The only proof it can
TEAR DOWN is doing it (RUNBOOK "Teardown timer", verify step):
  make eks-up          # as yourself
  sudo systemctl start eks-teardown.service
  journalctl -u eks-teardown.service -f
NEXT
