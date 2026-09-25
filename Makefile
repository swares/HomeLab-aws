# Convenience targets for the EKS sandbox. Mirrors the conventions in
# swares/HomeLab: `make help` greps the ## comments.
.PHONY: help init plan eks-up eks-down eks-status eks-kubeconfig eks-env argocd-ui litellm-wait litellm-smoke litellm-url litellm-master-key litellm-auth-check litellm-key fallback-check irsa-check alb-check cost fmt validate \
        account-init account-plan account-apply backlog

# Recipes use bash features ([[ ]]); /bin/sh on Debian is dash.
SHELL     := /bin/bash

TOFU      ?= tofu
TOFU_DIR   = tofu
REGION    ?= us-east-1
CLUSTER   ?= lab-sandbox

# The sandbox gets its OWN kubeconfig file. Never ~/.kube/config: on n150-2
# (a k3s server) `aws eks update-kubeconfig` switched the shared file's
# current-context to EKS, so plain `kubectl` stopped pointing at the lab.
# Use `eval "$(make -s eks-env)"` to point a shell at the sandbox.
EKS_KUBECONFIG ?= $(HOME)/.kube/eks-sandbox

# Argo CD creates the litellm Deployment a few minutes after `eks-up` returns
# (root app -> litellm app -> manifests). The phase-1 targets wait rather than
# failing with "deployments.apps \"litellm\" not found".
LITELLM_WAIT ?= 300

# Which LiteLLM model group `litellm-smoke` asks for. `claude-haiku` is the
# client-facing name (Bedrock, falling back to the Anthropic API);
# `claude-haiku-direct` hits the fallback backend alone.
LITELLM_MODEL ?= claude-haiku

# How `litellm-smoke` reaches LiteLLM: `pf` (port-forward to the Service, works
# from anywhere with the kubeconfig) or `alb` (through the Ingress, works only
# from an address in alb_allowed_cidrs - the real client path).
LITELLM_VIA ?= pf

# Read the per-cluster master key (Tofu-created Secret). Used inside recipes;
# the key goes to curl on stdin (-H @-), never in argv.
LITELLM_KEY_CMD = KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm get secret litellm-master-key -o jsonpath='{.data.master-key}' | base64 -d
LITELLM_HOST_CMD = KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm get ingress litellm -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

help:        ## Show this help
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t-/' | sort

init:        ## Initialise OpenTofu (S3 backend must already exist - see tofu/backend.tf)
	cd $(TOFU_DIR) && $(TOFU) init

plan:        ## Show what eks-up would do
	cd $(TOFU_DIR) && $(TOFU) plan

eks-up:      ## Create the sandbox cluster (~15 min). BILLING STARTS NOW.
	@echo "Control plane is \$$0.10/hr from the moment this completes."
	@echo "Nightly teardown runs at 02:00. Run 'make eks-down' when finished."
	cd $(TOFU_DIR) && $(TOFU) apply
	@$(MAKE) --no-print-directory eks-kubeconfig

eks-down:    ## Ordered teardown: prune Argo apps, wait for LBs, then destroy
	./scripts/eks-teardown.sh
	@rm -f $(EKS_KUBECONFIG) && echo "Removed $(EKS_KUBECONFIG) (cluster is gone)."

eks-status:  ## Is anything running (and billing)?
	@aws eks describe-cluster --name $(CLUSTER) --region $(REGION) \
		--query 'cluster.{name:name,status:status,version:version,created:createdAt}' \
		--output table 2>/dev/null \
		|| echo "No cluster '$(CLUSTER)' in $(REGION) - nothing billing."

eks-kubeconfig: ## Write the sandbox kubeconfig to its own file (never ~/.kube/config)
	@mkdir -p $(dir $(EKS_KUBECONFIG))
	aws eks update-kubeconfig --name $(CLUSTER) --region $(REGION) --kubeconfig $(EKS_KUBECONFIG)
	@echo 'Point this shell at the sandbox with:  eval "$$(make -s eks-env)"'

eks-env:     ## Print the export line; use: eval "$(make -s eks-env)"
	@echo "export KUBECONFIG=$(EKS_KUBECONFIG)"

argocd-ui:   ## Print the admin password and start a port-forward on :8080
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo
	@echo "user: admin   ->  http://localhost:8080"
	KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n argocd port-forward svc/argocd-server 8080:443

litellm-wait:  ## Phase 1: wait for Argo to create the litellm Deployment, then for it to be ready
	@echo "Waiting up to $(LITELLM_WAIT)s for Argo CD to create deploy/litellm..."
	@deadline=$$(( $$(date +%s) + $(LITELLM_WAIT) )); \
	  until KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm get deploy/litellm >/dev/null 2>&1; do \
	    if [[ $$(date +%s) -ge $$deadline ]]; then \
	      echo "FAIL: deploy/litellm never appeared. Check: kubectl -n argocd get applications"; exit 1; \
	    fi; \
	    sleep 5; \
	  done
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm rollout status deploy/litellm --timeout=180s

# LITELLM_VIA=pf (default) port-forwards to a FREE local port, never a fixed
# 4000: a leftover port-forward (from a manual test, or pointing at a pod that
# has since been replaced) would otherwise hold 4000, ours would fail to bind
# silently, and curl would hit the stale one - "Empty reply from server".
# LITELLM_VIA=alb goes through the Ingress instead, like a real client.
# On a non-200 it prints the HTTP status and LiteLLM's error message, not a
# JSON traceback. Since phase 2a every call carries the master key.
litellm-smoke: litellm-wait ## Phase 1: one real Claude call through LiteLLM; prints which backend served it (LITELLM_VIA=alb for the ALB path)
	@hdr=$$(mktemp); body=$$(mktemp); pf=""; trap 'kill $$pf 2>/dev/null; rm -f $$hdr $$body' EXIT; \
	  key=$$($(LITELLM_KEY_CMD)); \
	  [[ -n "$$key" ]] || { echo "FAIL: no litellm-master-key Secret - was the cluster created by this tofu?"; exit 1; }; \
	  if [[ "$(LITELLM_VIA)" == alb ]]; then \
	    host=$$($(LITELLM_HOST_CMD)); \
	    [[ -n "$$host" ]] || { echo "FAIL: the Ingress has no address yet - the ALB takes 2-3 minutes after eks-up"; exit 1; }; \
	    base="http://$$host"; \
	  else \
	    port=$$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'); \
	    KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm port-forward svc/litellm $$port:4000 >/dev/null 2>&1 & pf=$$!; \
	    for i in $$(seq 1 30); do \
	      kill -0 $$pf 2>/dev/null || { echo "FAIL: kubectl port-forward exited before it was ready"; exit 1; }; \
	      (exec 3<>/dev/tcp/127.0.0.1/$$port) 2>/dev/null && break; sleep 0.5; \
	    done; \
	    base="http://127.0.0.1:$$port"; \
	  fi; \
	  code=$$(printf 'Authorization: Bearer %s\n' "$$key" | curl -sS -o "$$body" -D "$$hdr" -w '%{http_code}' -H @- \
	    "$$base/v1/chat/completions" -H 'Content-Type: application/json' \
	    -d '{"model":"$(LITELLM_MODEL)","max_tokens":40,"messages":[{"role":"user","content":"Reply with exactly: gateway works"}]}'); \
	  unset key; \
	  if [[ "$$code" != 200 ]]; then \
	    echo "FAIL: HTTP $$code from LiteLLM (model group $(LITELLM_MODEL), via $(LITELLM_VIA))"; \
	    python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["message"][:1500])' < "$$body" 2>/dev/null \
	      || head -c 1500 "$$body"; echo; exit 1; \
	  fi; \
	  python3 -c 'import json,sys; r=json.load(sys.stdin); print("model:", r["model"]); print("reply:", r["choices"][0]["message"]["content"])' < "$$body"; \
	  echo "via $(LITELLM_VIA); backend (bedrock-haiku | anthropic-haiku) and fallbacks attempted:"; \
	  grep -iE '^x-litellm-(model-id|attempted-fallbacks):' "$$hdr" | tr -d '\r' | sed 's/^/  /'

litellm-url: ## Phase 2a: print the ALB URL and a ready-to-run curl (the key is fetched at run time, not printed)
	@host=$$($(LITELLM_HOST_CMD)); \
	  [[ -n "$$host" ]] || { echo "No address yet - the ALB takes 2-3 minutes after eks-up. Watch: kubectl -n litellm get ingress litellm -w"; exit 1; }; \
	  echo "Base URL (OpenAI-compatible): http://$$host/v1"; \
	  echo "Reachable only from alb_allowed_cidrs. Key: make -s litellm-master-key"; echo; \
	  echo "printf 'Authorization: Bearer %s\\n' \"\$$(make -s litellm-master-key)\" | curl -sS -H @- \\"; \
	  echo "  http://$$host/v1/chat/completions -H 'Content-Type: application/json' \\"; \
	  echo "  -d '{\"model\":\"claude-haiku\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"

litellm-master-key: ## Phase 2a: print this cluster's LiteLLM master key (new every eks-up)
	@$(LITELLM_KEY_CMD); echo

# Proves the three layers in front of LiteLLM from the outside. Must run from an
# address in alb_allowed_cidrs. LiteLLM without a database refuses a missing or
# wrong key with 500/400 rather than 401, so "refused" here means "anything but
# 200"; what matters is that it never answers 200 without the key.
litellm-auth-check: ## Phase 2a: through the ALB - no key refused, wrong key refused, right key works, admin paths not exposed
	@host=$$($(LITELLM_HOST_CMD)); \
	  [[ -n "$$host" ]] || { echo "FAIL: the Ingress has no address yet"; exit 1; }; \
	  b="http://$$host"; fail=0; \
	  j='{"model":"claude-haiku","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'; \
	  c=$$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$$b/v1/chat/completions" -H 'Content-Type: application/json' -d "$$j"); \
	  if [[ "$$c" == 000 ]]; then echo "FAIL: no connection - is this machine's address in alb_allowed_cidrs?"; exit 1; fi; \
	  if [[ "$$c" == 200 ]]; then echo "FAIL: no key  -> 200 (the gateway is OPEN)"; fail=1; else echo "OK:   no key    -> $$c (refused)"; fi; \
	  c=$$(printf 'Authorization: Bearer sk-wrong\n' | curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H @- "$$b/v1/chat/completions" -H 'Content-Type: application/json' -d "$$j"); \
	  if [[ "$$c" == 200 ]]; then echo "FAIL: wrong key -> 200"; fail=1; else echo "OK:   wrong key -> $$c (refused)"; fi; \
	  c=$$(printf 'Authorization: Bearer %s\n' "$$($(LITELLM_KEY_CMD))" | curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H @- "$$b/v1/models"); \
	  if [[ "$$c" == 200 ]]; then echo "OK:   right key -> 200 (/v1/models)"; else echo "FAIL: right key -> $$c"; fail=1; fi; \
	  for p in / /ui/ /key/generate /health/readiness; do \
	    c=$$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$$b$$p"); \
	    if [[ "$$c" == 404 ]]; then echo "OK:   $$p -> 404 (not routed by the ALB)"; else echo "FAIL: $$p -> $$c (should not be reachable from outside)"; fail=1; fi; \
	  done; \
	  exit $$fail

# The fallback key is the one static credential in this design. Prompted,
# never read from disk, never an argv (printf is a bash builtin, so the key is
# not visible in `ps`), never `kubectl apply` (that would copy it into the
# last-applied-configuration annotation). It lives only as an in-cluster
# Secret and dies with the cluster, so this runs once per `eks-up`.
# Run it ON ITS OWN LINE. It reads the key from the terminal, so in a pasted
# multi-line block it swallows the next pasted line as the "key".
# Only standard API keys (sk-ant-api...) can call the Messages API. Admin keys
# (sk-ant-admin...) and OAuth tokens (sk-ant-oat...) start with sk-ant- too, and
# used to be accepted here and then fail later as "401 API key is invalid".
litellm-key: litellm-wait ## Fallback: prompt for the Anthropic API key, store it as an in-cluster Secret, restart LiteLLM
	@read -rsp "Anthropic API key (input hidden): " key; echo; \
	  if [[ "$$key" =~ [[:space:]] ]]; then unset key; echo "FAIL: key contains whitespace - paste only the key"; exit 1; fi; \
	  if [[ "$$key" != sk-ant-api* ]]; then unset key; \
	    echo "FAIL: not a standard Anthropic API key (sk-ant-api...). Admin keys and OAuth tokens cannot call the Messages API."; exit 1; fi; \
	  KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm delete secret litellm-anthropic --ignore-not-found >/dev/null; \
	  printf '%s' "$$key" | KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm create secret generic litellm-anthropic \
	    --from-file=api-key=/dev/stdin >/dev/null; \
	  rc=$$?; unset key; [[ $$rc -eq 0 ]] && echo "OK: secret litellm-anthropic written" || exit $$rc
	@# os.environ/ is resolved at LiteLLM startup: a new key needs a new pod.
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm rollout restart deploy/litellm
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm rollout status deploy/litellm --timeout=180s

fallback-check: litellm-wait ## Fallback: key present in-cluster only - never in the ConfigMap or git
	@if KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm get secret litellm-anthropic >/dev/null 2>&1; then \
	  echo "OK: secret litellm-anthropic exists"; \
	else echo "INFO: no secret litellm-anthropic - run 'make litellm-key' (without it claude-haiku has no fallback; while the account has Bedrock Error 002 it cannot answer at all)"; fi
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm exec deploy/litellm -- \
	  sh -c 'if [ -n "$$ANTHROPIC_API_KEY" ]; then echo "OK: pod has ANTHROPIC_API_KEY ($${#ANTHROPIC_API_KEY} chars)"; \
	         else echo "INFO: pod has no ANTHROPIC_API_KEY - run make litellm-key (it restarts the pod)"; fi'
	@if KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm get configmap litellm-config -o yaml | grep -q 'sk-ant-'; then \
	  echo "FAIL: key material in the ConfigMap"; exit 1; else echo "OK: ConfigMap holds no key"; fi
	@if git grep -qE 'sk-ant-[A-Za-z0-9]'; then echo "FAIL: key material committed to git"; exit 1; \
	  else echo "OK: no key in git"; fi

irsa-check: litellm-wait ## Phase 1: prove the pod has web-identity creds and NO static keys
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm exec deploy/litellm -- \
	  sh -c 'env | grep -E "^AWS_(ROLE_ARN|WEB_IDENTITY_TOKEN_FILE)=" | sed "s/[0-9]\{12\}/<acct>/"; \
	         if env | grep -qE "^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)="; then echo "FAIL: static keys present"; exit 1; \
	         else echo "OK: no static AWS keys in the pod"; fi; \
	         if [ -s "$$AWS_WEB_IDENTITY_TOKEN_FILE" ]; then echo "OK: IRSA web-identity token mounted"; \
	         else echo "FAIL: IRSA token file missing"; exit 1; fi; \
	         if [ -e /var/run/secrets/kubernetes.io/serviceaccount/token ]; then echo "FAIL: k8s API token mounted"; exit 1; \
	         else echo "OK: no Kubernetes API token (automount off)"; fi'

alb-check:   ## Phase 2: prove the AWS Load Balancer Controller is up and holding IRSA creds
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl get ingressclass alb -o jsonpath='{.metadata.name}{"\t"}{.spec.controller}{"\n"}'
	@# The controller image is distroless, so there is no shell to exec into:
	@# read the annotation the pod-identity webhook acts on instead.
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n kube-system get sa aws-load-balancer-controller \
	  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}{"\n"}' | sed 's/[0-9]\{12\}/<acct>/'

cost:        ## Month-to-date spend
	@aws ce get-cost-and-usage \
		--time-period Start=$$(date -u +%Y-%m-01),End=$$(date -u +%Y-%m-%d) \
		--granularity MONTHLY --metrics UnblendedCost \
		--query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text

backlog:     ## Audit BACKLOG.md bookkeeping (no untrackable items, no open boxes under a DONE heading)
	python3 scripts/backlog-audit.py --strict --max-orphans 0

fmt:         ## Format HCL
	cd $(TOFU_DIR) && $(TOFU) fmt -recursive

validate:    ## Validate HCL
	cd $(TOFU_DIR) && $(TOFU) validate

# --- Permanent, account-level resources (tofu-account/). NOT torn down. ------

account-init: ## Initialise the permanent account module (budget)
	cd tofu-account && $(TOFU) init

account-plan: ## Plan the permanent account module
	cd tofu-account && $(TOFU) plan

account-apply: ## Apply the permanent account module. Never part of eks-down.
	cd tofu-account && $(TOFU) apply
