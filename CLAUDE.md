# CLAUDE.md — operating rules for the AWS sandbox

You are helping operate an **ephemeral EKS training cluster** in `us-east-1`.
It is deliberately separate from the home lab. Read this before acting.

This is not the lab. The lab's rules (`swares/HomeLab/CLAUDE.md`) do not apply
here, and these do not apply there.

## The prime directive: this must stay detachable

The whole justification for this repo is that the lab keeps working, unchanged,
if AWS disappears. Every change is measured against that.

- **Never** add a Vault path, ExternalSecret, or Argo `Application` in the
  **lab** cluster that points at AWS.
- **Never** register this cluster as a destination in the lab's Argo CD. Argo
  CD runs *inside* this cluster and dies with it. That is the design, not an
  oversight.
- **Never** make a lab service depend on an AWS service at runtime.
- The one accepted exception is the nightly teardown timer, which runs on a lab
  host and holds a scoped AWS credential. It is an exception, not a precedent.

## Cost is the primary operational risk

Nothing here can lose data. The realistic failure is a cluster nobody
remembered, quietly accruing charges.

- The control plane is **$0.10/hr** — about **$73/mo** — whether or not
  anything is deployed on it.
- If `cluster_version` falls out of standard support the rate becomes
  **$0.60/hr**, about **$438/mo**. Check the EKS version calendar before
  bumping or leaving it alone.
- **Never create a NAT Gateway.** ~$32/mo, more than the nodes. `tofu/vpc.tf`
  uses public subnets specifically to avoid it. Most upstream EKS modules
  create one by default — that is why this module does not use one.
- Run `make eks-status` before assuming nothing is running.
- The nightly timer at 02:00 is the primary control. The Budget alarm is the
  backstop for the night it did not fire.
- **The budget lives in `tofu-account/`, never in `tofu/`.** `tofu/` is
  destroyed nightly; a backstop destroyed alongside the thing it watches is not
  a backstop. On the first real teardown the budget went early in the destroy,
  so a teardown failing halfway would have left the cluster up and the alarm
  gone. Never add `tofu-account/` to `make eks-down` or the teardown script.
- `upgrade_policy` is `STANDARD`, not the EKS default `EXTENDED`: a cluster
  left on an old version gets auto-upgraded rather than billed 6x.

## Never write the sandbox into `~/.kube/config`

n150-2 is a k3s server. On 2026-09-21 `aws eks update-kubeconfig` switched the
shared `~/.kube/config` to EKS, so plain `kubectl` as `swares` silently stopped
pointing at the lab. The sandbox kubeconfig is `~/.kube/eks-sandbox`, written
by `make eks-kubeconfig` and deleted by `make eks-down`. Point a shell at it
with `eval "$(make -s eks-env)"`. Any new tooling that needs cluster access
takes `KUBECONFIG` explicitly, the way `argocd-ui` and the teardown script do.

## Lockout is a billing event, not just an access problem

If AWS access is lost, the cluster keeps billing. `docs/BREAK-GLASS.md` exists
for that, and its first recovery step is deliberately not "regain access" — it
is "use the teardown credential from any machine to stop the charges," because
that takes minutes while a root recovery can take days.

`scripts/print-aws-envelope.sh` **prompts** for each credential and renders it
into the printed page. The invariant is narrower than "no secrets": secrets are
**prompted for, never read from disk or an API**. AWS exposes no endpoint that
returns a root password or an MFA seed, so anything that read these from a file
would be creating the at-rest copy the envelope exists to avoid. Prompt, render,
shred.

The handling discipline is the lab's, deliberately: `read -s` so nothing reaches
the scrollback, rendering under `/dev/shm`, shred on every exit path, and the
CUPS spool purged **after** the queue drains rather than before. Install
`oathtool` before running it — it verifies each base32 MFA seed against a live
TOTP code, which is the only way to catch a transcription error before the
lockout rather than during it.

## Teardown is ordered, and the order is load-bearing

**Never run `tofu destroy` directly.** Use `make eks-down`.

Kubernetes controllers create AWS resources that OpenTofu has no record of. An
Ingress managed by the AWS Load Balancer Controller creates an ALB, target
groups and a security group. Destroy the infrastructure first and the
controller is deleted before it can clean up after itself: the load balancers
are orphaned, the VPC delete fails with `DependencyViolation` on ENIs Tofu
cannot see, and the cleanup is manual and billable.

The order is: delete the Kubernetes objects → **wait** for AWS to actually
remove the load balancers → destroy. `scripts/eks-teardown.sh` does all three.

Phase 0 has no Ingress, so the wait is currently a no-op. Do not remove it.
Phase 2 makes it load-bearing.

## State lives in S3, never in Minio

If the lab is down you must still be able to destroy the cluster. State behind
Minio behind the H4 means a lab outage becomes a control plane you are paying
for and cannot reach. Bucket versioning is the only undo for corrupted state —
do not disable it.

## Kyverno policies are a vendored snapshot

`gitops/workloads/kyverno/policies/` is copied from HomeLab and is **allowed to
drift**. Do not edit these expecting the change to reach the lab, and do not
treat a difference from upstream as a bug.

One thing that is load-bearing and was carried over verbatim: the `=()`
equality anchor on `initContainers` in `require-resource-limits.yaml`. Without
the parentheses the pattern requires the field to be *present*, and every pod
without an initContainer fails admission. In Enforce mode that is a
cluster-wide outage from a one-character edit. The upstream comment explaining
this was kept deliberately — do not trim it.

Expect the first Karpenter sync in phase 3 to fail admission (its namespace is
not excluded and the NVIDIA device plugin runs privileged). That is the policy
working.

## Version pins move together

Three pins are coupled, and bumping one alone is how this goes wrong:

| Pin | Where | Constrained by |
|---|---|---|
| `cluster_version` | `tofu/variables.tf` | EKS standard support **and** the Kyverno compatibility matrix |
| Kyverno chart | `gitops/apps/kyverno.yaml` | Kubernetes version |
| argo-cd chart | `tofu/variables.tf` | Kubernetes version |

As of 2026-09-21 the ceiling is Kyverno: its matrix lists Kubernetes 1.35
as the newest supported, even though EKS offers 1.36. Check both before
moving `cluster_version` in either direction. Falling behind is the
expensive failure (extended support is 6× the control-plane price);
jumping ahead is the confusing one (an admission webhook that half-works).

`tofu/.terraform.lock.hcl` is committed. After adding a provider or
changing a constraint, run `tofu init -upgrade` and commit the lock file in
the same change.

## Provider pinning

`helm` is pinned to `~> 2.17` on purpose. Version 3.0 changed the provider
configuration syntax — the `kubernetes` block became an attribute and `set`
blocks became a list. `tofu/argocd.tf` is written for 2.x. Bumping it is a real
edit, not a version bump.

## How changes are made

- Edit HCL or `gitops/`, open a PR. Argo reconciles `gitops/` with `selfHeal`
  and `prune` on.
- Infrastructure changes need `make plan` reviewed before `make eks-up`.
- The root `Application` exists twice: rendered by the `argocd-apps` Helm release
  in `tofu/argocd.tf` (the live one) and as a reference copy in
  `gitops/bootstrap/root-app.yaml`. If you edit one, edit both.
