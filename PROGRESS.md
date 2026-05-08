# Saviynt + Pulumi Demo — Progress Tracker

> **Purpose of this file:** This is the working roadmap for the demo. Update statuses as you build. When picking up in a new Claude Code session, this file (plus README.md and ARCHITECTURE.md) gives full context to continue without re-explaining the design.

## Project State: 🟢 IGA CONFIG VERIFIED — Demo flow proven end-to-end via API. Broker implementation next.

Last updated: 2026-05-08 — IGA config Section A/B/C verified against tenant; both demo paths (dev auto-approve, prod manual approve via wes-approver) confirmed working with real `createrequest` → `fetchRequestApprovalDetails` → UI approval → `getEntDetailsforUsers` cycles.

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
AWS us-east-1 (free tier t2.micro Ubuntu)
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

### Phase 1 — Broker (FastAPI) ⏳ NEXT
**Location:** `broker/`
**Goal:** Saviynt-facing service with five endpoints, all HMAC-authenticated.

- [ ] `broker/settings.py` — configurable Saviynt URL, endpoint paths, account names
- [ ] `broker/.env.example` — bootstrap secret template
- [ ] `broker/saviynt_client.py` — Saviynt API wrapper (login, getAccount, LLT, checkout, createRequest, fetchRequestStatus, createAccount)
- [ ] `broker/auth.py` — HMAC validation middleware
- [ ] `broker/main.py` — FastAPI app with routes
- [ ] `broker/models.py` — Pydantic request/response models
- [ ] `broker/requirements.txt`
- [ ] `broker/README.md` — local run instructions
- [ ] `scripts/test_broker.sh` — curl-based local test harness

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
- Free-tier compliant: t2.micro, Ubuntu 22.04 LTS AMI in us-east-1
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
- [ ] `saviynt-config/00-OVERVIEW.md` — *not written yet, optional*
- [ ] `saviynt-config/04-pam-endpoint.md` — endpoint for AWS IAM and EC2 instances *(Phase 5 prerequisite)*
- [ ] `saviynt-config/05-service-account.md` — broker SA setup with rotation policy *(Phase 5 prerequisite)*
- [ ] `saviynt-config/06-test-checklist.md` — pre-demo validation steps

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
| Auto-completion of provisioning tasks for disconnected endpoint | ⚠️ Open | `instantprovision: true` insufficient. Plan: broker calls `updateTasks` to close task itself after detecting APPROVED. Optional: try `automatedProvisioning: true` on SS. |
| Custom property mapping for NHI metadata (which customproperty fields hold owner, env, etc.) | ⚠️ To decide in Phase 4 PAM section | Will document in `saviynt-config/04-pam-endpoint.md` (not yet written) |
| Whether to add a quarterly NHI certification campaign as a Phase 7 extension | 💭 Optional | Strong story but adds Saviynt config complexity |
| AWS region failover (us-east-1 only?) | ✅ us-east-1 only | Confirmed by user |

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
- `accessRemoveWorkflow`: blank (or set to a simple auto-approve to allow easy reset between demo runs)
- `automatedProvisioning`: false ← *try true to test auto-completion of tasks*
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
- ✅ Dev path: createrequest for `EC2Deploy-Dev` with `requestor: igaadmin` → auto-approves immediately → after manual task close, entitlement appears on wes-dev
- ✅ Prod path: createrequest for `EC2Deploy-Prod` with `requestor: wes-dev` (NOT igaadmin) → PENDING with assignee `wes-approver` → wes-approver approves in UI → APPROVED → manual task close → entitlement on wes-dev

**Known follow-ups for Phase 5+:**
1. Auto-completion of provisioning tasks (currently manual; broker should call `updateTasks` API)
2. Reset script: revoke EC2Deploy-Prod between demo runs
3. NHI registration custom-property mapping (Phase 4 PAM section, not yet written)
