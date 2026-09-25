# Sandbox backlog — started 2026-09-23

**Open work that is not on the roadmap goes here.** Phases 0–3 live in the
README roadmap. Everything else goes in this file: account problems, AWS
requests, hygiene, follow-ups found during a session. If you are tempted to
start a list somewhere else, add a pointer to this file instead.

**When you finish something**, tick it here. **When you find something**, add
it here. Every item is a `### N.M` entry with checkboxes under it. When an
entry is complete, strike through its title and mark the heading **DONE**.

Ordered by **what happens if it is ignored**, not by effort. In this repo the
worst outcomes are money spent with no way to stop it, and losing access to
the account.

`make backlog` checks this file's bookkeeping (`scripts/backlog-audit.py`,
vendored from the lab). It fails if a checkbox has no owning entry or a
section-level bullet cannot be ticked. It also fails if any open box sits
under a heading that claims completion: the ratchet is `--max-orphans 0`,
because this file starts clean and should stay that way.

---

## 1. Account access and billing

### 1.1 Bedrock is blocked for the whole account (Error 002) — **waiting on AWS**

Every Bedrock call fails with `ValidationException: Error 002: Access to
Bedrock models is not allowed for this account`. That holds for every model,
including Amazon Nova Micro, and for every identity, including root. First seen
2026-09-22 after the card on the account expired; still present 2026-09-23.
This is separate from the quota denial in 2.1. Raised as a reply on support
case 179010504900511 on 2026-09-23.

Until it clears, `claude-haiku` is served only by the direct-API fallback, so
all Claude spend is on the Anthropic account (see 1.3).

- [ ] AWS replies on the case, and the answer is recorded here
- [ ] As admin, the RUNBOOK phase-1 `converse` call returns text
- [ ] `make litellm-smoke` reports `bedrock-haiku` with no fallback attempted
- [ ] RUNBOOK Error 002 row and README phase-1 status updated to say it cleared

### 1.2 Day-to-day CLI work runs as the root user — **plan written, decisions open**

`~/.aws/config` on n150-2 uses `aws login` as `root`. Root can close the
account or change its MFA, and routine use keeps the recovery credential
exposed. The plan: an IAM Identity Center admin user (organization instance,
MFA, `AdministratorAccess`, 8-hour sessions) as the `[default]` profile, with
root kept for recovery only. The step-by-step plan is a separate doc, "AWS
sandbox: moving CLI work off the root user". No repo file needs to change if
the new profile is `[default]`.

Do it only while **no cluster is running**: a cluster created by root gives
cluster-admin to root alone.

- [ ] Decisions in the plan made (Identity Center vs IAM user, session length, item 7)
- [ ] Identity Center enabled and the admin user can sign in with MFA
- [ ] n150-2 `[default]` is the SSO profile; `aws sts get-caller-identity` shows `AWSReservedSSO_AdministratorAccess_`
- [ ] Root CLI session logged out and removed from `~/.aws`
- [ ] Root has no access keys (IAM → Security credentials, as root)
- [ ] README quickstart and RUNBOOK gain a login step: `aws sso login --use-device-code`
- [ ] Break-glass envelope reviewed for the new identity, and re-printed if changed

### 1.3 Anthropic spend is invisible to the AWS Budget — **open**

The direct-API fallback bills the Anthropic account, which `tofu-account/`'s
budget cannot see. While 1.1 lasts, that is all Claude spend. Since phase 2a
LiteLLM requires a per-cluster master key and is reachable from outside only
from `alb_allowed_cidrs`, so spend needs the key. The limit below is the
backstop for a leaked key or a runaway client, not the first line.

- [ ] Monthly spend limit set on the Anthropic key's workspace in the Anthropic Console
- [ ] Usage alert set there, to the same address as the AWS Budget

### 1.4 Break-glass Drill A has not been run — **open**

README marks phase 0 complete except for this. Drill A is the billing kill
switch: tearing down from a machine with no AWS credentials, using only the
envelope. Until it passes, the envelope's first recovery step is untested.
Procedure: `docs/BREAK-GLASS.md` → Drill A.

- [ ] Drill A run, result recorded in `docs/BREAK-GLASS.md`
- [ ] README phase-0 status updated

---

## 2. Requests to AWS with lead time

### 2.1 Resubmit the Bedrock quota request for Haiku 4.5 — **after the October bill**

Denied 2026-09-23 on case 179010504900511 for lack of usage history ("continue
using the other accessible models", "wait for the next billing cycle"). That
advice cannot be followed while 1.1 blocks every model, so this is gated on 1.1.
A reminder fires on 2026-11-03.

- [ ] 1.1 cleared, so the account can actually build Bedrock usage
- [ ] October bill closed
- [ ] Resubmitted: one model, a modest tokens-per-minute increase, citing usage since September

### 2.2 G-instance vCPU quota for phase 3 — **not requested**

New accounts often start at 0 vCPUs for G instances, and a decision takes days.
Given how 2.1 went, expect a first denial. Request it only once the account has
history, but well before phase 3 starts.

- [ ] Current value checked: Service Quotas → EC2 → "Running On-Demand G and VT instances" and the spot equivalent
- [ ] Requested, sized to phase 3's node pool, once 1.1 is cleared

---

## 3. Repo and tooling hygiene

### 3.1 RUNBOOK "Verifying before the first real session" is all unticked — **open**

All eight boxes at the end of `docs/RUNBOOK.md` are `- [ ]`. But README says
phase 0 is complete, and sessions have run since 2026-09-21. Either some of
these are true and unticked, or README overstates phase 0. This is the same
pattern the lab's audit script was written to catch.

- [ ] Each of the eight checked against reality and ticked, or copied here as open work
- [ ] README phase-0 status matches the result

### 3.2 Remove the direct-API fallback once Bedrock serves — **gated on 1.1 and 2.1**

The fallback is scaffolding while Bedrock is blocked. Removing it removes the
repo's only static credential. Removal steps are in RUNBOOK → Direct-API
fallback → "Removing it".

- [ ] Bedrock has served `claude-haiku` in normal use for a full session
- [ ] Decide: remove the fallback, or keep it as deliberate redundancy
- [ ] If removed: ConfigMap entry, Deployment env, `litellm-key` and `fallback-check`, and the docs, in one PR

### 3.3 Windows working copy shows every file modified — **open**

The Windows clone reported 34 files modified whose only change is line endings
(CRLF vs LF). `core.autocrlf` is unset there. A per-clone setting fixes one
machine; a committed `.gitattributes` fixes every clone.

- [ ] Decide: `core.autocrlf` on the Windows clone, or `.gitattributes` in the repo (`* text=auto eol=lf`)
- [ ] Windows clone `git status` is clean after a fresh checkout

### 3.4 k3s's bundled kubectl warns on every sandbox command — **cosmetic**

On n150-2, `kubectl` is the k3s wrapper, which tries
`/etc/rancher/k3s/config.yaml` before honouring `KUBECONFIG`. It prints
`WARN … permission denied` three times per call. It is harmless, but it buries
real output in every `make` target.

- [ ] Decide: a standalone `kubectl` for the sandbox (e.g. `KUBECTL ?=` in the Makefile), or accept the noise

### 3.5 The LiteLLM ALB is HTTP only, so the master key crosses the internet in cleartext — **accepted for now**

Chosen in phase 2a. It's acceptable because the security group admits only
`alb_allowed_cidrs` (your own address), so a sniffed key is useless from
anywhere else, and the key is replaced every night. HTTPS needs an ACM
certificate, which needs a domain for DNS validation.

- [ ] Decide on a domain (or subdomain) for the sandbox
- [ ] ACM certificate in `tofu-account/` (permanent, free), DNS-validated
- [ ] 443 listener + SG rule; `alb.ingress.kubernetes.io/certificate-arn` and ssl-redirect on the Ingress; port 80 closed

---

## 4. Done

Kept for the reasoning; nothing here needs action.

### 4.1 ~~Claude through LiteLLM while Bedrock is unavailable~~ — **DONE 2026-09-23**

Bedrock primary, Anthropic API fallback on the same `claude-haiku` name. The key
is prompted per session into an in-cluster Secret. Verified live: Bedrock
refused with Error 002, and the direct path answered with
`attempted-fallbacks: 1`.

- [x] Fallback config, `litellm-key`, `fallback-check` (PR #12)
- [x] Smoke test reports the backend and shows real errors; non-API keys refused (PR #13)

### 4.2 ~~Teardown could report load balancers gone before their ENIs were~~ — **DONE 2026-09-23**

- [x] The wait also counts ELB-owned network interfaces (PR #11)
- [x] A failed AWS query holds the wait instead of reading as 0; the VPC lookup retries (PR #14)
