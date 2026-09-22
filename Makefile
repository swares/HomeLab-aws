# Convenience targets for the EKS sandbox. Mirrors the conventions in
# swares/HomeLab: `make help` greps the ## comments.
.PHONY: help init plan eks-up eks-down eks-status eks-kubeconfig eks-env argocd-ui litellm-wait litellm-smoke irsa-check alb-check cost fmt validate \
        account-init account-plan account-apply

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

litellm-smoke: litellm-wait ## Phase 1: one real Claude call through LiteLLM (port-forward, curl, clean up)
	@KUBECONFIG=$(EKS_KUBECONFIG) kubectl -n litellm port-forward svc/litellm 4000:4000 >/dev/null 2>&1 & \
	  pf=$$!; trap "kill $$pf 2>/dev/null" EXIT; sleep 3; \
	  curl -fsS http://localhost:4000/v1/chat/completions \
	    -H 'Content-Type: application/json' \
	    -d '{"model":"claude-haiku","max_tokens":40,"messages":[{"role":"user","content":"Reply with exactly: IRSA works"}]}' \
	  | python3 -c 'import json,sys; r=json.load(sys.stdin); print("model:", r["model"]); print("reply:", r["choices"][0]["message"]["content"])'

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
