# Convenience targets for the EKS sandbox. Mirrors the conventions in
# swares/HomeLab: `make help` greps the ## comments.
.PHONY: help init plan eks-up eks-down eks-status eks-kubeconfig argocd-ui cost fmt validate

TOFU      ?= tofu
TOFU_DIR   = tofu
REGION    ?= us-west-2
CLUSTER   ?= lab-sandbox

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

eks-status:  ## Is anything running (and billing)?
	@aws eks describe-cluster --name $(CLUSTER) --region $(REGION) \
		--query 'cluster.{name:name,status:status,version:version,created:createdAt}' \
		--output table 2>/dev/null \
		|| echo "No cluster '$(CLUSTER)' in $(REGION) - nothing billing."

eks-kubeconfig: ## Point kubectl at the sandbox
	aws eks update-kubeconfig --name $(CLUSTER) --region $(REGION)

argocd-ui:   ## Print the admin password and start a port-forward on :8080
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo
	@echo "user: admin   ->  http://localhost:8080"
	kubectl -n argocd port-forward svc/argocd-server 8080:443

cost:        ## Month-to-date spend
	@aws ce get-cost-and-usage \
		--time-period Start=$$(date -u +%Y-%m-01),End=$$(date -u +%Y-%m-%d) \
		--granularity MONTHLY --metrics UnblendedCost \
		--query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text

fmt:         ## Format HCL
	cd $(TOFU_DIR) && $(TOFU) fmt -recursive

validate:    ## Validate HCL
	cd $(TOFU_DIR) && $(TOFU) validate
