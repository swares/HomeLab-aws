# Case study: a disposable EKS cluster for about a dollar a session

*Scott Wares · October 2026 · [github.com/swares/HomeLab-aws](https://github.com/swares/HomeLab-aws)*

## The problem

I run a 14-host GitOps home lab ([HomeLab](https://github.com/swares/HomeLab)):
k3s, Argo CD, Vault, Kyverno, and a full Prometheus/Loki stack. It taught me
Kubernetes operations, but not the AWS parts that show up in platform and SRE
roles: EKS, IAM for workloads, load balancers created by controllers, and cost
control on a meter that never stops.

I had two constraints:

1. **It must not cost real money.** An EKS control plane bills $0.10/hr whether
   or not anything runs on it, so a forgotten cluster costs about $85 a month.
2. **It must not compromise the lab.** The lab has to keep working, unchanged,
   if the AWS account disappears tomorrow.

## The design in one paragraph

`make eks-up` builds a VPC, an EKS cluster on two spot nodes, and the IAM
roles, all with OpenTofu. Tofu installs Argo CD, and Argo installs everything
else from the public repo: Kyverno policies, a LiteLLM AI gateway, and an
adapter for my edge-device framework. The gateway is reachable through an ALB
from one IP address only. At 02:00 every night a systemd timer on a lab host
runs an ordered teardown as a narrowly scoped IAM user. The next session starts
from nothing.

## Decisions worth explaining

**Separate repo, not a folder in the lab repo.** The two disagree on almost
everything: lifecycle (permanent vs. 8 hours), state backend (MinIO vs. S3),
blast radius, and operating rules. One repo would mean one rulebook with a
section of exceptions. Separation also makes "the lab has a zero-line diff from
AWS" something you can check, not just a promise.

**Argo CD runs inside the EKS cluster, not in the lab.** If the lab's Argo
managed EKS, the lab would need a rotating cluster endpoint, static AWS
credentials, and a column of `Unknown` apps every morning after teardown. The
trade-off is that EKS app health isn't visible in lab Grafana. For a
training cluster I accepted that.

**No NAT Gateway.** It costs about $32 a month, more than the nodes. Public
subnets with tight security groups aren't a production pattern, and the repo
says so, but for an 8-hour cluster it's the right call.

**State in S3, not the lab's MinIO.** If the lab is down I still need to be
able to destroy the cluster. State that depends on the thing that's down turns
an outage into a bill.

**Workload identity through IRSA, with no AWS keys in pods.** The LiteLLM pod
assumes an IAM role through the cluster's OIDC provider. The trust policy pins
both the ServiceAccount (`sub`) and the audience with `StringEquals`. A
`StringLike` on `sub` would let any pod in the cluster assume the role.
`make irsa-check` proves it: the pod holds a role ARN and a token path, and no
key of any kind.

**Split ownership: Tofu owns identity, git owns workloads.** The repo is
public, and a role ARN contains the account ID. So Tofu creates the IAM role,
namespace, and ServiceAccount, and Argo deploys everything else. The role and
the only thing that can use it are created and destroyed together.

**Two kinds of secrets, two rules.** A value minted per cluster (the gateway's
master key) dies with the cluster, so storing it in Tofu state is fine. A
credential someone issued me (an API key) still works tomorrow, so it never
touches state, git, disk, or a command line. It's prompted for and written
straight into an in-cluster Secret.

## What broke, and what I changed

**The budget alarm was destroyed by the teardown it was watching.** The first
version kept the AWS Budget in the same module as the cluster. On the first
real teardown, the budget was deleted early in the destroy. If that teardown
had failed halfway, the cluster would have stayed up with no alarm. Now the
budget, the teardown identity, and the ECR repository live in a separate
`tofu-account/` module that is never part of the nightly destroy.

**`tofu destroy` alone can't clean up an EKS cluster.** The AWS Load Balancer
Controller creates ALBs, target groups, and security groups that Tofu has no
record of. Destroy the infrastructure first and the controller dies before it
can clean up, which orphans the ALB and makes the VPC delete fail with
`DependencyViolation`. The teardown script deletes the Kubernetes objects,
waits for AWS to finish, and only then destroys.

**"The load balancer is gone" was a lie, briefly.** A deleted ALB disappears
from `DescribeLoadBalancers` in seconds, but its network interfaces detach
much later, and those are what block the VPC delete. The wait now requires the
load balancers *and* their ENIs to be gone. It also fails closed: an AWS API
error counts as "still present", never as zero.

**The ALB answered with 504.** To keep my home IP out of a public repo, the
Ingress references a Tofu-managed security group by name. Naming a frontend
security group quietly turns off the controller's management of the
node-side rules, so the ALB came up healthy and then couldn't reach the pods.
The fix is a second annotation that must always travel with the first, now
written into the operating rules.

**The teardown identity outgrew its policy.** Phase 2 pushed the inline IAM
policy past the 2,048-byte limit. I moved it to an attached managed policy
(6,144 bytes) rather than widening actions to wildcards to save space.

**A cloud tool shared a kubeconfig with a lab cluster.** `aws eks
update-kubeconfig` rewrote the shared `~/.kube/config` on a host that is also a
k3s server. Plain `kubectl` quietly stopped pointing at the lab. The sandbox
now has its own kubeconfig file, which is deleted on teardown, and every tool
takes `KUBECONFIG` explicitly.

**Intermittent "Plugin did not respond" turned out to be bad RAM.** Four
unrelated-looking crashes in one day (Tofu providers, pip, the AWS CLI), all
on the same host, all under heavy load, and every rerun worked. Rather than
blame the tools, I tested the hardware. `memtester` passed with the CPU idle.
`stress-ng` under full CPU and memory load found 9 bit errors. ECC counters
read zero because ECC doesn't cover that memory, so they couldn't be trusted
to call the host healthy. The fix is in progress. Meanwhile the teardown
retries exactly once, and only for that error, and no state-changing Tofu runs
happen from that host (BACKLOG 3.6).

**Bedrock was blocked for the entire account.** IRSA worked end to end, but
every Bedrock call, from any identity and any model, returned an
account-level error. I added a fallback: LiteLLM tries Bedrock, then retries
the same request against the Anthropic API directly. Clients don't change, and
the smoke test reports which backend answered. A support case is open with AWS.

## Results

- Phases 0 to 2b verified live, including a nightly teardown with a live ALB
  that left no load balancers or security groups behind.
- About **$1.05 per 8-hour session**, or about $1.25 with the ALB, against
  about **$85 a month** if left running.
- Zero static AWS credentials in any pod, and no account ID or home IP in the
  public repo.

## What I'd do differently, and what's still open

I'd rather list these myself than have a reviewer find them. Each one is tracked in [BACKLOG.md](../BACKLOG.md).

- **CLI work still runs as the AWS root user.** The plan to move to an IAM
  Identity Center admin with MFA is written. It waits for a window with no
  cluster running (BACKLOG 1.2).
- **The ALB is HTTP only.** The master key crosses the internet in cleartext.
  That's mitigated by the single-IP security group and a new key every night,
  but the real fix is an ACM certificate, which needs a domain (BACKLOG 3.5).
- **The break-glass envelope isn't filled in, and its drill hasn't run** (BACKLOG 1.4, 1.5).
- **I'd have put the budget in its own module from day one.** Anything meant
  to catch a failure has to outlive it.

## Next

Phase 3 adds Karpenter with GPU spot nodes for batch Whisper transcription.
The GPU vCPU quota on a new account is zero, and requests take days, so that
request goes in before any code does.
