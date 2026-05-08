# Architecture

## Component Map

```
┌──────────────────────────────────────────────────────────────────────┐
│  GitHub (cloud)                                                      │
│  ┌─────────────────┐         ┌──────────────────────────────────┐   │
│  │  Repo: pulumi   │ ──────▶ │  Actions Workflow: deploy-ec2    │   │
│  │  EC2 program    │         │  (runs on self-hosted runner)    │   │
│  └─────────────────┘         └──────────────┬───────────────────┘   │
└──────────────────────────────────────────────┼──────────────────────┘
                                               │ HMAC-signed HTTPS
                                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Ubuntu VM (homelab)                                                 │
│                                                                       │
│  ┌────────────────────────┐         ┌──────────────────────────┐    │
│  │  GitHub Actions Runner │         │  FastAPI Broker          │    │
│  │  (self-hosted)         │ ──────▶ │  localhost:18443          │    │
│  │                        │         │                          │    │
│  │  Runs Pulumi here      │         │  Endpoints:              │    │
│  │  AWS creds via env     │         │   /preflight             │    │
│  │  HMAC-signs requests   │         │   /preflight/status/{id} │    │
│  │                        │         │   /checkout-aws          │    │
│  └────────────────────────┘         │   /register-nhi          │    │
│                                     │   /checkin-aws           │    │
│  Existing K3s cluster               │                          │    │
│  (untouched)                        │  Holds bootstrap creds:  │    │
│                                     │   - Saviynt SA password  │    │
│                                     │   - HMAC shared secret   │    │
│                                     └──────────┬───────────────┘    │
└────────────────────────────────────────────────┼────────────────────┘
                                                 │ Bearer token
                                                 │ (refreshed on 401)
                                                 ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Saviynt EIC (your existing tenant)                                  │
│                                                                       │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐    │
│  │  IGA             │  │  PAM             │  │  Audit          │    │
│  │  - Users         │  │  - AWS IAM acct  │  │  - All actions  │    │
│  │  - Roles         │  │  - EC2 NHI accts │  │  - Identity     │    │
│  │  - Entitlements  │  │  - Vault         │  │    correlated   │    │
│  │  - Access        │  │  - Checkout/in   │  │                 │    │
│  │    requests      │  │  - Rotation      │  │                 │    │
│  │  - SoD policies  │  │                  │  │                 │    │
│  └──────────────────┘  └──────────────────┘  └─────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
                                                 ▲
                                                 │ Pulumi uses checked-out
                                                 │ AWS creds to deploy
                                                 │
┌────────────────────────────────────────────────┼────────────────────┐
│  AWS us-east-1                                  │                    │
│                                                 │                    │
│  ┌───────────────────────────────────────────┐ │                    │
│  │  EC2 instance (t2.micro Ubuntu)           │◀┘                    │
│  │  - SSH keypair (Pulumi-generated)         │                       │
│  │  - OS user with random password           │                       │
│  │  - Tagged: owner, env, app, requester     │                       │
│  └───────────────────────────────────────────┘                       │
└──────────────────────────────────────────────────────────────────────┘
```

## Sequence: Run 1 — Dev Deployment (Auto-Approved)

```
Developer            GitHub Actions       Broker             Saviynt           Pulumi/AWS
   │                       │                 │                  │                  │
   │ workflow_dispatch     │                 │                  │                  │
   │ env=dev,user=wes-dev  │                 │                  │                  │
   ├──────────────────────▶│                 │                  │                  │
   │                       │                 │                  │                  │
   │                       │ POST /preflight │                  │                  │
   │                       │ {user,action}   │                  │                  │
   │                       ├────────────────▶│                  │                  │
   │                       │                 │ login + getUser  │                  │
   │                       │                 ├─────────────────▶│                  │
   │                       │                 │ checkEntitlement │                  │
   │                       │                 ├─────────────────▶│                  │
   │                       │                 │  ✓ has it        │                  │
   │                       │                 │◀─────────────────┤                  │
   │                       │ {status:ok}     │                  │                  │
   │                       │◀────────────────┤                  │                  │
   │                       │                 │                  │                  │
   │                       │ POST /checkout  │                  │                  │
   │                       │ -aws            │                  │                  │
   │                       ├────────────────▶│                  │                  │
   │                       │                 │ login + getAcct  │                  │
   │                       │                 │ + LLT + checkout │                  │
   │                       │                 ├─────────────────▶│                  │
   │                       │                 │ {AKID,SECRET}    │                  │
   │                       │                 │◀─────────────────┤                  │
   │                       │ {AKID,SECRET}   │                  │                  │
   │                       │◀────────────────┤                  │                  │
   │                       │                 │                  │                  │
   │                       │ pulumi up (env=dev stack)          │                  │
   │                       ├──────────────────────────────────────────────────────▶│
   │                       │                 │                  │                  │
   │                       │ stack outputs (instance, ssh_key, os_creds)           │
   │                       │◀──────────────────────────────────────────────────────┤
   │                       │                 │                  │                  │
   │                       │ POST /register- │                  │                  │
   │                       │ nhi {meta,creds}│                  │                  │
   │                       ├────────────────▶│                  │                  │
   │                       │                 │ createAccount    │                  │
   │                       │                 │ + storeCredential│                  │
   │                       │                 ├─────────────────▶│                  │
   │                       │                 │  account created │                  │
   │                       │                 │◀─────────────────┤                  │
   │                       │ {accountKey}    │                  │                  │
   │                       │◀────────────────┤                  │                  │
   │                       │                 │                  │                  │
   │                       │ POST /checkin-aws (always)         │                  │
   │                       ├────────────────▶│                  │                  │
   │                       │                 │ checkin + rotate │                  │
   │                       │                 ├─────────────────▶│                  │
   │ Done ✓                │                 │                  │                  │
   │◀──────────────────────┤                 │                  │                  │
```

## Sequence: Run 2 — Prod Deployment (Manual Approval)

```
Developer       GitHub Actions       Broker            Saviynt UI       Approver
   │                  │                 │                  │                │
   │ env=prod         │                 │                  │                │
   ├─────────────────▶│                 │                  │                │
   │                  │                 │                  │                │
   │                  │ POST /preflight │                  │                │
   │                  ├────────────────▶│                  │                │
   │                  │                 │ checkEntitlement │                │
   │                  │                 │  ✗ does not have │                │
   │                  │                 ├─────────────────▶│                │
   │                  │                 │ createRequest    │                │
   │                  │                 ├─────────────────▶│                │
   │                  │                 │ {request_id}     │                │
   │                  │                 │◀─────────────────┤                │
   │                  │ {pending,reqid} │                  │                │
   │                  │◀────────────────┤                  │                │
   │                  │                 │                  │                │
   │                  │ ⏳ poll /status loop (30s interval, 30min max)       │
   │                  │                 │                  │                │
   │                  │                 │                  │ notification   │
   │                  │                 │                  ├───────────────▶│
   │                  │                 │                  │                │
   │                  │ ┌────────────── DEMO PAUSE ──────────────────────┐  │
   │                  │ │ Switch to Saviynt UI                            │  │
   │                  │ │ Show:                                            │  │
   │                  │ │  - Pending request                               │  │
   │                  │ │  - Requester context                             │  │
   │                  │ │  - SoD check passed                              │  │
   │                  │ │  - Approver clicks "Approve" with 4hr TTL       │  │
   │                  │ └─────────────────────────────────────────────────┘  │
   │                  │                 │                  │                │
   │                  │                 │                  │ approve        │
   │                  │                 │                  │◀───────────────┤
   │                  │                 │                  │                │
   │                  │ poll iteration n│                  │                │
   │                  ├────────────────▶│                  │                │
   │                  │                 │ fetchRequestStatus                │
   │                  │                 ├─────────────────▶│                │
   │                  │                 │ {status:approved}│                │
   │                  │                 │◀─────────────────┤                │
   │                  │ {status:ok}     │                  │                │
   │                  │◀────────────────┤                  │                │
   │                  │                 │                  │                │
   │                  │ (continues identical to Run 1 from here)            │
```

## Component Responsibilities

### FastAPI Broker

| Responsibility | Why it lives here |
|---|---|
| Authenticate to Saviynt | Holds the bootstrap credential; nothing else should |
| Translate pipeline-friendly requests to Saviynt API calls | Saviynt API has multi-step flows (login → LLT → checkout) that don't fit cleanly in a YAML pipeline |
| HMAC-validate inbound requests | Confirms requests came from authorized GitHub Actions, not attackers |
| Cache Saviynt session token, refresh on 401 | Resilience to credential rotation without breaking pipelines |
| Audit logging | Every broker request logged with HMAC-validated source, before forwarding to Saviynt |

### GitHub Actions

| Responsibility | Why it lives here |
|---|---|
| Trigger pipeline on push or workflow_dispatch | Standard CI/CD entry point |
| Sign requests to broker with HMAC | Authenticates the pipeline as the legitimate caller |
| Run Pulumi with checked-out AWS creds in env | Pulumi consumes AWS creds the same way it always does |
| Always run /checkin-aws via cleanup step | Even on deploy failure, creds get returned and rotated |

### Saviynt EIC

| Responsibility | Demo evidence |
|---|---|
| Source of truth for who can do what | Entitlement check during /preflight |
| Approval workflow for high-risk requests | Prod deploy pauses pipeline pending approval |
| Credential vault for AWS IAM | /checkout-aws and /checkin-aws |
| Credential vault for new EC2 NHIs | /register-nhi creates the account and stores creds |
| Rotation policy enforcement | Configured on AWS IAM account in tenant |
| Audit trail | Every action above is logged with full identity context |

### Pulumi

| Responsibility | Why |
|---|---|
| Deterministic, declarative EC2 deploy | IaC discipline; supports the dev/prod stack separation cleanly |
| SSH key generation and output as stack output | Keys never written to disk; passed to broker for vaulting |
| Stack-scoped state | Dev and prod state are isolated |

## Settings & Configuration Strategy

All Saviynt-specific paths and values live in `broker/settings.py` (with environment variable overrides). This means:
- After first live tenant test, any path corrections happen in one file
- The same broker can point at different Saviynt tenants for dev vs prod by changing env vars
- No hardcoded URLs or account names anywhere in the request handlers

Example shape (final form will be in Phase 1):

```python
# broker/settings.py
SAVIYNT_BASE_URL = env("SAVIYNT_BASE_URL")
SAVIYNT_USERNAME = env("SAVIYNT_USERNAME")  # bootstrap SA
SAVIYNT_PASSWORD = env("SAVIYNT_PASSWORD")  # bootstrap SA

# Endpoint paths (configurable in case tenant differs)
PATH_LOGIN              = env("PATH_LOGIN",              "/ECM/api/login")
PATH_GET_ACCOUNTS       = env("PATH_GET_ACCOUNTS",       "/ECM/api/v5/getAccounts")
PATH_LLT                = env("PATH_LLT",                "/ECM/oauth/access_token_withissuer")
PATH_CHECKOUT           = env("PATH_CHECKOUT",           "/ECMv6/api/pam/account/checkout")
PATH_CHECKIN            = env("PATH_CHECKIN",            "/ECMv6/api/pam/account/checkin")           # confirm
PATH_CREATE_REQUEST     = env("PATH_CREATE_REQUEST",     "/ECM/api/v5/createRequest")                # confirm
PATH_REQUEST_STATUS     = env("PATH_REQUEST_STATUS",     "/ECMv6/api/v5/fetchRequestStatus")         # confirm
PATH_CREATE_ACCOUNT     = env("PATH_CREATE_ACCOUNT",     "/ECM/api/v5/createAccount")                # confirm

# Saviynt object names this demo expects
APP_NAME                = env("APP_NAME",                "Pulumi-Pipeline-AWS")
ENT_DEPLOY_DEV          = env("ENT_DEPLOY_DEV",          "EC2Deploy-Dev")
ENT_DEPLOY_PROD         = env("ENT_DEPLOY_PROD",         "EC2Deploy-Prod")
PAM_ENDPOINT_AWS        = env("PAM_ENDPOINT_AWS",        "AWS-IAM-Endpoint")
PAM_ENDPOINT_EC2        = env("PAM_ENDPOINT_EC2",        "EC2-Instances-Endpoint")
PAM_ACCOUNT_AWS_IAM     = env("PAM_ACCOUNT_AWS_IAM",     "pulumi-deployer")  # the IAM account name in PAM

# Behavior
PAM_CHECKOUT_TTL_MIN    = int(env("PAM_CHECKOUT_TTL_MIN", "30"))
APPROVAL_POLL_TIMEOUT   = int(env("APPROVAL_POLL_TIMEOUT", "1800"))  # 30 min
APPROVAL_POLL_INTERVAL  = int(env("APPROVAL_POLL_INTERVAL", "30"))
```

## Failure Modes & Handling

| Failure | Behavior |
|---|---|
| Broker can't reach Saviynt | Returns 502 to GitHub Actions; pipeline fails clean |
| Saviynt returns 401 (token expired) | Broker re-authenticates and retries the original call once |
| Approval request times out (30 min default) | Broker returns 408; pipeline fails with clear "approval not received" message |
| Pulumi `up` fails after AWS checkout | Cleanup job still calls /checkin-aws; creds get returned and rotated |
| /register-nhi fails after EC2 created | Pipeline marked failed; manual cleanup needed (this is a known v1 limitation, document in TALK_TRACK) |
| HMAC signature invalid | Broker returns 401; logs the attempt with source IP |
