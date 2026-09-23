# RUNBOOK — EKS sandbox

## One-time bootstrap

### 1. State bucket

The bucket cannot be created by the module that stores its state in it. Create
it by hand, once:

**Note the missing `--create-bucket-configuration`.** `us-east-1` is S3's
default region and passing `LocationConstraint=us-east-1` fails with
`InvalidLocationConstraint`. Every other region requires it; this one rejects
it. Copying a create-bucket command from any other runbook will not work here.

```bash
aws s3api create-bucket --bucket swares-lab-tofu-state --region us-east-1

aws s3api put-bucket-versioning --bucket swares-lab-tofu-state \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block --bucket swares-lab-tofu-state \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

Versioning is not optional — it is the only undo for a corrupted state file.

If you also stand up the restic S3 target (Seam C), create both buckets in the
same sitting. Restic's bucket wants Object Lock, which **must** be enabled at
creation time and cannot be added later.

### 2. The permanent budget (once, not per session)

```bash
cp tofu-account/terraform.tfvars.example tofu-account/terraform.tfvars
# set budget_email
make account-init
make account-apply
git add tofu-account/.terraform.lock.hcl && git commit   # first time only
```

This is the backstop for a cluster nobody tore down, so it is deliberately
outside the module that gets destroyed. It covers the whole account, and it
emails you directly: there's no SNS subscription to confirm.

### 3. Sandbox tfvars

```bash
cp tofu/terraform.tfvars.example tofu/terraform.tfvars
make init
```

### 4. Fill the break-glass envelope

`docs/BREAK-GLASS.md`. Do this before the first long session, not after.

The AWS lockout scenario is not "I forgot my password" — it is a lost MFA
device, and AWS shows the virtual MFA secret **exactly once** at enrolment. If
you only scanned the QR code, that seed exists nowhere but on the phone. The
cluster keeps billing while you work through AWS Support.

    apt install pandoc oathtool                  # oathtool verifies MFA seeds
    ./scripts/print-aws-envelope.sh --dry-run    # prompt + render, print nothing
    ./scripts/print-aws-envelope.sh              # prompt, render, print, purge

The script prompts for each value; nothing is echoed, and nothing is read from
disk or from an AWS API. Press Enter to skip any item and get a ruled blank to
fill in by hand instead.

With `oathtool` installed it generates a live TOTP code from each seed you type
and asks you to confirm it against your authenticator. Do not skip that — a
base32 transcription error produces valid-looking codes that AWS rejects, and
the failure is silent until the moment you need it.

Run it on a host with encrypted swap or none: rendering happens in `/dev/shm`,
but tmpfs can still be swapped, and bash cannot mlock its memory.

Run **Drill A** within a week of filling it: from a machine with no AWS
credentials and no browser session, use only the envelope to clone the public
repo and `make eks-down` a running cluster. That drill is the one that proves
you can stop the billing without your workstation or the lab.

## Daily use

```bash
make eks-up                   # ~15 min
eval "$(make -s eks-env)"     # point this shell at the sandbox
make argocd-ui                # password + port-forward :8080
make eks-down                 # also deletes ~/.kube/eks-sandbox
```

The sandbox kubeconfig is `~/.kube/eks-sandbox`, never `~/.kube/config`. A
shell where you haven't run the `eval` still points wherever it did before.

Verify after `eks-up` (in the `eval`'d shell):

```bash
kubectl get nodes                          # 2 Ready
kubectl -n argocd get applications         # root, kyverno, kyverno-policies Synced/Healthy
kubectl get clusterpolicies                # 3, all Ready
```

There is no ingress and no public endpoint for Argo. The UI is reached by
port-forward only. This is deliberate — see `CLAUDE.md`.

## Teardown timer

The 02:00 timer on **`n150-2.lab.home.arpa`** is the primary control against a
forgotten cluster. The budget is only the backstop.

Why n150-2 and not `xu3-1` (the build agent): the Odroid XU3 is ARMv7 32-bit,
and AWS publishes CLI v2 for `x86_64` and `aarch64` only. Teardown needs `aws`
for `eks get-token`, which kubectl and the helm provider both call.

### The pieces

| Piece | Where | Why |
|---|---|---|
| `lab-teardown` IAM user + scoped policy | `tofu-account/teardown-user.tf` | Can refresh and delete sandbox resources; creates nothing, cannot touch the budget or the account state |
| Its access key | `/etc/eks-sandbox/teardown.env`, `0400 eks-teardown` | Created by hand so the secret never enters tofu state |
| Its **Kubernetes** access | access entry in `tofu/eks.tf`, made by every `make eks-up` | AWS permissions alone cannot reach the cluster API; without this the Helm uninstall fails `Unauthorized` and the cluster stays up |
| `eks-teardown` system user | n150-2 | No login shell; runs the unit |
| Timer's own checkout | `/opt/HomeLab-aws` | Separate from your working copy; `git pull --ff-only` before every run |
| Units | `systemd/eks-teardown.{service,timer}` | Hardened; no retries; failures go to the journal only, by design |

### Install (once)

```bash
# 1. The IAM user and its policy - permanent module
make account-apply

# 2. Its access key, by hand, NOT via tofu
aws iam create-access-key --user-name lab-teardown
#    Copy AccessKeyId and SecretAccessKey. This is also envelope item 8.

# 3. Everything on n150-2: user, AWS CLI v2 in /usr/local/bin, /opt clone,
#    credentials file (prompted, not echoed), units, credential check
sudo ./scripts/install-teardown-timer.sh
```

The script refuses to finish if the key authenticates as anything other than
`lab-teardown`. An admin key on the timer defeats the point of scoping it.

Re-run the script any time; it is idempotent. `--rotate-key` replaces the
credentials file. Deactivate the old key in IAM afterwards.

### Verify (before trusting it)

The install only proves the key **authenticates**. The only proof it can
**tear down** is a real run:

```bash
make eks-up                                   # as yourself
sudo systemctl start eks-teardown.service     # as the timer would at 02:00
journalctl -u eks-teardown.service -f         # expect "Teardown complete."
```

Then the orphan sweep below, and `make eks-status` should say nothing is
billing. Also `rm -f ~/.kube/eks-sandbox`: only `make eks-down` removes that
file. The timer runs as a different user, so a timer teardown leaves it behind. Also run it once with no cluster up; it should exit 0.

### When a nightly run fails

```bash
systemctl status eks-teardown.service
journalctl -u eks-teardown.service --since yesterday
```

- **`AccessDenied` naming an action.** A resource type was added to `tofu/`
  without extending `tofu-account/teardown-user.tf`. Add the action,
  `make account-apply`, `sudo systemctl start eks-teardown.service`.
- **`Unauthorized` from kubectl or Helm.** The cluster was created before the
  teardown access entry existed, or the entry was removed. Run `make eks-down`
  as yourself.
- **Anything else.** Run `make eks-down` as yourself first to stop the billing,
  then diagnose. The cluster costs money while you debug the timer.

## Phase 1: LiteLLM → Bedrock via IRSA

### One-time prerequisites (account level, do before the first phase-1 `eks-up`)

1. **Anthropic use-case form.** Bedrock enables serverless models by default
   (the old Model Access page was retired in October 2025), but Anthropic
   models still need a one-time use-case form. In the Bedrock console, open
   Claude Haiku 4.5 in the model catalog and submit it when prompted.
2. **Make the first call yourself, as admin.** The account's first Anthropic
   call creates an AWS Marketplace subscription and needs
   `aws-marketplace:Subscribe`, which the pod deliberately does not have:
   ```bash
   aws bedrock-runtime converse --region us-east-1 \
     --model-id us.anthropic.claude-haiku-4-5-20251001-v1:0 \
     --messages '[{"role":"user","content":[{"text":"hi"}]}]' \
     --query 'output.message.content[0].text' --output text
   ```
   Any reply means the account is ready. `AccessDeniedException` mentioning
   the use-case form means step 1 hasn't gone through yet. `Error 002` is an
   account-level block, usually billing - see the table below.
3. **Extend the teardown policy first:** `make account-apply`. The phase-1 role
   has an inline policy, and without `iam:DeleteRolePolicy` the 02:00 timer
   fails `AccessDenied` on it with the cluster still up.

### Verify

```bash
make eks-up
eval "$(make -s eks-env)"
make irsa-check                        # AWS_ROLE_ARN + token file present, NO static keys
make litellm-smoke                     # a real Claude reply through LiteLLM
```

Argo CD creates the `litellm` Deployment a few minutes after `eks-up` returns
(root app -> litellm app -> manifests), so both targets first wait for it via
`litellm-wait` - up to `LITELLM_WAIT` seconds, 300 by default - and then wait
for the rollout. Watch it happen with
`kubectl -n argocd get applications -w` if you want to see the waves land.

`irsa-check` is the lesson made visible: the pod holds a role ARN and a path to
a Kubernetes-issued token, and no AWS key of any kind.

### When it fails

| Symptom | Cause |
|---|---|
| `litellm` pod `ImagePullBackOff` | Image tag doesn't exist. Check the current stable tag and update `deployment.yaml` |
| Pod never starts: `serviceaccount "litellm" not found` | Tofu hasn't created the SA; check the `eks-up` output for `kubernetes_service_account_v1.litellm` |
| Smoke test: `AccessDeniedException ... not authorized to perform: sts:AssumeRoleWithWebIdentity` | Trust policy `sub`/`aud` doesn't match the SA, or the OIDC provider is missing. `tofu/litellm.tf` |
| Smoke test: `AccessDeniedException ... bedrock:InvokeModel` on a **foundation-model ARN in another region** | The inference profile routed the call to a region the policy doesn't list. Add it to `bedrock_profile_dest_regns` |
| Smoke test: mentions the use-case form or Marketplace | Prerequisite 1 or 2 hasn't been done |
| Any Bedrock call, from **any** identity and **any** model (including Amazon Nova), fails `ValidationException: Error 002: Access to Bedrock models is not allowed for this account` | Not IAM and not model access - the whole account is restricted. Seen 2026-09-22 after a credit card on the account expired. Fix the payment method in the Billing console; if that doesn't clear it within a day, open a free **Account and billing** support case. `aws freetier get-account-plan-state` returning `FREE` instead means the account needs upgrading to the paid plan |

### Direct-API fallback (while the Bedrock quota is low)

A new account's Bedrock quota for Haiku 4.5 is small, and AWS Support denied an
increase on 2026-09-23 pending usage history (case 179010504900511: "use the
current capacity, re-submit after a billing cycle"). So `claude-haiku` in
LiteLLM tries Bedrock first and, on failure, retries the same request against
the Anthropic API as `claude-haiku-direct`. Clients do not change.

The Anthropic key is the **one static credential** in this design. It is
prompted for and written straight into an in-cluster Secret; it never touches
git, Tofu state, or disk, and it dies with the cluster. So, once per `eks-up`:

```bash
make litellm-key                              # prompts (hidden), creates Secret, restarts the pod
make fallback-check                           # Secret exists, pod has it, ConfigMap and git do not
make litellm-smoke                            # prints which backend answered
make litellm-smoke LITELLM_MODEL=claude-haiku-direct   # the fallback path alone
```

`litellm-smoke` prints `x-litellm-model-id` (`bedrock-haiku` or
`anthropic-haiku`) and `x-litellm-attempted-fallbacks`. If it says
`anthropic-haiku` with `attempted-fallbacks: 1`, Bedrock failed and the
fallback served the request - look at the pod log for why before assuming it
was quota. A wrong IAM policy looks identical from the client side.

Skipping `make litellm-key` is safe: the Secret is `optional`, the pod starts,
Bedrock works, and only the fallback fails with `401 Missing Anthropic API Key`.

**Removing it** when the quota comes through: delete the `claude-haiku-direct`
entry and `fallbacks` from the ConfigMap, the `ANTHROPIC_API_KEY` env from the
Deployment, and the two Make targets. Nothing in Tofu or `tofu-account/`
changed, so nothing there to undo.

| Symptom | Cause |
|---|---|
| `401 Missing Anthropic API Key` after Bedrock fails | `make litellm-key` not run this session, or the pod started before the Secret existed (the target restarts it) |
| `anthropic-haiku` serves every request | Bedrock is failing every time. `kubectl -n litellm logs deploy/litellm` - `ThrottlingException` is quota; `AccessDenied` is IAM (`tofu/litellm.tf`) |
| `404 not_found_error` from Anthropic | The Anthropic model ID in the ConfigMap is wrong; it is not the Bedrock ID |

## Phase 2: ingress via the AWS Load Balancer Controller

The controller watches Ingress objects and creates a real ALB for each one -
**outside Tofu's state**. That is the whole risk of this phase: an ALB nobody
deleted keeps billing and blocks the VPC delete.

### One-time setup

Put your own address in `tofu/terraform.tfvars` (gitignored - never in git):

```bash
curl -s https://checkip.amazonaws.com          # your current public IP
echo 'alb_allowed_cidrs = ["A.B.C.D/32"]' >> tofu/terraform.tfvars
make account-apply                             # teardown identity: SG deletion
```

`account-apply` also converts lab-teardown's permissions from an inline user
policy to a **managed policy** (`eks-sandbox-teardown`, attached). Inline user
policies cap at 2048 bytes and phase 2 crossed it - the first attempt failed
with `LimitExceeded: Maximum policy size of 2048 bytes exceeded`. Managed
allows 6144. Nothing about the scope changes; check it after applying with:

```bash
aws iam list-attached-user-policies --user-name lab-teardown
```

Left empty, the security group is created with no ingress rule and the ALB
answers nobody. A home IP changes; when a demo stops working, check this first.

### What `eks-up` now creates

| Resource | Owner |
|---|---|
| `lab-sandbox-alb-controller` role + inline policy | Tofu (`tofu/alb-controller.tf`) |
| `aws-load-balancer-controller` Helm release, kube-system | Tofu |
| `lab-sandbox-alb-ingress` security group | Tofu, from `alb_allowed_cidrs` |
| The ALB, target groups, backend SG | **The controller**, at Ingress creation |

The IAM policy is upstream's, vendored verbatim at
`tofu/policies/alb-controller-v3.5.0.json`. Re-vendor it from the matching tag
whenever `alb_controller_chart_version` moves.

### Verify

```bash
make eks-up
eval "$(make -s eks-env)"
make alb-check       # controller Ready, `alb` IngressClass present, role ARN on the SA
```

### The teardown test, which is the point of this phase

Phase 0 proved the teardown works with nothing to clean up. Do this once, with
a real ALB live, before trusting the 02:00 timer with ingress in the cluster:

```bash
# 1. a throwaway Ingress that provisions an ALB.
#    Namespace `default` on purpose: it is excluded from the resource-limits
#    policy. The tag is pinned because disallow-latest-tag is NOT excluded
#    there and rejects :latest - which is the point of having it.
kubectl create deploy echo --image=python:3.12-slim --port=8080 \
  -- python -m http.server 8080
kubectl expose deploy echo --port=80 --target-port=8080
kubectl create ingress echo --class=alb --rule='/*=echo:80' \
  --annotation alb.ingress.kubernetes.io/scheme=internet-facing \
  --annotation alb.ingress.kubernetes.io/target-type=ip \
  --annotation alb.ingress.kubernetes.io/security-groups=lab-sandbox-alb-ingress \
  --annotation alb.ingress.kubernetes.io/manage-backend-security-group-rules=true

# 2. wait for an ADDRESS (2-3 minutes), then curl it from an allowed address
kubectl get ingress echo -w

# 3. tear down WITH the ALB live and watch the wait step do its job
make eks-down

# 4. prove nothing survived
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s-')].LoadBalancerName" --output text
aws ec2 describe-security-groups --filters Name=tag-key,Values=elbv2.k8s.aws/cluster \
  --query 'SecurityGroups[].GroupId' --output text
```

Clean up the test objects afterwards if you are not tearing down:
`kubectl delete ingress/echo svc/echo deploy/echo`.

Both queries must come back empty. If they don't, the resources are billing:
delete them by hand (see "Destroy fails with `DependencyViolation`" below) and
fix the ordering before running the timer again.

### When it fails

| Symptom | Cause |
|---|---|
| Ingress never gets an `ADDRESS` | Controller not running or not permitted. `make alb-check`, then `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| Controller logs `AccessDenied` on an `elasticloadbalancing:*` call | The vendored policy is older than the chart. Re-vendor from the chart's tag |
| Ingress events: `couldn't auto-discover subnets` | Public subnets lost `kubernetes.io/role/elb=1`. Tofu sets it in `tofu/vpc.tf` |
| ALB exists but times out from your machine | Your public IP changed, or `alb_allowed_cidrs` is empty. Update tfvars and `make eks-up` |
| ALB answers **504** from an allowed address | `manage-backend-security-group-rules=true` is missing. Naming a frontend SG stops the controller managing the node-side rules, so nothing lets the ALB reach the pods. Seen 2026-09-22 on the first live ALB |
| `make eks-down` stops on `DependencyViolation` for the VPC | An ALB or its SG outlived the Ingress. See "Failure recovery" |

## Failure recovery

### Destroy fails with `DependencyViolation` on the VPC

Load balancers or ENIs the controller did not clean up. Find and remove them,
then re-run:

```bash
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=lab-sandbox" \
  --query 'Vpcs[0].VpcId' --output text)

aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn" --output text
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
  --query 'NetworkInterfaces[].{id:NetworkInterfaceId,desc:Description,status:Status}' \
  --output table
```

Delete the load balancers first and give AWS a minute — their ENIs clear on
their own. Only detach and delete ENIs by hand if they persist with no owning
resource. Then `make eks-down` again.

### Argo Applications stuck Terminating

A finalizer is waiting on a resource that will not delete. The teardown script
strips finalizers after its timeout, but manually:

```bash
kubectl -n argocd patch application/<name> --type=merge \
  -p '{"metadata":{"finalizers":null}}'
```

### `make eks-up` fails partway

Safe to re-run — it is the same `tofu apply`. If the nodegroup failed on spot
capacity, check the AZ and consider adding instance types to
`node_instance_types`.

### State lock stuck

Native S3 locking leaves a `.tflock` object beside the state key. If a run was
killed mid-apply:

```bash
aws s3api list-objects-v2 --bucket swares-lab-tofu-state --prefix eks-sandbox/
aws s3api delete-object --bucket swares-lab-tofu-state \
  --key eks-sandbox/terraform.tfstate.tflock
```

Only do this when certain no other apply is running.

### Suspected orphans / unexpected bill

```bash
make cost
aws resourcegroupstaggingapi get-resources --region us-east-1 \
  --tag-filters Key=Repo,Values=swares/HomeLab-aws Key=Lifecycle,Values=ephemeral \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

Everything `tofu/` creates carries `Lifecycle=ephemeral` via `default_tags`, so
anything this lists after a teardown is *probably* an orphan. Confirm before
acting: the tagging index lags, and can keep listing a resource for a while
after it is deleted. On 2026-09-21 it returned a subnet that
`aws ec2 describe-subnets --subnet-ids <id>` showed did not exist
(`InvalidSubnetID.NotFound`). Check every hit with the matching `describe-*`
call. The `Lifecycle` filter
matters: the permanent budget in `tofu-account/` carries the same `Repo` tag
but `Lifecycle=permanent`, and must not show up as a leftover.

## Verifying before the first real session

- [ ] `make eks-up` then `make eks-down` twice, cleanly, back to back
- [ ] `resourcegroupstaggingapi` returns nothing after teardown
- [ ] Permanent budget applied (`make account-apply`) and its lock file committed
- [ ] `install-teardown-timer.sh` completed and authenticated as `lab-teardown`
- [ ] A real `systemctl start eks-teardown.service` tore down a live cluster
- [ ] `make eks-down` with no cluster present exits 0
- [ ] Break-glass envelope filled, sealed, stored off-site
- [ ] Drill A passed: teardown from a machine with no AWS credentials
