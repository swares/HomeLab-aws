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

## The teardown identity is scoped, and its access has an ordering rule

The 02:00 timer runs as the `lab-teardown` IAM user
(`tofu-account/teardown-user.tf`). Its policy can refresh and delete what
`tofu/` creates and nothing else.

- **Adding a resource type to `tofu/` means extending that policy in the same
  PR.** Otherwise the first sign is a 02:00 `AccessDenied`, with the cluster
  still running.
- **Its permissions are a MANAGED policy, attached** (`eks-sandbox-teardown`),
  not an inline user policy. Inline user policies cap at 2048 bytes and phase 2
  crossed it; managed allows 6144. Past that, add a second managed policy
  rather than widening actions to wildcards to save bytes.
- **Never create its access key in Tofu.** `aws_iam_access_key` would put the
  secret in S3 state. It is created by hand (RUNBOOK "Teardown timer").
- **Never give the timer an admin key.** The same key is envelope item 8, on
  paper and usable from anywhere.
- **`helm_release.argocd` must `depends_on` the teardown access policy
  association.** Destroy runs in reverse dependency order; that edge is what
  keeps lab-teardown's Kubernetes access alive until both Helm releases are
  uninstalled. Remove it and tofu may delete the access entry in parallel,
  failing the uninstall `Unauthorized` halfway through a nightly run.

## Workload identity: Tofu owns it, git owns the workload

Phase 1 established the pattern for any pod that calls AWS:

- **IAM role, namespace and ServiceAccount are Tofu** (`tofu/litellm.tf`). The
  SA's `eks.amazonaws.com/role-arn` annotation contains the account ID and the
  repo is public, so it never goes in git.
- **Everything else is GitOps.** The Argo Application for such a workload has
  no `CreateNamespace`, because Tofu owns the namespace.
- **Trust policies pin `sub` and `aud` with `StringEquals`.** Never
  `StringLike` on `sub`: that lets any ServiceAccount in the cluster assume
  the role.
- **Kubernetes resources created by Tofu must `depends_on` the teardown access
  policy association**, the same rule as the Helm releases, or the nightly
  destroy loses cluster access halfway.
- **Role names start `lab-sandbox-`,** which is what the teardown policy is
  scoped to.
- **Bedrock in us-east-1 is called through inference profiles** (`us.…`), not
  bare model IDs. The IAM policy must allow the profile *and* the model in
  every region the profile routes to.
- **No LiteLLM master key and no ingress, or both.** Never an ingress without
  the key. Phase 2a added both together: `gitops/workloads/litellm/ingress.yaml`
  and the Tofu-created Secret `litellm-master-key`.
- **The master key Secret is required, never `optional`.** With
  `LITELLM_MASTER_KEY` unset, LiteLLM starts with no auth at all (verified on
  v1.101.0). A missing Secret must stop the pod, not open the gateway.
- **The LiteLLM Ingress routes `/v1` only.** The admin UI, API docs and
  management routes live at other paths and stay inside the cluster. Widening
  the path is a security change, not a convenience.
- **Two kinds of secret, two rules.** A *credential someone issued us* (the
  Anthropic key, any IAM access key) stays valid after teardown, so it never
  goes in Tofu state. A *random value minted per cluster* (the LiteLLM master
  key, `random_password` in `tofu/litellm.tf`) is destroyed with the cluster
  and opens nothing afterwards, so state is acceptable. If a value would still
  work tomorrow, it is the first kind.
- **The Anthropic API key is the one static credential, and it is handled like
  the envelope's secrets.** It exists only as the in-cluster Secret
  `litellm-anthropic`, written by `make litellm-key` from a hidden prompt. Never
  a Tofu variable or `kubernetes_secret_v1` (that puts it in S3 state, and
  bucket versioning keeps it forever), never a ConfigMap, never `kubectl apply`
  (that copies it into an annotation), never an argv. The Deployment references
  it `optional: true`; keep it that way, so a session without the key still
  has a working Bedrock path. If this ever needs to survive teardown, the
  answer is Secrets Manager in `tofu-account/` with the value set by hand -
  not moving it into `tofu/`.
- **The fallback raises the stakes of an unauthenticated gateway:** a caller
  can now spend on the Anthropic account, which the AWS Budget does not see.
- **A chart that creates its own ServiceAccount keeps it** (phase 2's
  aws-load-balancer-controller): the role ARN is a Helm value in Tofu, still
  never a manifest in git. Tofu only creates the SA itself when nothing else
  will.

## Nothing that identifies the home network goes in git

This repo is public. The ingress ALB is reachable from the internet and its
backends have no auth, so the allowed source CIDR matters - and it is a home
address. It lives in `tofu/terraform.tfvars` (gitignored) as
`alb_allowed_cidrs`; Tofu builds the `lab-sandbox-alb-ingress` security group
from it, and the Ingress in `gitops/` references that group **by name**. Never
put a home address in an `alb.ingress.kubernetes.io/inbound-cidrs` annotation,
and never widen the variable to `0.0.0.0/0` - the variable validation refuses
it on purpose.

**Every Ingress that names that security group must also set
`alb.ingress.kubernetes.io/manage-backend-security-group-rules: "true"`.**
Naming a frontend SG turns off the controller's management of the node-side
rules, so the ALB provisions, passes the SG check, and then returns 504 because
nothing permits it to reach the pods. That pairing is the cost of keeping the
CIDR out of git; the two annotations travel together.

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

The wait requires the load balancers **and** their ENIs to be gone. A deleted
ALB disappears from `DescribeLoadBalancers` in seconds while its interfaces
detach for longer, and the interfaces are what `DeleteVpc` refuses over. Do not
"simplify" that check back to counting load balancers.

**The wait fails closed.** A query that errors (throttling, an expired
credential, a missing permission) counts as "still present", never as 0, and
the error is logged. The VPC lookup follows the same rule: an error is retried,
and only a real "no such VPC" skips the wait. When the deadline passes, the
script still runs `tofu destroy`, because stopping the billing comes first.
Never put back `|| echo 0` or `|| echo None` on these calls.

Phase 0 had no Ingress, so the wait was a no-op. Phase 2 makes it
load-bearing. Do not remove it.

Security groups are the second half of that problem. The controller creates
SGs tagged `elbv2.k8s.aws/cluster`, not with this repo's tags, and a VPC
cannot be deleted while any SG lives in it. `tofu-account/teardown-user.tf`
grants the teardown identity deletion on SGs carrying that tag, scoped to
`lab-sandbox`, purely as the orphan safety net.

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

`kubernetes` is used for **v1 resources only** (`kubernetes_namespace_v1`,
`kubernetes_service_account_v1`). Never `kubernetes_manifest`: it needs a live
cluster at plan time, and this cluster never exists at plan time.

`helm` is pinned to `~> 2.17` on purpose. Version 3.0 changed the provider
configuration syntax — the `kubernetes` block became an attribute and `set`
blocks became a list. `tofu/argocd.tf` is written for 2.x. Bumping it is a real
edit, not a version bump.

## Open work lives in BACKLOG.md

The README roadmap holds the phases; `BACKLOG.md` holds everything else. Do not
start a TODO list in another file, a PR description or a code comment. Add a
`### N.M` entry with checkboxes there instead. When you close something, tick
it, and only then strike through the heading and mark it **DONE**. `make backlog`
fails on an open box under a DONE heading (`--max-orphans 0`) and on any item
without a checkbox or an owning entry. Run it before any PR that touches the file.

## How changes are made

- Edit HCL or `gitops/`, open a PR. Argo reconciles `gitops/` with `selfHeal`
  and `prune` on.
- Infrastructure changes need `make plan` reviewed before `make eks-up`.
- The root `Application` exists twice: rendered by the `argocd-apps` Helm release
  in `tofu/argocd.tf` (the live one) and as a reference copy in
  `gitops/bootstrap/root-app.yaml`. If you edit one, edit both.
