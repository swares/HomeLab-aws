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
# Phase 0 has no Ingress and no LoadBalancer Service, so the wait is a no-op
# today. It is built in now because phase 2 adds the ALB controller, and the
# failure mode above is much easier to avoid than to diagnose at 2am.
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

# --- 0. Is there anything to tear down? ------------------------------------
if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  log "No EKS cluster named '${CLUSTER_NAME}' in ${REGION}."
  log "Running tofu destroy anyway to clear any partial/orphaned state."
  cd "$TOFU_DIR"
  $TOFU init -input=false -upgrade=false >/dev/null
  $TOFU destroy -auto-approve -input=false
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
vpc_id="$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")"

if [[ "$vpc_id" != "None" && -n "$vpc_id" ]]; then
  deadline=$(( SECONDS + LB_WAIT_SECONDS ))
  while (( SECONDS < deadline )); do
    count="$(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "length(LoadBalancers[?VpcId=='${vpc_id}'])" --output text 2>/dev/null || echo 0)"
    classic="$(aws elb describe-load-balancers --region "$REGION" \
      --query "length(LoadBalancerDescriptions[?VPCId=='${vpc_id}'])" --output text 2>/dev/null || echo 0)"
    if [[ "$count" == "0" && "$classic" == "0" ]]; then
      log "No load balancers remain in ${vpc_id}."
      break
    fi
    log "  ${count} v2 + ${classic} classic still present; waiting..."
    sleep 15
  done
  if (( SECONDS >= deadline )); then
    log "WARN: load balancers still present after ${LB_WAIT_SECONDS}s."
    log "WARN: destroy may fail on DependencyViolation. See docs/RUNBOOK.md."
  fi
fi

# --- 5. Destroy ------------------------------------------------------------
log "Running tofu destroy..."
cd "$TOFU_DIR"
$TOFU init -input=false -upgrade=false >/dev/null
$TOFU destroy -auto-approve -input=false
log "Teardown complete."
