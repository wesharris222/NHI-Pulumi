# Saviynt + Pulumi Demo — Progress Tracker

> **Purpose of this file:** This is the working roadmap for the demo. Update statuses as you build. When picking up in a new Claude Code session, this file (plus README.md and ARCHITECTURE.md) gives full context to continue without re-explaining the design.

## Project State: 🟢 BROKER IGA-SIDE VALIDATED — Demo flow proven through the broker's API. PAM-side (Phase 5) next.

Last updated: 2026-05-11 — IGA config Section A/B/C verified against tenant; both demo paths (dev auto-approve, prod manual approve via wes-approver) confirmed working. `automatedProvisioning: true` on the SS verified to auto-close provisioning tasks on approval — broker doesn't need updateTasks logic. SS-level Access Remove Workflow bound to OOB auto-approval workflow; REMOVE createrequest works cleanly for demo state resets. `scripts/test_iga_flow.sh full` validated end-to-end against live tenant (after fixing a stdout-pollution bug in submit_request that was masquerading as a Saviynt "transient error"). Broker IGA-endpoint smoke test (`scripts/test_broker.sh`) restructured to validate auth + /preflight (dev & prod) without touching unconfigured PAM endpoints.

---

## Demo Goal

Show that Saviynt's converged IGA + PAM provides governance value that standalone key vaults (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault) cannot. The demo runs an AWS EC2 deployment pipeline twice with the same user but different target environments. Dev auto-approves; prod requires manual approval via Saviynt. Both runs end with the EC2 instance's SSH key and OS credentials vaulted in Saviynt PAM as a registered Non-Human Identity (NHI) with full ownership metadata.

The story: hundreds of static pipeline secrets → one governed bootstrap credential, with everything else dynamically issued and identity-bound.

---

## Architecture Summary

```
GitHub repo (free)
  │ push / workflow_dispatch
  ▼
GitHub Actions (self-hosted runner on Ubuntu VM)
  │ HMAC-signed requests
  ▼
FastAPI Broker (localhost:18443 on Ubuntu VM)
  │ Saviynt SA bearer token
  ▼
Saviynt EIC tenant (existing)
  │ entitlement check, access request, PAM checkout, account creation
  ▼
Returns: approval decision, AWS creds, NHI registration confirmation

Pulumi (Python, run by GitHub Actions)
  │ uses AWS creds checked out from Saviynt PAM
  ▼
AWS us-east-2 (free tier t2.micro Ubuntu)
  │ creates EC2 + keypair + OS user
  ▼
Outputs: instance_id, public_ip, ssh_private_key, os_username, os_password
  │
  ▼
Pipeline calls broker /register-nhi → vaults credentials in Saviynt PAM
```

**Bootstrap secrets (irreducible):**
1. Saviynt SA password — broker `.env`
2. HMAC secret — GitHub repo secret + broker `.env`

**Everything else** is dynamically issued by Saviynt at pipeline runtime.

---

## Build Phases

### Phase 0 — Scaffolding ✅
- [x] Project directory structure
- [x] PROGRESS.md (this file)
- [x] README.md (top-level overview)
- [x] ARCHITECTURE.md (detailed flow + diagrams)
- [x] TALK_TRACK.md (demo narrative including two-standing-secrets discussion)
- [x] .gitignore
- [ ] *(complete after first test pass)* Update with any tenant-specific corrections

### Phase 1 — Broker (FastAPI) 🟡 IN PROGRESS — IGA half coded, awaiting live validation
**Location:** `broker/`
**Goal:** Saviynt-facing service with five endpoints, all HMAC-authenticated.

- [x] `broker/settings.py` — configurable Saviynt URL, endpoint paths, account names
- [x] `broker/.env.example` — bootstrap secret template (DEMO_APPROVER=wes-approver defaulted)
- [x] `broker/saviynt_client.py` — Saviynt API wrapper. IGA flows (login, user_has_entitlement, create_access_request, fetch_request_status, cancel_pending_request) aligned with verified contracts. PAM flows (getAccount, LLT, checkout, checkin, createAccount) coded but not validated against live tenant (Phase 5).
- [x] `broker/auth.py` — HMAC validation middleware
- [x] `broker/main.py` — FastAPI app with all five routes wired
- [x] `broker/models.py` — Pydantic request/response models
- [x] `broker/requirements.txt`
- [x] `broker/README.md` — local run instructions
- [x] `scripts/test_broker.sh` — curl-based local test harness (subcommands: auth/dev/prod/status/full; PAM endpoints excluded until Phase 5)

**Validation status (broker code paths):**
- [x] `/healthz` + HMAC auth modes (unsigned → 401/422, bad sig → 401) — validated 2026-05-11
- [x] `/preflight` (dev path, status=ok) — validated 2026-05-11
- [x] `/preflight` (prod path, status=pending → manual approve → status=approved) — validated 2026-05-11 (req 7690 lifecycle on tenant)
- [ ] `/checkout-aws` / `/register-nhi` / `/checkin-aws` — blocked on Phase 5 PAM config

**Validation findings (2026-05-11):**
- Stale `ENT_DEPLOY_DEV=Deploy-EC2-Dev` / `ENT_DEPLOY_PROD=Deploy-EC2-Prod` in broker/.env (from before the rename to `EC2Deploy-{Dev,Prod}`) — cleared so `settings.py` verified defaults take effect. Anyone copying from an older `.env.example` will hit this; the in-repo `.env.example` no longer carries these lines.
- Broker reads `.env` at import; `--reload` watches Python files but not always `.env`, so config changes need a hard restart.

**Endpoints:**
| Method | Path | Purpose |
|---|---|---|
| POST | `/preflight` | Check entitlement; if missing, create access request |
| GET | `/preflight/status/{request_id}` | Poll approval status |
| POST | `/checkout-aws` | Check out AWS IAM credentials from Saviynt PAM |
| POST | `/register-nhi` | After deploy, vault EC2 SSH key and OS creds |
| POST | `/checkin-aws` | Return AWS creds, trigger rotation |

**Saviynt API endpoints used (from validate_secret.py):**
- ✅ `POST /ECM/api/login`
- ✅ `POST /ECM/api/v5/getAccounts` (with `advsearchcriteria.name`)
- ✅ `POST /ECM/oauth/access_token_withissuer` (LLT generation)
- ✅ `POST /ECMv6/api/pam/account/checkout` (with TASK_NOT_FOUND polling)

**Saviynt API endpoints to confirm against actual tenant:**
- ⚠️ `POST /ECM/api/v5/createRequest` (or `createUserAccessRequest`) — for prod approval workflow
- ⚠️ `GET /ECMv6/api/v5/fetchRequestStatus` — polling
- ⚠️ `POST /ECM/api/v5/createAccount` — NHI registration
- ⚠️ `POST /ECMv6/api/pam/account/checkin` — credential checkin

> *Mark these confirmed in Phase 5 after live tenant testing.*

### Phase 2 — Pulumi Program ⏳
**Location:** `pulumi/`
**Goal:** Python Pulumi project that creates an EC2 instance and outputs credentials for vaulting.

- [ ] `pulumi/Pulumi.yaml` — project metadata
- [ ] `pulumi/Pulumi.dev.yaml` — dev stack config
- [ ] `pulumi/Pulumi.prod.yaml` — prod stack config
- [ ] `pulumi/__main__.py` — main program: VPC lookup, security group, SSH keypair generation, EC2 instance, OS user via user-data
- [ ] `pulumi/requirements.txt`
- [ ] `pulumi/README.md` — manual run instructions for testing

**Key design points:**
- SSH keypair generated locally with `cryptography` library, public half registered with EC2 via `aws.ec2.KeyPair`
- OS user created via cloud-init user-data with random password (also output)
- Stack outputs: `instance_id`, `public_ip`, `ssh_private_key` (marked secret), `os_username`, `os_password` (marked secret)
- Free-tier compliant: t2.micro, Ubuntu 22.04 LTS AMI in us-east-2
- Security group: SSH (22) from anywhere for demo simplicity (call this out in talk track as a demo simplification)

### Phase 3 — GitHub Actions Workflow ⏳
**Location:** `github-actions/`
**Goal:** Workflow that orchestrates broker calls and Pulumi runs.

- [ ] `github-actions/deploy-ec2.yml` — main workflow
- [ ] `github-actions/README.md` — setup instructions (secrets to configure, runner setup)

**Workflow structure:**
1. `workflow_dispatch` input: `target_env` (dev or prod), `requesting_user` (optional override)
2. Job: `preflight` — call broker `/preflight`, poll `/preflight/status` until approved or timeout
3. Job: `checkout-aws` — call broker `/checkout-aws`, set AWS creds as masked env vars
4. Job: `pulumi-deploy` — `pulumi stack select dev|prod`, `pulumi up`
5. Job: `register-nhi` — extract Pulumi outputs, call broker `/register-nhi`
6. Job: `cleanup` — always runs, calls `/checkin-aws`

**Secrets needed in GitHub repo:**
- `BROKER_URL` (e.g., `http://localhost:18443` if self-hosted runner)
- `BROKER_HMAC_SECRET`
- `PULUMI_ACCESS_TOKEN`

### Phase 4 — Saviynt Tenant Configuration 🟢 IGA SIDE DONE (PAM still pending)
**Location:** `saviynt-config/`
**Goal:** Step-by-step guide for setting up the tenant objects this demo needs.

- [x] `saviynt-config/01-application-onboarding.md` — Pulumi-Pipeline-AWS Security System + Endpoint **(verified in tenant)**
- [x] `saviynt-config/02-entitlements.md` — EC2Deploy-Dev + EC2Deploy-Prod under EntDev/EntProd types **(verified; workflow architecture corrected from per-type to single SS-level with If-Else)**
- [x] `saviynt-config/03-roles-and-users.md` — wes-dev with EC2Deploy-Dev directly assigned, wes-approver for prod approvals **(verified; payload shape and requestor=beneficiary rule corrected)**
- [x] `saviynt-config/04-aws-cross-account.md` — Saviynt ↔ customer-AWS trust via CloudFormation Stack (Security Analyzer + IGA + PAM template); AWS Connection in Saviynt **(written 2026-05-11; not yet executed against tenant)**
- [x] `saviynt-config/05-aws-iam-pam-endpoint.md` — `AWS-IAM-Endpoint` SS+Endpoint; `pulumi-deployer` IAM user; PAM onboarding with rotate-on-checkin policy; end-to-end /checkout-aws → /checkin-aws test **(written 2026-05-11; not yet executed against tenant)**
- [ ] `saviynt-config/00-OVERVIEW.md` — *not written yet, optional*
- [ ] `saviynt-config/06-aws-ec2-nhi-endpoint.md` — EC2 instance NHI registration *(deferred — broker push-based for v1, can stay governance-only)*
- [ ] `saviynt-config/07-test-checklist.md` — pre-demo validation steps

### Phase 5 — Local Testing & Saviynt Endpoint Confirmation ⏳
**Location:** `scripts/`

- [ ] Run broker locally, hit each endpoint with curl test harness
- [ ] Confirm/correct Saviynt API paths in `broker/settings.py`
- [ ] Document any tenant-specific quirks found
- [ ] Update PROGRESS.md with confirmed endpoints

### Phase 6 — End-to-End Demo Validation ⏳
- [ ] Run dev deployment end-to-end → success path
- [ ] Run prod deployment → pause → approve in Saviynt UI → resume → success
- [ ] Verify NHI is registered in Saviynt PAM with correct metadata
- [ ] Verify SSH key checkout from Saviynt PAM actually grants SSH access to the EC2 instance
- [ ] Tear down EC2 instance via `pulumi destroy`

### Phase 7 — Polish & Recording ⏳
- [ ] Demo script with timing
- [ ] Screenshots / video walkthrough
- [ ] Slide deck talking points

---

## Open Questions / Decisions Pending

| Question | Status | Notes |
|---|---|---|
| Exact Saviynt endpoint paths for createRequest, fetchRequestApprovalDetails, getEntDetailsforUsers, getAccounts | ✅ Verified in tenant | All under `/ECM/api/v5/`. Captured in `saviynt-config/03-roles-and-users.md` settings.py block. |
| createrequest payload shape | ✅ Verified | `entitlement` is array-of-objects; `accountname` required; `requestor` must equal beneficiary for manual approval to fire |
| Workflow architecture (per-type vs SS-level + If-Else) | ✅ Resolved | One SS-level workflow with If-Else on `entitlement.entitlementtypekey.entitlementname` is what actually works; per-type bindings don't fire for entitlement add requests in this tenant |
| Auto-completion of provisioning tasks for disconnected endpoint | ✅ Resolved | `automatedProvisioning: true` on the SS auto-closes tasks on approval (verified 2026-05-11). Broker does NOT need updateTasks logic. |
| Custom property mapping for NHI metadata (which customproperty fields hold owner, env, etc.) | ⚠️ To decide in Phase 4 PAM section | Will document in `saviynt-config/04-pam-endpoint.md` (not yet written) |
| Whether to add a quarterly NHI certification campaign as a Phase 7 extension | 💭 Optional | Strong story but adds Saviynt config complexity |
| AWS region failover (us-east-2 only?) | ✅ us-east-2 only | Confirmed by user |

---

## Known Limitations & Demo Caveats

These are intentional and called out in TALK_TRACK.md:

1. **Two standing secrets** — Saviynt SA password + HMAC secret. Honest framing: "every secrets system has irreducible bootstrap credentials; we've collapsed hundreds → two."
2. **Security group allows SSH from 0.0.0.0/0** — demo simplification. In prod you'd lock to bastion/VPN CIDR.
3. **Self-hosted GitHub runner on same VM as broker** — convenient but not realistic for enterprise. Production would have runners in separate security boundary.
4. **AWS IAM credentials in Saviynt PAM** — the broker still needs *some* way to get the Saviynt SA credential. The reduction is hundreds → one, not zero.
5. **No real rotation triggered during demo** — Saviynt rotation policy is *configured* and visible in UI, but we don't wait for an actual rotation cycle during the demo.

---

## Files to Hand to Claude Code Next

When you continue this work:
1. Read `PROGRESS.md` (this file) — the roadmap
2. Read `README.md` — the high-level pitch
3. Read `ARCHITECTURE.md` — the detailed design
4. Read `TALK_TRACK.md` — what you're saying during the demo
5. Read `CLAUDE.md` — **critical contracts and verified architecture** (corrected after live testing)
6. Pick up at the first unchecked Phase 1 (Broker) item

Hand Claude Code the entire `saviynt-pulumi-demo/` folder and it will have full context.

---

## Phase 4 — Verified IGA Configuration Snapshot (2026-05-08)

This section records what's actually in the tenant after verification testing. If anything in `saviynt-config/*.md` conflicts with these values, the tenant is the source of truth — update the docs.

**Tenant:** `https://eic-poc-wesharris.saviyntcloud.com`

**Security System:** `Pulumi-Pipeline-AWS`
- `accessAddWorkflow`: `WF-PulumiPipeline-AddAccess` (one workflow, branches inside via If-Else)
- `accessRemoveWorkflow`: OOB auto-approval workflow (no human gate on removals — encourages least-privilege)
- `automatedProvisioning`: **true** (verified auto-closes provisioning tasks on approval; broker doesn't need updateTasks)
- `useopenconnector`: true
- `instantprovision`: true

**Endpoint:** `Pulumi-Pipeline-AWS` (under above SS)
- Resource Owner: `wes-approver` (userKey 3452) — populates the `requestowner` field that Resource Owner Approval reads, but we ended up using Custom Assignment instead so this is informational
- Requestable: ON

**Entitlement Types** (under endpoint):
- `EntDev` (display: "Pipeline Access - Dev") — `workflow` field has the JSON-wrapped name but is *not* what fires; SS-level workflow handles routing
- `EntProd` (display: "Pipeline Access - Prod") — same

**Entitlements:**
- `EC2Deploy-Dev` under EntDev (requestable, status 1, risk Low) — assigned directly to wes-dev
- `EC2Deploy-Prod` under EntProd (requestable, status 1, risk High) — NOT assigned to wes-dev (the demo's prod-path trigger)

**Workflow:** `WF-PulumiPipeline-AddAccess`
- Type: **Parallel** (mandatory for entitlement-object If-Else conditions)
- Status: Active (must Send For Approval → Accept after each edit)
- Canvas:
  ```
  Start
    └→ If-Else (entitlement.entitlementtypekey.entitlementname.equals('EntProd') eq true)
         ├─ True  → Custom Assignment (Username = wes-approver) → Grant Access → End
         │                                                      ↘ Rejected Access → End
         │                                                      ↘ Escalation → End
         └─ False → Grant Access → End
  ```
- Custom Assignment block: Name=`Prod-Manual-Approval`, Select User Field=`Username`, User Group=`wes-approver`, Type Of Approval=`Any Owner Approval Required`, MC Required for Risk=`None`, Notification Email Template populated.

**Users:**
- `igaadmin` (userKey 6) — broker SA
- `wes-dev` (userKey 3451) — beneficiary; holds EC2Deploy-Dev; account `wes-dev` on Pulumi-Pipeline-AWS endpoint, mapped (userKey populated)
- `wes-approver` (userKey 3452) — approver; SAV Role: ROLE_ADMIN; no account on the endpoint (not required)

**Verified test results:**
- ✅ Dev path: createrequest for `EC2Deploy-Dev` with `requestor: igaadmin` → auto-approves via SS workflow's If-Else False branch → entitlement appears on wes-dev (task auto-closes via `automatedProvisioning`)
- ✅ Prod path: createrequest for `EC2Deploy-Prod` with `requestor: wes-dev` (NOT igaadmin) → PENDING with assignee `wes-approver` → wes-approver approves in UI → APPROVED → entitlement on wes-dev (task auto-closes via `automatedProvisioning`)
- ✅ Remove path: REMOVE createrequest with `requestor: igaadmin` → SS-level Access Remove Workflow (OOB auto-approval) auto-approves → entitlement removed (task auto-closes)

**Known follow-ups for Phase 5+:**
1. Reset script / docs entry: REMOVE createrequest snippet for revoking EC2Deploy-Prod between demo runs (working payload captured in `saviynt-config/03-roles-and-users.md`)
2. NHI registration custom-property mapping (Phase 4 PAM section, not yet written)
3. Decision on JIT pattern: should the broker call REMOVE after a successful deploy to demonstrate just-in-time access? (Not required for demo v1; future enhancement)
