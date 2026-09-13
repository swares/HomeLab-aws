#!/usr/bin/env bash
# Set the GitHub "About" panel for swares/HomeLab-aws.
# Requires: gh auth login   (I cannot do this - no GitHub credentials here)
set -euo pipefail
REPO="swares/HomeLab-aws"

gh repo edit "$REPO" \
  --description "Ephemeral EKS training sandbox: OpenTofu-built cluster that bootstraps its own Argo CD and tears itself down nightly. Deliberately detachable from the bare-metal home lab." \
  --homepage "https://github.com/swares/HomeLab" \
  --enable-issues \
  --enable-wiki=false \
  --enable-projects=false

gh repo edit "$REPO" \
  --add-topic aws \
  --add-topic eks \
  --add-topic kubernetes \
  --add-topic opentofu \
  --add-topic terraform \
  --add-topic gitops \
  --add-topic argocd \
  --add-topic kyverno \
  --add-topic infrastructure-as-code \
  --add-topic homelab \
  --add-topic devops \
  --add-topic ephemeral-infrastructure \
  --add-topic finops \
  --add-topic spot-instances \
  --add-topic irsa

gh repo view "$REPO" --json name,description,homepageUrl,repositoryTopics
