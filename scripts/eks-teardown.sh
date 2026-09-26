#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Ordered teardown of the EKS sandbox.
#
# WHY THIS IS A SCRIPT AND NOT `tofu destroy`:
#
# Kubernetes controllers create AWS resources that OpenTofu has no record of.
# An Ingress managed by the AWS Load Balancer Controller creates an ALB, target
# groups and a security group; a Service type=LoadBalancer creates an NLB. Run
# `tofu destroy` while those objects still exist in the cluster and:
#
#   - the controller is deleted before it can clean up its own resources
#   - the load balancers and security groups are orphaned
#   - the VPC delete hangs (DependencyViolation) on ENIs tofu cannot see
#   - you clean it up by hand, while paying for it
#
# So: delete the Kubernetes objects first, WAIT for the controller to finish
# the AWS-side deletion, and only then destroy the infrastructure.
#
# Phase 2 made that wait real: the first live ALB went through it on
# 2026-09-22. Note WHAT is waited for - an ALB drops out of
# DescribeLoadBalancers almost immediately, while the ENIs it leaves in the
# subnets are what actually blocks the VPC delete. So the wait requires both
# to be gone, not just the load balancer record.
#
# Safe to run when no cluster exists - exits 0.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOFU_DIR="${REPO_DIR}/tofu"
CLUSTER_NAME="${CLUSTER_NAME:-lab-sandbox}"
REGION="${AWS_REGION:-us-east-1}"
LB_WAIT_SECONDS="${LB_WAIT_SECONDS:-300}"
TOFU="${TOFU:-tofu}"

log() { printf '%s  %s\n' "$(date -Is)" "$*"; }

# tofu destroy, retried ONCE if and only if a provider plugin stopped
# answering. On 2026-09-25 that happened twice on n150-2 in an hour (the helm
# provider during eks-up, the aws provider during eks-down - BACKLOG 3.6), and
# both times an immediate rerun succeeded. For the 02:00 timer a crash like that
# is a cluster left billing until someone notices, so one retry is worth it.
#
# Deliberately narrow. Any OTHER failure (AccessDenied, DependencyViolation, a
# state lock) fails at once, as before: retrying those hides a real problem and
# delays the exit code the timer's journal relies on. Destroy is idempotent, so
# a retry after a partial first run only has less left to do.
DESTROY_RETRY_DELAY="${DESTROY_RETRY_DELAY:-15}"
tofu_destroy() {
  local out rc
  out="$(mktemp)"
  if $TOFU destroy -auto-approve -input=false 2>&1 | tee "$out"; then
    rm -f "$out"; return 0
  fi
  rc=${PIPESTATUS[0]}
  if grep -q "Plugin did not respond" "$out"; then
    rm -f "$out"
    log "WARN: tofu destroy failed with 'Plugin did not respond' (BACKLOG 3.6)."
    log "WARN: retrying once in ${DESTROY_RETRY_DELAY}s."
    sleep "$DESTROY_RETRY_DELAY"
    $TOFU destroy -auto-approve -input=false
    return $?
  fi
  rm -f "$out"
  return "$rc"
}

# --- 0. Is there anything to tear down? ------------------------------------
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  log "No EKS cluster named '${CLUSTER_NAME}' in ${REGION}."
  log "Running tofu destroy anyway to clear any partial/orphaned state."
  cd "$TOFU_DIR"
  $TOFU init -input=false -upgrade=false >/dev/null
  tofu_destroy
  log "Done."
  exit 0
fi

log "Cluster '${CLUSTER_NAME}' exists. Beginning ordered teardown."

# --- 1. Kubeconfig ---------------------------------------------------------
KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
export KUBECONFIG="$KUBECONFIG_FILE"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
log "Kubeconfig written."

# --- 2. Let Argo prune its own managed resources ---------------------------
# Deleting Applications (which carry resources-finalizer) cascades to the
# resources they manage - including any Ingress or LoadBalancer Service.
# Delete the root last so it does not immediately re-create the children.
if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  log "Deleting Argo CD Applications (cascades to managed resources)..."
  kubectl -n argocd delete applications.argoproj.io --all \
    --ignore-not-found --timeout=180s || {
      log "WARN: Application delete timed out. Stripping finalizers and continuing."
      for app in $(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null || true); do
        kubectl -n argocd patch "$app" --type=merge \
          -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      done
    }
else
  log "No Application CRD; skipping Argo prune."
fi

# --- 3. Sweep any load-balancer-backed objects Argo did not own ------------
log "Deleting any remaining Ingresses and LoadBalancer Services..."
kubectl delete ingress --all --all-namespaces --ignore-not-found --timeout=120s || true
for svc in $(kubectl get svc --all-namespaces \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
      2>/dev/null || true); do
  ns="${svc%%/*}"; name="${svc##*/}"
  log "  deleting Service ${ns}/${name} (type=LoadBalancer)"
  kubectl -n "$ns" delete svc "$name" --ignore-not-found --timeout=120s || true
done

# --- 4. WAIT for AWS to actually remove the load balancers -----------------
# This is the step that makes the whole script worth having. Kubernetes
# reports the object gone well before the AWS-side ALB/NLB is deleted.
log "Waiting up to ${LB_WAIT_SECONDS}s for AWS load balancers to disappear..."
deadline=$(( SECONDS + LB_WAIT_SECONDS ))

# Same rule for the VPC lookup: an error used to become "None", which skipped
# the whole wait. Retry within the same deadline; "None" now only ever means
# AWS answered and there is no such VPC.
AWS_ERR="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE" "$AWS_ERR"' EXIT
while :; do
  if vpc_id="$(aws ec2 describe-vpcs --region "$REGION" \
      --filters "Name=tag:Name,Values=${CLUSTER_NAME}" \
      --query 'Vpcs[0].VpcId' --output text 2>"$AWS_ERR")"; then
    break
  fi
  err="$(tr '\n' ' ' < "$AWS_ERR")"
  log "  query failed (ec2 describe-vpcs): ${err:0:300}" >&2
  if (( SECONDS >= deadline )); then vpc_id="?"; break; fi
  sleep 15
done

# A failed query must never read as "0 remaining". Each count comes back as a
# number or "?"; "?" counts as still present, so a throttled call, an expired
# credential or a missing permission holds the wait (up to LB_WAIT_SECONDS)
# instead of waving teardown through to a DependencyViolation. The error goes
# to stderr, so the nightly run's journal says which call failed and why.
# stderr goes to a file, not into the answer: a harmless CLI warning must not
# turn a good "0" into a failure.
count_of() {
  local out err
  if out="$("$@" --output text 2>"$AWS_ERR")" && [[ "$out" =~ ^[0-9]+$ ]]; then
    printf '%s' "$out"
  else
    err="$(tr '\n' ' ' < "$AWS_ERR")"
    log "  query failed ($2 $3): ${err:0:300}${out:+ / output: ${out:0:100}}" >&2
    printf '?'
  fi
}

if [[ "$vpc_id" == "?" ]]; then
  log "WARN: could not look up the VPC for ${LB_WAIT_SECONDS}s, so could not wait for its load balancers."
  log "WARN: destroying anyway (stopping the billing comes first); it may fail on DependencyViolation. See docs/RUNBOOK.md."
elif [[ "$vpc_id" != "None" && -n "$vpc_id" ]]; then
  clear=false
  while (( SECONDS < deadline )); do
    count="$(count_of aws elbv2 describe-load-balancers --region "$REGION" \
      --query "length(LoadBalancers[?VpcId=='${vpc_id}'])")"
    classic="$(count_of aws elb describe-load-balancers --region "$REGION" \
      --query "length(LoadBalancerDescriptions[?VPCId=='${vpc_id}'])")"
    # The ENIs, not the load balancer record, are what fails the VPC delete.
    # AWS drops a deleted ALB from DescribeLoadBalancers within seconds while
    # its interfaces detach for a while longer; on 2026-09-22 this loop said
    # "none remain" 3s after the Ingress went, and only the minutes spent
    # deleting the cluster and nodegroup covered the difference. ELB-owned
    # interfaces are the ones whose Description starts "ELB ".
    enis="$(count_of aws ec2 describe-network-interfaces --region "$REGION" \
      --filters "Name=vpc-id,Values=${vpc_id}" \
      --query "length(NetworkInterfaces[?starts_with(Description, 'ELB ')])")"
    if [[ "$count" == "0" && "$classic" == "0" && "$enis" == "0" ]]; then
      log "No load balancers or ELB interfaces remain in ${vpc_id}."
      clear=true
      break
    fi
    note=""; [[ "$count$classic$enis" == *'?'* ]] && note=" ('?' = query failed, treated as present)"
    log "  ${count} v2 + ${classic} classic LBs, ${enis} ELB interfaces${note}; waiting..."
    sleep 15
  done
  if [[ "$clear" != true ]]; then
    log "WARN: after ${LB_WAIT_SECONDS}s: ${count} v2 + ${classic} classic LBs, ${enis} ELB interfaces."
    [[ "$count$classic$enis" == *'?'* ]] && \
      log "WARN: at least one query was still failing - see the 'query failed' lines above."
    log "WARN: destroying anyway (stopping the billing comes first); it may fail on DependencyViolation. See docs/RUNBOOK.md."
  fi
else
  # Unchanged behaviour, made visible: no tagged VPC means Tofu never got as
  # far as creating one, or it is already gone.
  log "No VPC tagged ${CLUSTER_NAME}; nothing to wait for."
fi

# --- 5. Destroy ------------------------------------------------------------
log "Running tofu destroy..."
cd "$TOFU_DIR"
$TOFU init -input=false -upgrade=false >/dev/null
tofu_destroy
log "Teardown complete."
