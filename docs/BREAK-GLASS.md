# Break-glass envelope — AWS segment

**This file is the template. It contains no secrets and never should.**
The filled copy lives offline — printed, or on an encrypted USB stored somewhere
other than the house. If the filled copy is ever committed, treat every
credential in it as compromised and rotate all of them.

Companion to `swares/HomeLab/docs/BREAK-GLASS.md`, which covers the lab. Keep
the two in the same envelope. They fail independently but you will want both in
the same bad afternoon.

## Why this exists, and why it is different from the lab's

The lab envelope answers: *the H4 is gone, how do I decrypt my backups?* Every
value in it can be read off a running machine, which is why
`print-offline-envelope.sh` can harvest them.

This one answers a different question: **AWS has locked me out, and something in
there is still billing.** Almost nothing here is readable from a machine — root
passwords, MFA seeds and security answers live in the AWS console, in your
password manager, and in your head, and no AWS API returns them. So
`scripts/print-aws-envelope.sh` **prompts** for each value rather than
harvesting it, then renders and shreds. Anything skipped prints as a ruled blank
to fill in by hand.

The asymmetry that matters: losing access to the lab costs you data. Losing
access to AWS costs you *money, continuously, with no way to stop it*. An EKS
control plane you cannot reach is $73/month — $438/month if its Kubernetes
version has slipped into extended support — and it does not stop because you
cannot log in.

## The failure this is really for

Not "I forgot my password." The realistic lockout is **the virtual MFA device is
gone** — phone lost, wiped, or replaced — and:

- AWS shows the MFA secret key **exactly once**, at enrolment. If you only
  scanned the QR code, that secret exists nowhere but on the lost device.
- Root recovery requires the **email account** on the AWS account. If that
  mailbox has its own MFA, you now have two locked doors in series.
- If email recovery fails, the remaining path is an AWS Support identity
  verification — a **phone call to the number on the account**. If that number
  is stale, you are into a slow manual process measured in days, not hours.
- Meanwhile the cluster bills.

Item 4 below is the single highest-value line in this document.

## Contents

Run `scripts/print-aws-envelope.sh` on a machine you trust and answer the
prompts from the source column. Nothing is echoed and nothing is written outside
`/dev/shm`. Skip anything you would rather write by hand — it prints as a ruled
blank. Do not paste any of these into a terminal that logs, a chat, or a file
inside the repo.

| # | What | Source | Without it |
|---|------|--------|-----------|
| 1 | **AWS account ID** (12 digits) and account alias | Console top-right menu, or `aws sts get-caller-identity` | The IAM sign-in page cannot be reached — it is keyed on account ID or alias, not on your email |
| 2 | **Root email address**, and which mailbox provider it lives in | Your own records | No root login, and no password reset — every recovery path starts with this mailbox |
| 3 | **Root password** | Your own records; exists nowhere recoverable | No root login |
| 4 | **Root MFA secret (base32 seed), or the recovery codes** — transcribe in full | Shown **once** at MFA enrolment. Not retrievable afterwards. If you did not record it, re-enrol now (see below) | **The main lockout.** A lost phone becomes an AWS Support case measured in days while the cluster bills |
| 5 | **Phone number registered on the account** | Console → Account settings → Contact information | AWS Support's identity verification calls this number. A stale number closes the last recovery path |
| 6 | **Security challenge questions and answers** | Console → Account settings → Configure security challenge questions | Used during root recovery. If unset, set them now — this is a free recovery path most people skip |
| 7 | **Break-glass IAM user**: username, password, and its MFA secret | Created by you; see below. Not the identity you use daily | Root is your only way in, which means item 4 is a single point of failure |
| 8 | **Teardown IAM access key ID and secret** — the one on `n150-2` | `/etc/eks-sandbox/teardown.env` on `n150-2.lab.home.arpa` | Cannot stop the billing from a clean machine if both the lab and your workstation are unavailable |
| 9 | **Password manager recovery kit**, if items 2–7 live in one | Your password manager's own export/recovery process | Items 2–7 are unreachable. The envelope is only as good as the thing holding what is not on it |

### Item 4 — do this now, not during the incident

If you enrolled MFA by scanning a QR code and did not record the secret, you
have no second copy. Fix it before anything else in this document matters:

1. Console → Security credentials → deactivate the existing MFA device.
2. Re-enrol. On the enrolment screen choose **"Show secret key"**.
3. Write that base32 string into the envelope.
4. Confirm the new device works **before** closing the page.

Do the same for item 7's user. Two accounts, two secrets, both on paper.

A hardware key (YubiKey) is a reasonable alternative for root, but it does not
remove the need for this line — it replaces it with "where the spare key is,"
which then becomes the thing written down. AWS supports multiple MFA devices per
root user; enrolling two and recording the location of both is the strongest
version of this.

### Item 7 — why a break-glass IAM user exists at all

The AWS analogue of the lab envelope's item 7, and found the same way: every
other line here assumes you can already authenticate.

Items 1–6 all route through root. Root is one password and one MFA device. If
that device is gone, every path in this envelope converges on the same AWS
Support case.

So: a second IAM user, `break-glass`, with `AdministratorAccess`, its own
password, its own MFA device (a *different* physical device from your daily
one), console access only, and **no access keys**. Never used day to day, so
never in a browser session, never in a shell history, never in a config file.

```bash
# Create it (you do this yourself — do not script it, do not paste the password anywhere)
aws iam create-user --user-name break-glass
aws iam attach-user-policy --user-name break-glass \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
# Then set a console password and enrol MFA in the console, recording the secret.
```

Console access only, no access keys, is deliberate: an access key on paper is a
credential that works from anywhere with no second factor. A console password
plus MFA is not.

### Item 8 — the "stop the bleeding" credential

This one has a narrower job than the rest: from any machine with network access,
destroy whatever is running. It is not a recovery credential, it is a *billing
kill switch*.

It is already on `n150-2` at `/etc/eks-sandbox/teardown.env`. It is in the
envelope because the scenario is "the lab is also unavailable."

Scope it to teardown. It does not need the permissions you use to create the
cluster interactively, and an over-scoped key on paper is worse than a
well-scoped one.

## Reference values — not secret, but needed under stress

| What | Value |
|------|-------|
| Region | `us-east-1` |
| Cluster name | `lab-sandbox` |
| State bucket | `s3://swares-lab-tofu-state`, key `eks-sandbox/terraform.tfstate` |
| Git remote | `https://github.com/swares/HomeLab-aws.git` (public — clone needs no credential) |
| Teardown host | `n150-2.lab.home.arpa` |
| Teardown credentials path | `/etc/eks-sandbox/teardown.env` |
| IAM sign-in URL | `https://<ACCOUNT-ID-OR-ALIAS>.signin.aws.amazon.com/console` |
| Resource tag for orphan sweep | `Repo=swares/HomeLab-aws` |

The git remote being **public** is load-bearing here: in a recovery you can
clone the repo and run teardown without needing any credential to reach the
code. Only item 8 is required.

## If you are locked out right now

In order. Stop as soon as one works.

1. **Can you still reach anything with item 8?** From any machine:
   `git clone https://github.com/swares/HomeLab-aws.git && cd HomeLab-aws`,
   put item 8 in the environment, `make eks-down`. This stops the billing
   without solving the lockout. Do this first — the rest can take days.
2. **Break-glass IAM user (item 7).** Sign in at the URL above with the account
   ID or alias, not the email address.
3. **Root, with items 2–4.**
4. **Root password reset** via the item 2 mailbox.
5. **AWS Support identity verification**, using items 5 and 6. This is the slow
   path. Have the account ID and the registered phone in hand.

If none of these work, the remaining lever is the payment method: cancelling the
card stops the charges and eventually the account, and loses everything in it.
Nothing in this sandbox is irreplaceable — that is by design — but write down
that you considered it, because under pressure it looks more drastic than it is.

## Currency

The envelope is wrong the moment a credential rotates and nobody reprints it.
Log every change here.

| Date | What changed | Envelope updated? |
|------|--------------|-------------------|
| 2026-09-12 | Envelope created alongside phase 0 | `[ ]` |

Re-verify the non-secret half whenever the account changes:

```bash
aws sts get-caller-identity                      # item 1
aws iam list-account-aliases                     # item 1
aws iam get-account-summary | grep AccountMFAEnabled   # 1 = root MFA on
aws iam list-users --query 'Users[?UserName==`break-glass`]'   # item 7 exists
```

Contact info (items 5 and 6) is console-only — check it by eye, at the same time.

## The drill

An untested envelope is a guess. The lab's item 7 was found by drilling, not by
reasoning, and the same will be true here.

**Drill A — the billing kill switch.** The one that actually matters.

1. `make eks-up`. Let it come up fully.
2. Move to a machine that has never touched this account — no `~/.aws`, no
   browser session. A fresh VM, or a guest account.
3. Using **only** the envelope: clone the public repo, configure item 8, run
   `make eks-down`.
4. Confirm with the orphan sweep in `RUNBOOK.md` that nothing remains.

What this proves: you can stop the bleeding without your workstation, without
the lab, and without solving the lockout. Time it. If it takes more than about
fifteen minutes, something in the envelope is missing or wrong.

**Drill B — the break-glass login.** Quarterly, and after any MFA change.

Sign in as item 7 from a private browser window. Confirm the MFA secret on paper
actually generates an accepted code — transcription errors in a base32 string
are silent until the moment you need it.

**Drill C — root recovery, on paper only.** Do not actually trigger AWS Support.
Read items 2 through 6 aloud and confirm each is present, current, and legible.
Check the phone number against the console. Confirm you can still receive mail
at the item 2 address.

### What the drill will probably find

Best guess, based on where the lab's drills found gaps: the MFA secret for item
4 was never recorded, because scanning a QR code is the path of least resistance
and AWS does not force you to save the seed. Assume that is true until Drill B
proves otherwise.
