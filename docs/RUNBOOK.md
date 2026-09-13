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

### 2. tfvars

```bash
cp tofu/terraform.tfvars.example tofu/terraform.tfvars
# set budget_email
make init
```

### 3. Confirm the SNS subscription

The first apply sends a confirmation email. Until you click it, the
subscription sits `PendingConfirmation` and the budget alarm delivers nothing.

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
make eks-up        # ~15 min
make argocd-ui     # password + port-forward :8080
make eks-down
```

Verify after `eks-up`:

```bash
kubectl get nodes                          # 2 Ready
kubectl -n argocd get applications         # root, kyverno, kyverno-policies Synced/Healthy
kubectl get clusterpolicies                # 3, all Ready
```

There is no ingress and no public endpoint for Argo. The UI is reached by
port-forward only. This is deliberate — see `CLAUDE.md`.

## The teardown host problem

The nightly timer needs a host with `tofu`, the `aws` CLI, and network reach to
S3 and the EKS API. `aws` is required, not optional: the helm provider mints a
token by shelling out to `aws eks get-token` during destroy.

**Host: `n150-2.lab.home.arpa`** (decided 2026-09-12).

Not `xu3-1`, despite it being the obvious choice as the build agent. The Odroid
XU3 is an Exynos 5422 — Cortex-A15/A7, ARMv7, 32-bit — and AWS publishes CLI v2
for `x86_64` and `aarch64` only. There is no 32-bit ARM build, so no
`eks get-token`, so no teardown. (If `xu3-1` is ever needed anyway, AWS CLI v1
via `pip install awscli` is pure Python and still supports `eks get-token`;
it is in maintenance mode but adequate.)

On `n150-2`: the repo goes to `/opt/HomeLab-aws`, credentials to
`/etc/eks-sandbox/teardown.env` at `0400` owned by the service user, and the
IAM identity is scoped to teardown — it does **not** need the permissions you
use to create the cluster interactively.

```bash
sudo cp systemd/eks-teardown.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now eks-teardown.timer
systemctl list-timers eks-teardown.timer
```

Test it once by hand before trusting it:

```bash
sudo systemctl start eks-teardown.service
journalctl -u eks-teardown.service -f
```

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
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Repo,Values=swares/HomeLab-aws \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

Every resource this module creates carries `Repo=swares/HomeLab-aws` via
`default_tags`, so anything listed there and not in state is an orphan.

## Verifying before the first real session

- [ ] `make eks-up` then `make eks-down` twice, cleanly, back to back
- [ ] `resourcegroupstaggingapi` returns nothing after teardown
- [ ] SNS subscription confirmed
- [ ] Timer fires on n150-2 and the service user's credentials work
- [ ] `make eks-down` with no cluster present exits 0
- [ ] Break-glass envelope filled, sealed, stored off-site
- [ ] Drill A passed: teardown from a machine with no AWS credentials
