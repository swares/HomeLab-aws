#!/usr/bin/env bash
#
# Print the AWS break-glass envelope: docs/BREAK-GLASS.md plus a table of the
# actual credentials, rendered to PDF and sent to the default printer.
#
# THIS SCRIPT HANDLES SECRETS. Design rules, all of which have a reason — most
# of them learned the hard way in the lab's print-offline-envelope.sh, which
# this deliberately mirrors:
#
#   - SECRETS ARE PROMPTED FOR, NEVER READ FROM DISK OR AN API. This is the one
#     rule that differs from the lab script, and it is not a style choice: AWS
#     exposes no API that returns a root password, an MFA seed, or a security
#     answer. There is nothing to harvest. Any future "improvement" that reads
#     these from a file is creating the at-rest copy this envelope exists to
#     avoid. Prompt, render, shred.
#
#   - Nothing is echoed. `read -s` throughout, so no value reaches the
#     terminal, the scrollback, or a session log. Values are never passed as
#     command-line arguments either, where `ps` would expose them.
#
#   - Everything renders under TMPDIR on /dev/shm (tmpfs), so no intermediate
#     touches persistent storage. xelatex writes several MB of temp files;
#     without this they land on disk, where rm and shred cannot reliably erase
#     them on flash because of wear levelling.
#
#   - The CUPS spool is purged AFTER the queue drains. Purging before the job
#     prints would instead cancel it — clean spool, no paper. (Lab lesson,
#     2026-08-15: twenty rendered copies sat in /var/spool/cups for fifteen
#     hours.)
#
#   - Manual steps are printed at the end because the script cannot shred paper
#     or power-cycle a printer, and those are the copies that need no root to
#     read.
#
# RESIDUAL RISK, stated plainly: /dev/shm is tmpfs and tmpfs CAN be swapped. On
# a host with unencrypted swap a rendered page could reach disk. Run this on a
# machine with encrypted swap or none. Bash cannot mlock its memory, so this is
# a property of where you run it, not something the script can fix.
#
# Usage:  ./scripts/print-aws-envelope.sh [-d printer] [--dry-run] [--no-purge]
#
#   --dry-run    render and report size, print nothing, purge nothing. Use this
#                when editing the layout so you are not producing paper drafts.
#                Still prompts, so you can rehearse the fill.
#   --no-purge   print but leave the CUPS spool alone (for a local printer you
#                will power-cycle by hand).

set -euo pipefail

PRINTER=""
DRY_RUN=0
NO_PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d) PRINTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-purge) NO_PURGE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DOC="$SCRIPT_DIR/../docs/BREAK-GLASS.md"
[ -r "$DOC" ] || { echo "FATAL: cannot read $DOC" >&2; exit 1; }
command -v pandoc >/dev/null || { echo "FATAL: pandoc not installed" >&2; exit 1; }

# ---- tmpfs workspace, shredded on every exit path ---------------------------
[ -d /dev/shm ] || { echo "FATAL: /dev/shm unavailable; refusing to render to disk" >&2; exit 1; }
WORKDIR=$(mktemp -d /dev/shm/aws-envelope.XXXXXX)
chmod 700 "$WORKDIR"
cleanup_workdir() {
  find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup_workdir EXIT INT TERM
export TMPDIR="$WORKDIR"     # pandoc and xelatex inherit this

# ---- Prompting --------------------------------------------------------------
# Every value is optional. An empty answer leaves a ruled blank on the form to
# fill in by hand — better than a wrong value, and better than omitting the row,
# because a missing row is invisible during a drill.

BLANK='\rule{6cm}{0.4pt}'

ask() {            # ask <varname> <prompt>  — single line, not echoed
  local __var="$1" __prompt="$2" __val
  read -r -s -p "  ${__prompt}: " __val </dev/tty; echo
  printf -v "$__var" '%s' "$__val"
}

ask_multi() {      # ask_multi <varname> <prompt> — until a blank line
  local __var="$1" __prompt="$2" __line __acc=""
  echo "  ${__prompt}"
  echo "    (one per line; empty line to finish; input is not echoed)"
  while IFS= read -r -s __line </dev/tty; do
    [ -z "$__line" ] && break
    __acc+="${__line}\\newline "
    echo "    + entry recorded"
  done
  printf -v "$__var" '%s' "$__acc"
}

cell() {           # cell <value> — the value in code style, or a ruled blank
  if [ -z "${1:-}" ]; then printf '%s' "$BLANK"; else printf '`%s`' "$1"; fi
}

cat <<'INTRO'

  AWS break-glass envelope
  ------------------------
  Nothing you type is echoed, logged, or written to disk outside /dev/shm.
  Press Enter to skip any item and leave a ruled blank to fill in by hand.

INTRO

ask       ACCOUNT_ID     "1  AWS account ID (12 digits)"
ask       ACCOUNT_ALIAS  "1  Account alias (blank if none set)"
ask       ROOT_EMAIL     "2  Root email address"
ask       ROOT_MAILBOX   "2  Which mailbox provider it lives in"
ask       ROOT_PASSWORD  "3  Root password"
ask       ROOT_MFA_SEED  "4  Root MFA secret, base32 — THE critical one"
ask_multi ROOT_MFA_CODES "4  Root MFA recovery codes (if you have these instead)"
ask       ACCT_PHONE     "5  Phone number registered on the account"
ask_multi SEC_QA         "6  Security challenge Q&A (format: question = answer)"
ask       BG_USER        "7  Break-glass IAM username"
ask       BG_PASSWORD    "7  Break-glass IAM console password"
ask       BG_MFA_SEED    "7  Break-glass IAM MFA secret (base32)"
ask       TEARDOWN_AKID  "8  Teardown access key ID (AKIA...)"
ask       TEARDOWN_SAK   "8  Teardown secret access key"
ask       PM_RECOVERY    "9  Password manager recovery kit / emergency code"

# ---- Sanity checks on the values most likely to be wrong --------------------
# These never print the value. They print a judgement about it.

warn() { printf '  WARN: %s\n' "$*" >&2; }

check_b32() {      # check_b32 <label> <value>
  local label="$1" v="${2:-}" stripped n
  [ -z "$v" ] && return 0
  stripped="${v// /}"
  if [[ ! "$stripped" =~ ^[A-Z2-7=]+$ ]]; then
    warn "$label does not look like base32 (expected A-Z and 2-7 only)."
    warn "      Lowercase, or 0/1/8/9, usually means a transcription error."
  fi
  n=${#stripped}
  if (( n % 8 != 0 )) || (( n < 16 )); then
    warn "$label is ${n} characters. AWS virtual MFA seeds are usually 32."
  fi
}

echo
check_b32 "Root MFA seed" "$ROOT_MFA_SEED"
check_b32 "Break-glass MFA seed" "$BG_MFA_SEED"

if [ -n "$ACCOUNT_ID" ] && [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  warn "Account ID is not 12 digits."
fi
if [ -n "$TEARDOWN_AKID" ] && [[ ! "$TEARDOWN_AKID" =~ ^AKIA[A-Z0-9]{16}$ ]]; then
  warn "Teardown access key ID does not match the AKIA... format."
fi

# ---- Verify the MFA seeds actually generate accepted codes ------------------
# The highest-value check here. A transcription error in a base32 seed is
# SILENT: it produces valid-looking six-digit codes that AWS rejects, and you
# discover it during the lockout this envelope exists for.
if command -v oathtool >/dev/null 2>&1; then
  for pair in "Root:${ROOT_MFA_SEED}" "Break-glass:${BG_MFA_SEED}"; do
    label="${pair%%:*}"; seed="${pair#*:}"
    [ -z "$seed" ] && continue
    if code=$(oathtool --totp --base32 "${seed// /}" 2>/dev/null); then
      echo
      echo "  ${label} MFA — compare against your authenticator app NOW:"
      echo "      ${code}"
      read -r -p "      Does it match? [y/N] " ans </dev/tty
      case "$ans" in
        [yY]*) echo "      confirmed." ;;
        *)     warn "${label} MFA seed did NOT verify. Re-check before printing." ;;
      esac
    else
      warn "${label} seed could not be parsed by oathtool — likely malformed."
    fi
  done
else
  echo
  echo "  NOTE: oathtool not installed, so MFA seeds were not verified."
  echo "        A base32 transcription error is silent until you need it."
  echo "        Install it (apt install oathtool) and re-run to check."
fi

# ---- Render -----------------------------------------------------------------
SIGNIN="https://${ACCOUNT_ALIAS:-${ACCOUNT_ID:-ACCOUNT-ID}}.signin.aws.amazon.com/console"

{
  cat "$DOC"
  cat <<EOF

\newpage

# FILLED VALUES — $(date +%F)

**This page is the secret. Everything before it is the template.**
Shred every draft. Store the keeper copy off the property.

| # | What | Value |
|---|------|-------|
| 1 | Account ID | $(cell "$ACCOUNT_ID") |
| 1 | Account alias | $(cell "$ACCOUNT_ALIAS") |
| 1 | IAM sign-in URL | \`${SIGNIN}\` |
| 2 | Root email | $(cell "$ROOT_EMAIL") |
| 2 | Mailbox provider | $(cell "$ROOT_MAILBOX") |
| 3 | Root password | $(cell "$ROOT_PASSWORD") |
| 4 | **Root MFA seed (base32)** | $(cell "$ROOT_MFA_SEED") |
| 4 | Root MFA recovery codes | ${ROOT_MFA_CODES:-$BLANK} |
| 5 | Registered phone | $(cell "$ACCT_PHONE") |
| 6 | Security Q&A | ${SEC_QA:-$BLANK} |
| 7 | Break-glass IAM user | $(cell "$BG_USER") |
| 7 | Break-glass password | $(cell "$BG_PASSWORD") |
| 7 | Break-glass MFA seed | $(cell "$BG_MFA_SEED") |
| 8 | Teardown access key ID | $(cell "$TEARDOWN_AKID") |
| 8 | Teardown secret key | $(cell "$TEARDOWN_SAK") |
| 9 | Password manager recovery | $(cell "$PM_RECOVERY") |

## Stop the billing first

From any machine, no AWS login required — the repo is public:

    git clone https://github.com/swares/HomeLab-aws.git
    cd HomeLab-aws
    export AWS_ACCESS_KEY_ID=<item 8>
    export AWS_SECRET_ACCESS_KEY=<item 8>
    export AWS_REGION=us-east-1
    make eks-down

Then work the lockout. That takes days; this takes fifteen minutes.
EOF
} > "$WORKDIR/envelope.md"

pandoc "$WORKDIR/envelope.md" \
  -o "$WORKDIR/envelope.pdf" \
  --metadata title="Break-glass envelope - AWS segment" \
  --metadata date="rendered $(date +%F)" \
  -V geometry:"top=2cm, bottom=2cm, left=2cm, right=2cm" \
  -V fontsize=10pt \
  -f markdown

if [ "$DRY_RUN" -eq 1 ]; then
  echo
  echo "  Dry run: rendered $(stat -c%s "$WORKDIR/envelope.pdf") bytes. Nothing printed."
  echo "  Workspace shredded on exit."
  exit 0
fi

# ---- Print ------------------------------------------------------------------
if [ -n "$PRINTER" ]; then lp -d "$PRINTER" "$WORKDIR/envelope.pdf"
else                       lp "$WORKDIR/envelope.pdf"
fi

# ---- Purge the spool, but only once the job has actually gone ---------------
wait_for_queue() {
  local waited=0 timeout=300
  while lpstat -o 2>/dev/null | grep -q .; do
    if [ "$waited" -ge "$timeout" ]; then
      echo "WARN: queue still busy after ${timeout}s - NOT purging." >&2
      echo "      Check 'lpstat -p -o'. The spool still holds your credentials;" >&2
      echo "      purge by hand once it clears." >&2
      return 1
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
}

purge_cups() {
  # cupsd keeps job state in memory and rewrites job.cache on shutdown, so stop
  # it first or the entries come straight back.
  sudo systemctl stop cups cups-browsed 2>/dev/null || true
  sudo rm -f /var/spool/cups/d* /var/spool/cups/c*
  sudo rm -rf /var/spool/cups/tmp/*
  sudo rm -f /var/cache/cups/job.cache /var/cache/cups/*.data
  sudo truncate -s 0 /var/log/cups/access_log /var/log/cups/error_log 2>/dev/null || true
  sudo systemctl start cups
}

if [ "$NO_PURGE" -eq 1 ]; then
  echo "--no-purge: spool left alone. It still holds your credentials."
else
  echo "Waiting for the print queue to drain..."
  if wait_for_queue; then
    purge_cups
    echo "CUPS spool, job cache and logs purged."
  fi
fi

cat <<'MANUAL'

────────────────────────────────────────────────────────────────────────
 MANUAL STEPS - the script cannot do these
────────────────────────────────────────────────────────────────────────

 1. SHRED every draft. Cross-cut or burn; strip-cut can be reassembled.
    The filled page is complete administrative control of the AWS account
    and it needs no root access to read.

 2. POWER-CYCLE THE PRINTER. Jobs are buffered in RAM. Check its web UI
    for secure-print or reprint storage while you are there.

 3. STORE IT OFF THE PROPERTY, with the lab envelope. They fail
    independently but you will want both in the same bad afternoon.

 4. VERIFY THE MFA SEED FROM PAPER, not from the screen. Type the printed
    base32 into a fresh authenticator entry and confirm AWS accepts a
    code. Checking against the source proves the source is right; the
    paper is the copy you will be holding. Base32 errors are silent.

 5. UPDATE THE CURRENCY TABLE in docs/BREAK-GLASS.md and commit THAT -
    the table, never the values. A stale envelope is worse than none,
    because you will trust it.

 6. RUN DRILL A within a week. From a machine with no AWS credentials and
    no browser session, use only this paper to tear down a running
    cluster. Untested, this is a guess.

 Note: rm and shred do not reliably erase flash storage - wear levelling
 may retain blocks regardless. That is why this renders in /dev/shm and
 never writes the document to disk. tmpfs can still be swapped, so run
 this on a host with encrypted swap or none.

 Editing the layout? Use --dry-run so you are not making paper drafts.
────────────────────────────────────────────────────────────────────────
MANUAL
