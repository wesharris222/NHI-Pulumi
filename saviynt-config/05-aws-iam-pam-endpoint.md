# 05 — AWS IAM Endpoint + `pulumi-deployer` PAM Onboarding

> **🛑 STATUS (2026-05-14): BLOCKED at E.6 — PAM enablement of `pulumi-deployer`.** E.1–E.5 are done; the account exists in Saviynt with the correct AWS metadata. The "PAM Enabled" flag on the endpoint/account refuses to persist — silently reverts on save in the UI, and `updateAccount` API calls with `privileged: true` either don't stick or return errors. Have engaged outside help to identify what's missing. See "Pick-up checkpoint" inside E.6 below for resume notes.

> **Goal:** Stand up the Saviynt Security System and Endpoint named `AWS-IAM-Endpoint` over the cross-account connection from `04`. Create the `pulumi-deployer` IAM user in your customer AWS account with the permissions Pulumi needs to deploy EC2. Onboard `pulumi-deployer` as a Saviynt PAM account with rotation. Validate end-to-end through the broker's `/checkout-aws` → use the keys → `/checkin-aws` cycle.

> **The demo-worthy moment this enables:** before the pipeline runs, show `pulumi-deployer`'s current AWS access keys. Broker calls `/checkout-aws` → Saviynt invokes the IAM API to generate fresh keys, returns them. Pulumi uses those new keys to deploy. Pipeline calls `/checkin-aws` → Saviynt deletes the keys. Try to use them after → AWS rejects. Live rotation, visible to the audience.

## Prerequisites

1. **Section D complete** (`04-aws-cross-account.md`). The `AWS-PulumiDemo` Connection in Saviynt must be Save-and-Test green.
2. **AWS Console admin access** to your customer AWS account (same one from `04`).
3. **The connection key for `AWS-PulumiDemo`** — captured from a `getConnections` API call or visible in Admin → Connections in Saviynt.

## Reference

- Saviynt AWS Integration Guide PDF, Sections: "Configuring the Integration for Importing Accounts (AWS Cloud)", "Configuring the Integration for Provisioning Accounts and Entitlements (AWS Cloud)", "Creating User Accounts with Access Keys".
- The Saviynt **PAM Admin Guide** for the exact PAM-onboarding clicks (E.6 below). If you don't have it, the relevant menu paths are noted as "VERIFY in UI" — substitute the equivalents your Amsterdam build uses.

---

## E.1 Create the `AWS-IAM-Endpoint` Security System

The Security System is the top-level Saviynt container for this AWS integration. Mirrors what we did for `Pulumi-Pipeline-AWS` in `01-application-onboarding.md`, but with the AWS connection attached.

### Click-by-click

1. Log into Saviynt as `igaadmin`.
2. Admin → **Identity Repository** → **Security Systems** → **Actions** → **Create Security System**.
3. Fill in:
   - **System Name**: `AWS-IAM-Endpoint`
   - **Display Name**: `AWS IAM Endpoint (Pulumi Demo)`
   - **Hostname**: leave blank (or `n/a` if tenant rejects empty)
   - **Port**: blank
   - **Access Add Workflow**: leave blank (we won't be requesting AWS IAM entitlements through the IGA workflow for v1 demo — entitlement-based access is the `Pulumi-Pipeline-AWS` SS's job. This SS is purely a PAM container.)
   - **Access Remove Workflow**: blank
   - **Connection**: `AWS-PulumiDemo` ← **the critical link**. Select from dropdown.
4. **Provisioning** section:
   - **Automated Provisioning**: **ON** (we want Saviynt to actually call IAM APIs on our behalf)
   - **Use Open Connection**: ON
   - **Reconcile to External**: ON (so Saviynt periodically syncs IAM user state)
   - **Instant Provisioning**: ON
5. Save.

### Verify

```
GET https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5/getSecuritySystems

Params:
  systemname: AWS-IAM-Endpoint
  max: 4

Headers:
  Authorization: Bearer <fresh token>
```

Expected: one record with `systemname: "AWS-IAM-Endpoint"`, `automatedProvisioning: "true"`, and the external connection reference matching `AWS-PulumiDemo`.

---

## E.2 Create the `AWS-IAM-Endpoint` Endpoint

The Endpoint lives under the Security System and is what `createAccount` / PAM operations target.

### Click-by-click

1. Admin → **Identity Repository** → **Endpoints** → **Actions** → **Create Endpoint**.
2. Fill in:
   - **Endpoint Name**: `AWS-IAM-Endpoint` (must match the SS name for clarity)
   - **Display Name**: `AWS IAM Endpoint (Pulumi Demo)`
   - **Security System**: `AWS-IAM-Endpoint` (the one you just created)
   - **Description**: `AWS IAM users managed by Saviynt PAM for Pulumi pipeline deployment credentials`
   - **Owner Type**: User → **Owner**: `igaadmin`
   - **Resource Owner Type**: User → **Resource Owner**: `igaadmin`
   - **Account Name Validator Regex**: blank
   - **Account Custom Property Label**: blank
3. **Account Configuration**:
   - **Allow Removal of Owner**: default
   - **Disable New Account Request If Account Exists**: OFF
   - **Allow Multiple Accounts**: ON
   - **Service Account**: blank
4. **Requestable Configuration**:
   - **Requestable**: ON (per the tenant pattern; even though the broker is the primary actor, requestable enables admin operations)
5. **Provisioning** section: leave defaults — the SS-level Automated Provisioning will fire through this endpoint.
6. Save.

### Verify

```
POST https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5/getEndpoints

Body:
{
  "filterCriteria": {
    "endpointname": "AWS-IAM-Endpoint"
  }
}
```

Expected: one record with `endpointname: "AWS-IAM-Endpoint"`, `securitysystem: "AWS-IAM-Endpoint"`, `status: "1"`.

---

## E.3 Create the `pulumi-deployer` IAM user in AWS (out-of-band)

Saviynt's IAM connector can *create* IAM users via provisioning, but for demo simplicity and to keep AWS-side actions auditable in the AWS Console, we'll create `pulumi-deployer` directly in AWS and let Saviynt discover it on the next import.

### Click-by-click (AWS Console)

1. AWS Console → **IAM** → **Users** → **Create user**.
2. **User name**: `pulumi-deployer`.
3. **Provide user access to the AWS Management Console**: leave UNCHECKED. The broker uses access keys, not console login.
4. Next.
5. **Permissions options**: `Attach policies directly`.
6. Attach policies — for the demo's EC2 deploy needs:
   - `AmazonEC2FullAccess` (managed policy) — covers everything Pulumi needs to create EC2 instances, key pairs, security groups, etc.
   - Optionally, scope down later. For demo v1, broad is fine and matches the talk track's "the deploy identity has standing EC2 access".
7. Next → Review → **Create user**.
8. After creation, on the user's summary page:
   - **DO NOT** generate any access keys here. Saviynt will generate them on first PAM checkout.
   - Note the **ARN**: `arn:aws:iam::<your-customer-account-id>:user/pulumi-deployer` — you'll see it confirm in Saviynt after the next import.

### Verify (AWS Console)

IAM → Users → search for `pulumi-deployer` → confirm it exists, status Active, with the `AmazonEC2FullAccess` policy attached and **zero access keys**.

### Optional: scoped-down policy (more rigorous demo story)

If you want a tighter "least privilege" narrative for the talk track, attach a custom policy with just:
```
ec2:RunInstances, ec2:TerminateInstances, ec2:DescribeInstances,
ec2:CreateKeyPair, ec2:DeleteKeyPair, ec2:DescribeKeyPairs,
ec2:CreateSecurityGroup, ec2:DeleteSecurityGroup, ec2:DescribeSecurityGroups,
ec2:AuthorizeSecurityGroupIngress, ec2:CreateTags, ec2:DescribeImages
```
…limited to `us-east-2`. This is the demo-honest version of "Pulumi runs only what it needs to". Slightly more setup; not required for v1.

---

## E.4 Import IAM users into Saviynt (first sync)

This pulls IAM users from your customer AWS account through the cross-account role and creates corresponding Saviynt account records.

### Click-by-click

1. Admin → **Job Control Panel** (or **Job Management** in some Amsterdam UIs).
2. Find the **Application Data Import** job template.
3. **Create job trigger** (or **Run Now** if a trigger already exists for this SS).
4. Configure:
   - **Security System**: `AWS-IAM-Endpoint`
   - **Job Type**: `Full Import`
   - **Import Type**: `Access` (accounts + entitlements; the connector imports both in one pass per the AWS guide)
   - **Import Config**: leave default for first run — we want everything once. We can scope later.
5. Run the job. Watch its status update — should reach `SUCCESS` in 1-3 minutes for a fresh AWS account.

### Verify

```
POST https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5/getAccounts

Body:
{
  "advsearchcriteria": {
    "endpoint": "AWS-IAM-Endpoint",
    "name": "pulumi-deployer"
  }
}
```

Expected: one record with `name: "pulumi-deployer"`, `endpoint: "AWS-IAM-Endpoint"`, `status: "1"` (Active), and `accountid` matching `pulumi-deployer`'s AWS userId. The `customproperty4` field should hold the user ARN (per the IAM User Account Attribute Mapping in the integration guide).

---

## E.5 (Optional but useful) Verify Saviynt can SEE pulumi-deployer's keys

Before onboarding to PAM, confirm the connector is reading the IAM user correctly:

1. Saviynt UI → Admin → Accounts → find `pulumi-deployer` → open it.
2. Look at custom properties. You should see (per AWS integration guide's account attribute mapping):
   - `customproperty4`: the ARN
   - `customproperty5`: MFA device enabled = `N` (we didn't set MFA)
   - `customproperty15`: Has login profile = `NO` (we didn't enable console access)
   - `accessKeyMetadata`: empty for now (no keys yet)

3. Confirm `accessKeyMetadata` is empty — this is intentional. Saviynt PAM will generate the keys on first checkout.

---

## E.6 Onboard `pulumi-deployer` as a Saviynt PAM account

> **🛑 PICK-UP CHECKPOINT (2026-05-14) — read this first when returning**
>
> **What's done (E.1–E.5):** Security System `AWS-IAM-Endpoint` exists, Endpoint of the same name is bound to it via the `AWS-PulumiDemo` connection, `pulumi-deployer` IAM user created in customer AWS with `AmazonEC2FullAccess` (and zero access keys — the demo expects PAM to generate them on checkout), Full Import job ran successfully, account record is visible in Saviynt with correct ARN/MFA/login-profile custom properties. `accessKeyMetadata` field is absent on the account record — expected, since no keys exist yet.
>
> **Where we got stuck:** Enabling PAM on the account / endpoint. Specifically:
> - The **PAM Enabled** flag on the endpoint silently reverts when saved in the UI.
> - `updateAccount` API call with `privileged: "true"` + `accounttype: "FIREFIGHTERID"` didn't make the toggle stick either.
> - `updateEndpoint` API call with a `pamConfig` body returned 401 / "invalid payload" depending on the exact shape tried.
>
> **What was tried:**
> - PAM Configuration JSON variations in the GUI: with `KEY` wrapper, `IAMACCESSKEY` wrapper, flat `{"maxConcurrentSession":"50"}`, and finally a `CONSOLE` wrapper with `Connection: AWS` per the Saviynt Cloud PAM Admin Guide samples (lines 3605-3855 of that guide). None made PAM Enabled persist.
> - Confirmed `igaadmin` has roles `ROLE_SAV_PAMADMIN`, `ROLE_SAV_PAMOWNER`, `ROLE_SAV_PAMENDUSER`, `ROLE_SUPERADMIN` — not a permissions issue.
>
> **What we learned from the Saviynt Cloud PAM Administration Guide (2026-02-12 edition) that contradicts earlier assumptions:**
> 1. The documented credential-type wrappers in PAM Configuration JSON are only **`CONSOLE`, `UNIX`, `WINDOWS`, `DB`** — there is no `IAMACCESSKEY`, `AWSACCESSKEY`, or `KEY` wrapper. For an AWS IAM user, the closest documented analog is `CONSOLE` with `"authenticationType": "KEY,PASSWORD"` inside `endpointPamConfig`.
> 2. `Connection` field values in PAM_Config samples are connection-type names like `AWS`, `GCP`, `Azure`, `AD`, `Okta` — never `REST`.
> 3. **`Resource Type` on the endpoint must be set** to one of `Instance` / `Console` / `Database`, otherwise PAM Enabled rolls back on save. Quote from guide: *"This parameter is mandatory if PAM Enabled is set to ON"* and *"if you edit any parameter in the PAM Attributes tab... ensure to set the Resource Type parameter to Console. If the parameter is not set to Console, the application console bootstrap process fails."* **This is the leading hypothesis for why PAM Enabled wouldn't stick.**
> 4. **`rotateKey: true`** must be set in the endpoint's Configuration JSON (PAM Attributes tab — separate from the PAM Configuration JSON) or `Rotate On Checkin` is no-op.
> 5. The **global setting** `Enable Account Password Rotation Policies` must be ON or per-account rotation fields don't render.
> 6. Account-level PAM Enabled has a dependency on a **successful change-password task** before the flag persists (per p.438-449 of the guide).
> 7. The guide names a specific PAM-aware connection template: **`AWSPAM_CloudDeploymentCrossAccount_template`**. Worth verifying the `AWS-PulumiDemo` connection from `04-aws-cross-account.md` was created from this template (or has the PAM sub-config it requires).
> 8. **The exact demo pattern — Saviynt PAM calling AWS IAM `CreateAccessKey` on checkout and `DeleteAccessKey` on checkin for a vaulted IAM user — is NOT documented in the PAM admin guide.** The guide's AWS PAM section describes a "vault the IAM user creds, launch the AWS console" pattern. Whether the broker-driven dynamic-access-key flow is supported transparently or requires a custom connector is an open question. Confirm with Saviynt support / the outside help engaged.
>
> **First three things to try when you come back:**
> 1. **Set the endpoint's Resource Type to `Console`** (PAM Attributes tab on the endpoint). Then retry the PAM Enabled toggle on the endpoint.
> 2. **Add `rotateKey: true`** to the endpoint's Configuration JSON.
> 3. **Verify the `AWS-PulumiDemo` connection was built from `AWSPAM_CloudDeploymentCrossAccount_template`** (Admin → Connections → AWS-PulumiDemo → check the connection type / template). If it was built from a non-PAM AWS template, the connection won't expose the PAM hooks the endpoint needs.
>
> If those three don't unblock PAM Enabled, escalate to outside help with the dump above — they'll want to know what's been tried.

> **⚠️ The click-by-click below was the original plan and has NOT been validated end-to-end against this tenant.** The high-level flow is fixed; specific UI menu names may differ in your Amsterdam build. Treat "VERIFY in UI" as a prompt to find the equivalent in your tenant.

### What we're doing

Marking the `pulumi-deployer` account as PAM-managed tells Saviynt to:
- Treat its AWS access keys as vault-able credentials
- Generate new keys on checkout (and optionally delete old ones)
- Delete/rotate keys on checkin
- Track checkout/checkin history for audit

### Click-by-click

1. Admin → **PAM** → **Privileged Accounts** (path may be **Admin → Identity Repository → Accounts** with a PAM filter, or **Admin → PAM → Account Onboarding** — VERIFY in your tenant).
2. Search/filter for `pulumi-deployer` on `AWS-IAM-Endpoint`.
3. Select the account → **Actions** → **Onboard to PAM** (or **Mark as Privileged**, or **Add to PAM Vault** — VERIFY).
4. Set:
   - **Credential Type**: `AWS Access Key` (vs. password)
   - **Rotation Policy**: `Rotate on Checkin` ← the demo-worthy setting; alternative is `Rotate on Schedule (every N days)` which doesn't fire during a demo
   - **Auto-Generate on Checkout**: ON ← Saviynt creates new keys via IAM API at checkout time
   - **Auto-Delete on Checkin**: ON ← Saviynt deletes the keys via IAM API at checkin time
   - **Max Checkout Duration**: 30 minutes (matches `PAM_CHECKOUT_TTL_MIN` in `broker/settings.py`)
   - **Approval Required**: OFF for v1 (this would route checkouts through an approver workflow, like our prod-path entitlement requests — useful for "production-like demo" but adds another approval gate)
5. Save.

### Verify

Two checks:

**1. PAM account record exists in Saviynt:**
```
POST https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5/getAccounts

Body:
{
  "advsearchcriteria": {
    "endpoint": "AWS-IAM-Endpoint",
    "name": "pulumi-deployer"
  }
}
```
Look for a PAM flag in the response (commonly `accountType: "Privileged"` or a custom property indicating PAM management — VERIFY against your tenant's response shape).

**2. Test checkout from Saviynt UI:**
Some Saviynt builds expose a "Test Checkout" button on the PAM account page. Click it → Saviynt should call IAM `CreateAccessKey` for `pulumi-deployer`, display the new access key ID + secret. Confirm in AWS Console → IAM → `pulumi-deployer` → Security Credentials tab — you should see a new key listed.

If Test Checkout returns the credential successfully, **PAM rotation is working**. Click Checkin or wait the TTL to expire — the key should disappear from AWS within seconds.

---

## E.7 End-to-end test via the broker

Now test the broker's `/checkout-aws` endpoint, which exercises the same flow programmatically.

### On the Ubuntu VM

```bash
# Make sure broker is running (uvicorn from earlier session)
cd ~/NHI-Pulumi
export BROKER_HMAC_SECRET="$(grep '^BROKER_HMAC_SECRET=' broker/.env | cut -d= -f2-)"

# We'll need a small test script — for now do it manually with curl + HMAC.
# scripts/test_broker.sh currently skips PAM endpoints (Phase 5 isolation).
# Once Phase 5 is validated, we'll add a `pam` subcommand to test_broker.sh.
```

For manual testing right now, hit `/checkout-aws` via the broker. The broker will:

1. Authenticate to Saviynt as the SA
2. Call `getAccount` on `pulumi-deployer` at `AWS-IAM-Endpoint` → get account key
3. Call `/ECM/oauth/access_token_withissuer` to generate an LLT for that account
4. Call `/ECMv6/api/pam/account/checkout` → Saviynt invokes IAM `CreateAccessKey`, returns the new key+secret
5. Broker returns `aws_access_key_id` and `aws_secret_access_key` to the caller

Curl test (after the broker is running):

```
POST http://127.0.0.1:18443/checkout-aws

Headers:
  X-Broker-Timestamp: <unix epoch>
  X-Broker-Nonce: <random hex>
  X-Broker-Signature: <HMAC-SHA256 of "<ts>.<nonce>.<body>" using BROKER_HMAC_SECRET>
  Content-Type: application/json

Body:
{
  "requesting_user": "wes-dev",
  "target_env": "dev",
  "duration_minutes": 30
}
```

The broker checks (per its current code) that `wes-dev` holds `EC2Deploy-Dev` before issuing the checkout — that part is already validated. The new behavior is the PAM checkout itself.

**Expected response:**
```json
{
  "aws_access_key_id": "AKIA...XXXXXX",
  "aws_secret_access_key": "<secret>",
  "account_key": <int>,
  "expires_in_minutes": 30
}
```

**Verify in AWS Console:**
- IAM → `pulumi-deployer` → Security Credentials tab → confirm a new access key with create-time within the last few minutes.

### Then test `/checkin-aws`

```
POST http://127.0.0.1:18443/checkin-aws

(Signed body)
{
  "account_key": <account_key from checkout response>
}
```

**Expected response:**
```json
{
  "status": "ok",
  "rotation_triggered": true,
  "message": "Credential for accountKey=... checked in; Saviynt rotation policy will fire"
}
```

**Verify in AWS Console:**
- IAM → `pulumi-deployer` → Security Credentials tab → the access key from the checkout should be **gone** (or marked Inactive then deleted, depending on the rotation policy).

If both happen, **the rotation story is real and demonstrable**.

---

## E.8 (Future) Update test_broker.sh with a `pam` subcommand

Once Phase 5 is fully validated, `scripts/test_broker.sh` should grow a new subcommand:

```
scripts/test_broker.sh pam     # full /checkout-aws → use keys → /checkin-aws cycle
```

That's a follow-up; not blocking. The manual curl test in E.7 proves the broker code works end-to-end.

---

## Common Gotchas — Section E

| Symptom | Cause | Fix |
|---|---|---|
| `getAccounts` for `pulumi-deployer` returns empty after import | Import job failed silently, or wrong endpoint name | Re-run job; check Job Control logs; confirm endpoint name `AWS-IAM-Endpoint` |
| Account imported but `accessKeyMetadata` shows existing keys | You generated access keys in AWS Console before importing | Delete them from AWS Console; let Saviynt generate at checkout |
| PAM onboarding option not visible in UI | Tenant build lacks PAM module OR user lacks PAM admin role | Verify SAV Role includes `ROLE_SAV_PAMADMIN`; check tenant license includes PAM |
| Test Checkout button greyed out | Rotation policy not set, OR endpoint missing required PAM config | Review E.6 settings; check endpoint's Provisioning tab for "Connection" attached |
| `/checkout-aws` returns 502 "PAM checkout failed: HTTP 500" | Saviynt couldn't call IAM API — cross-account role lacks `iam:CreateAccessKey` permission | Re-check the CFN template was IGA+PAM (not just Security Analyzer); re-create stack if wrong |
| New access key appears in AWS but checkout returns null secret | Saviynt didn't capture the secret on creation (IAM API only returns secret ONCE at creation time) | Saviynt-side bug; usually means PAM module misconfiguration. Open support ticket. |
| Checkin doesn't delete the key | "Auto-Delete on Checkin" was OFF, or rotation policy is "On Schedule" not "On Checkin" | Revisit E.6 PAM settings |
| Provisioning task lingers Open after checkout | `automatedProvisioning` false on the Security System | Set to true (E.1 step 4) and re-test |

---

## AWS Cost & Free Tier Notes

Everything in Section E (IAM-side) is free:

| Resource | Cost | Notes |
|---|---|---|
| IAM User `pulumi-deployer` | $0 | IAM is always free |
| IAM Policy attachment (`AmazonEC2FullAccess` or scoped variant) | $0 | Free |
| IAM access keys (created at checkout, deleted at checkin) | $0 | No charge per key or for IAM API calls |
| Saviynt's IAM `CreateAccessKey` / `DeleteAccessKey` calls | $0 | Free |

The cost surface is what `pulumi-deployer` *creates* downstream (Pulumi → EC2). That's covered in `pulumi/` and gets billed against your AWS free tier:

| Resource Pulumi creates | Free tier | After 12 months |
|---|---|---|
| EC2 t2.micro (Ubuntu) | 750 hr/mo for 12 months | ~$8.50/mo if always-on |
| EBS volume 8 GB (default) | 30 GB-mo free | ~$0.80/mo if always-on |
| Public IPv4 address | ⚠️ NOT free even on free tier | $0.005/hr ($3.60/mo if always-on) |
| Default VPC, security group, key pair | $0 always | $0 |
| Data transfer out (demo SSH session) | 100 GB/mo free tier | $0.09/GB |

**Public IPv4 is the only line-item that costs from day 1**, but at ~$0.012/hour total demo run time it's pennies if you `pulumi destroy` after each run. If you want zero AWS-cost demos, swap SSH-to-EC2 for AWS Systems Manager Session Manager (no public IP needed) — extra setup, separate doc.

### Recommendation: scope `pulumi-deployer`'s policy

The `AmazonEC2FullAccess` policy in E.3 is wide. For demo cleanliness (and to lock down what Pulumi-via-`pulumi-deployer` could create even by accident), use the scoped policy from E.3's "Optional: scoped-down policy" section instead. Limit to:

- `ec2:RunInstances` with InstanceType condition restricted to `t2.micro`, `t3.micro`
- `ec2:TerminateInstances`, `ec2:DescribeInstances`
- `ec2:CreateKeyPair`, `ec2:DeleteKeyPair`, `ec2:DescribeKeyPairs`
- `ec2:CreateSecurityGroup`, `ec2:DeleteSecurityGroup`, `ec2:DescribeSecurityGroups`, `ec2:AuthorizeSecurityGroupIngress`
- `ec2:CreateTags`, `ec2:DescribeImages`

This makes the "what could go wrong if a Pulumi bug ran wild" answer trivially boundable to the free tier shape. Recommended for the final demo recording even if you start with EC2FullAccess for iteration speed.

### Demo cleanup checklist (between runs)

1. `pulumi destroy --stack dev` (and `--stack prod` if you ran prod) — terminates EC2, deletes SG/keypair/etc.
2. Confirm in AWS Console → EC2 → Instances filtered by State=Running → should be empty.
3. Saviynt → revoke any leftover entitlements (`scripts/test_iga_flow.sh remove`).

Skipping the destroy step is the single biggest accidental-cost risk during iteration.

## Settings to capture in broker/settings.py

The broker's defaults already point at what we created here. Verify nothing in `broker/.env` overrides them with stale values:

```python
pam_endpoint_aws    = "AWS-IAM-Endpoint"     # E.1/E.2
pam_account_aws_iam = "pulumi-deployer"      # E.3
pam_checkout_ttl_min = 30                    # matches E.6 setting
```

If `broker/.env` has lines like `PAM_ENDPOINT_AWS=` or `PAM_ACCOUNT_AWS_IAM=` set to anything else, strip them so the verified defaults take effect (same pattern we hit earlier with the entitlement names):

```bash
sed -i '/^PAM_ENDPOINT_AWS=/d; /^PAM_ACCOUNT_AWS_IAM=/d' broker/.env
```

---

## What's next

With Section E validated end-to-end (checkout returns keys, AWS reflects new key, checkin deletes it), the AWS IAM half of PAM is done. Remaining open items in PROGRESS.md's Phase 5:

1. **EC2 instances NHI endpoint** — for registering deployed EC2 instances as Saviynt accounts via the broker's `/register-nhi`. Originally scoped as governance-only push (no AWS-side connector); with live AWS connector now wired, we could optionally also enable EC2 instance discovery. Worth a separate design conversation.
2. **`scripts/test_broker.sh pam` subcommand** — automate the manual curl test in E.7.
3. **Saviynt rotation policy demo-tuning** — current "rotate on checkin" makes for a clean talk-track moment; if you want to demo scheduled rotation too, add a separate scheduled-rotation account to show the pattern.

After Section E lands, the demo's full architecture is real and observable:
- Saviynt holds the entitlement decisions (governance, manual approval gate on prod)
- Saviynt vaults the AWS deploy credential (PAM with live rotation)
- The broker brokers between GitHub Actions and Saviynt
- Pulumi consumes the dynamically-issued credentials

That's the entire "IGA + PAM as one converged platform" pitch made tangible.
