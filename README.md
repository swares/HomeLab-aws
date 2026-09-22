# HomeLab-aws — ephemeral EKS sandbox

A deliberately detachable AWS training environment, separate from
[swares/HomeLab](https://github.com/swares/HomeLab). An EKS cluster is built on
demand, bootstraps its own Argo CD, runs a small GitOps tree, and is destroyed
nightly.

**The lab has a zero-line diff from this repo.** Nothing here touches the k3s
cluster, the lab's Argo CD, Vault, or the NAS. Deleting this repo and running
one `tofu destroy` leaves no trace on either side.

## Why it is shaped this way

- **Separate repo, not a subtree.** The two bodies of work disagree on
  lifecycle (permanent vs. 8 hours), state backend (Minio vs. S3), blast radius,
  and operating rules. Merging them would mean one rulebook with a section of
  exceptions.
- **Argo CD lives in the cluster, not in the lab.** Tofu installs it via Helm
  and it dies with the cluster. The lab's Argo never registers an AWS
  destination, so there is no rotating endpoint to write back into Vault, no
  static IAM credentials in the lab control plane, and no Applications sitting
  `Unknown` in the lab UI every night after teardown. The cost is that EKS app
  status is not visible in lab Grafana.
- **Public subnets, no NAT Gateway.** A NAT Gateway is ~$32/mo and would cost
  more than the nodes. Not a production pattern; the right call for a cluster
  that lives 8 hours. See `tofu/vpc.tf`.
- **Teardown is a script, not `tofu destroy`.** Kubernetes controllers create
  AWS resources Tofu has no record of. See `scripts/eks-teardown.sh`.
- **The repo is public and Argo reads it anonymously.** No deploy key, no
  credential shared with the lab.

## Repo map

| Path | What it is |
|---|---|
| `tofu/` | Root module: VPC, IAM, EKS, addons, Argo CD bootstrap. Destroyed nightly |
| `tofu-account/` | **Permanent** root module: the monthly budget. Never torn down |
| `gitops/apps/` | App-of-apps children (Argo `Application` objects) |
| `gitops/workloads/` | Manifests the Applications point at |
| `gitops/bootstrap/` | Reference copy of the root Application (the live one is in `tofu/argocd.tf`) |
| `scripts/` | `eks-teardown.sh` (ordered teardown), `install-teardown-timer.sh` (sets up the 02:00 timer on n150-2), `print-aws-envelope.sh` |
| `systemd/` | Nightly teardown timer (runs on `n150-2`) |
| `docs/BREAK-GLASS.md` | AWS lockout envelope — prompted, printed, stored off-site |
| `CLAUDE.md` | Operating rules — read before touching anything |

## Quickstart

```bash
# One-time: create the state bucket (see tofu/backend.tf for the commands)
cp tofu-account/terraform.tfvars.example tofu-account/terraform.tfvars  # set budget_email
make account-init && make account-apply     # permanent budget - once, not per session
cp tofu/terraform.tfvars.example tofu/terraform.tfvars
make init

make eks-up                   # ~15 min. Billing starts.
eval "$(make -s eks-env)"     # point THIS shell's kubectl at the sandbox
make argocd-ui                # password + port-forward on :8080
make eks-down                 # ordered teardown; also deletes the sandbox kubeconfig
```

The sandbox never writes to `~/.kube/config`. Its kubeconfig lives in
`~/.kube/eks-sandbox`, so a shell you didn't `eval` in still talks to whatever
it talked to before - on n150-2, that's the lab.

`make eks-status` answers "is anything billing right now?"

Before the first long session, fill `docs/BREAK-GLASS.md`. Losing access to the
lab costs data; losing access to AWS costs money continuously, with no way to
stop it.

## What runs here

| App | Namespace | Notes |
|---|---|---|
| Argo CD | `argocd` | Installed by Tofu, not by itself. Dies with the cluster. |
| Kyverno | `kyverno` | Helm chart, sync-wave -1 |
| Kyverno policies | `kyverno` | Three ClusterPolicies vendored from HomeLab, sync-wave 0 |

That is the whole of phase 0 on purpose. If the create/destroy loop is not
boring and reliable, everything after it is painful.

## Cost

| Item | Rate | 8-hour session |
|---|---|---|
| EKS control plane | $0.10/hr | $0.80 |
| 2× t3.medium spot | ~$0.0125/hr ea | ~$0.20 |
| gp3 volumes, 30 GB ×2 | ~$0.08/GB-mo | ~$0.05 |
| NAT Gateway | **not created** | $0.00 |
| **Total** | | **~$1.05** |

Left running for a month, the same cluster is roughly **$85**. If the
Kubernetes version slips into extended support, the control plane alone goes
from $73/mo to about $438/mo. Both numbers are why the nightly timer exists.

## Roadmap

| Phase | Content | Status |
|---|---|---|
| 0 | Create/destroy loop, self-bootstrapping Argo, Kyverno baseline | this repo |
| 1 | LiteLLM → Bedrock via **IRSA** (the core EKS lesson) | not started |
| 2 | m5stack-adapter in front of it; ALB controller, ingress, teardown ordering | not started |
| 3 | Karpenter + GPU spot nodes; Whisper large-v3 batch | not started |

Lead-time items to start before phase 3: the **G-instance service quota**
(often 0 vCPUs on new accounts — a hard block, and the increase can take days)
and **Bedrock model access**, which is granted per-model per-region.

## Relationship to the lab

Upstream for the Kyverno policies only, and that copy is a **snapshot allowed
to drift**. The EKS sandbox is a short-lived training cluster; a stale policy
here costs nothing, and keeping two repos in lockstep is more machinery than
the problem deserves.
