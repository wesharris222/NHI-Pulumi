# 04 — AWS Connection (Saviynt → Customer AWS via IAM User + AssumeRole)

> **Goal:** Stand up the AWS-side IAM scaffolding (an IAM user + a role with PAM permissions) and connect Saviynt to it. Saviynt authenticates as the IAM user using static access keys, then calls `sts:AssumeRole` to take on the role's permissions to perform IAM/PAM operations — create/delete IAM users, generate and rotate access keys, attach policies. This is the foundation for every downstream PAM operation in the demo; **`05-aws-iam-pam-endpoint.md`** depends on this being complete.

> **Why this pattern (not cross-account-role-with-External-ID):** The "Security Analyzer + IGA + PAM" CloudFormation template Saviynt provides creates an IAM user + role in your account. Saviynt's tenant UI exposes both auth patterns (cross-account assume *and* IAM-user-with-keys); the template ships with the IAM-user pattern, so we use that. Tradeoff vs. cross-account: one set of long-lived AWS access keys lives in Saviynt PAM as the bootstrap SA credential, alongside the Saviynt SA password already in `broker/.env`. Same trust posture; honest framing already in the talk track's irreducible-bootstrap-secrets list.

## Reference

- Saviynt AWS Integration Guide (PDF in repo: `aws_integration_guide_configuring_the_integration_(aws_cloud)_2026-05-11-12-04-02.pdf`).
- The actual "Security Analyzer + IGA + PAM" CloudFormation template (shared in conversation; downloadable from the PDF's "Click to Download" link).

## Prerequisites

1. **A customer AWS account.** Free tier is fine; for the demo we recommend a fresh AWS account so blast radius is zero. Region: `us-east-2` (matches the rest of the demo per `PROGRESS.md`).
2. **AWS Console admin access** to that account (root user or an IAM admin user).
3. **The "Security Analyzer + IGA + PAM" CloudFormation template** — either the S3 URL from the Saviynt AWS Integration Guide table's "Click to Download" link, OR the local copy of the template JSON. The template's resources are: one IAM user (`SaviyntUser`), one IAM role (`SaviyntAssumeRole`), and four managed policies that wire them together.

> ⚠️ The template you're using has **one parameter only: `IAMUserName`**. It does NOT take `MasterAccID` or `EXTERNAL_ID`. If your template version has those parameters, you've got a different (cross-account) variant — pause and tell me; we'd switch the doc back to the cross-account pattern.

---

## D.1 Decide on naming and capture values you'll reuse

Open a scratch note and fill these in as you go. Most are produced by the CFN stack; you provide a few yourself.

| Variable | Example | Source | Used where |
|---|---|---|---|
| **IAMUserName** *(you choose)* | `saviynt-pam-svc` | You decide | CFN stack parameter; also the IAM user's name |
| **Customer AWS account ID** | `987654321098` | AWS Console top-right account menu | Saviynt Connection's `AWS_ACCOUNT_ID` field |
| **CFN stack name** | `Saviynt-PulumiDemo-IGA-PAM` | You decide | AWS Console only |
| **CFN template URL or local file** | `https://saviynt-cf-templates.s3.amazonaws.com/.../security-analyzer-iga-pam.json` | From Saviynt support or PDF link | CFN Step 1 |
| **SaviyntUser ARN** | `arn:aws:iam::987654321098:user/saviynt-pam-svc` | CFN Stack → Outputs tab → `SaviyntUser` row | Reference / audit |
| **SaviyntAssumeRole ARN** | `arn:aws:iam::987654321098:role/Saviynt-PulumiDemo-IGA-PAM-SaviyntAssumeRole-XXXXXXX` | IAM Console → Roles → search `SaviyntAssumeRole` (NOT in Outputs) | Saviynt Connection's `Role ARN` field |
| **Access Key ID** | `AKIA...XXXXXX` | IAM Console → Users → `<IAMUserName>` → Security Credentials → Create access key (manual post-stack step) | Saviynt Connection's `ACCESS KEY ID` field |
| **Secret Access Key** | `<40-char secret>` | Same step as above — shown ONCE only | Saviynt Connection's `SECRET ACCESS KEY` field |
| **Connection name in Saviynt** | `AWS-PulumiDemo` | You decide | Used as the link from Security System in `05-aws-iam-pam-endpoint.md` |

---

## D.2 Deploy the CloudFormation Stack in your AWS account

This creates `SaviyntUser` (IAM user), `SaviyntAssumeRole` (IAM role with IAM/PAM permissions), and the policies that link them.

### Click-by-click

1. Log into the **AWS Console** as admin in your customer AWS account.
2. Switch region to **us-east-2** (top-right region selector). IAM resources are global, but the CloudFormation stack record is regional — keeping it in our demo region keeps tagging tidy.
3. Navigate to **CloudFormation** (search in the top services bar).
4. Click **Create stack** → **With new resources (standard)**.
5. On the **Create stack** wizard:
   - **Prepare template**: `Template is ready`.
   - **Specify template** → **Template source**: `Amazon S3 URL` (or `Upload a template file` if you have a local copy of the JSON).
   - Paste the S3 URL, or upload the JSON.
6. Click **Next** → **Step 2 — Specify stack details**.
7. Fill in:
   - **Stack name**: `Saviynt-PulumiDemo-IGA-PAM`. Must be alphanumeric + hyphens; ≤128 chars; starts with a letter.
   - **Parameters → IAMUserName**: the name you decided for the IAM user (e.g., `saviynt-pam-svc`). Minimum 3 chars; alphanumeric, plus `+=,.@_-`.
8. Click **Next** → **Step 3 — Configure stack options**.
9. (Optional) Add a tag: Key=`Project`, Value=`PulumiSaviyntDemo`. Anything else default.
10. Click **Next** → **Step 4 — Review**.
11. Scroll to the bottom. Tick:
   - ☑ **I acknowledge that AWS CloudFormation might create IAM resources with custom names**
12. Click **Create stack**.
13. Wait. Status goes `CREATE_IN_PROGRESS` → `CREATE_COMPLETE` (usually 30-60 seconds).

### If you get errors

| Symptom | Cause | Fix |
|---|---|---|
| `Template format error: At least one Resources member must be defined` | Wrong S3 URL or empty file | Re-verify the URL from the PDF; or upload the JSON directly |
| `User: ... is not authorized to perform: iam:CreateUser` | AWS user lacks IAM permissions | Use root user or an IAM user with `AdministratorAccess` for this one-time stack creation |
| `EntityAlreadyExists: User with name <IAMUserName> already exists` | A previous stack run created the user; rolled back; left orphan | Delete the user from IAM Console, OR rerun with a different `IAMUserName` |
| `Stack rollback initiated` | Some resource creation failed | Click into Stack → Events tab → find the first FAILED line; usually a name collision; rerun with a different stack name |

---

## D.3 Capture Stack Outputs + post-deploy steps

The template's Outputs tab gives you the user ARN; the role ARN and access keys are post-deploy work in the IAM Console.

### Step 1: Grab the SaviyntUser ARN from Stack Outputs

1. Once the stack reaches `CREATE_COMPLETE`, click the stack name to open it.
2. Click the **Outputs** tab.
3. Note the **SaviyntUser** key's value — copy into your scratch note.
   ```
   arn:aws:iam::987654321098:user/saviynt-pam-svc
   ```

### Step 2: Find the SaviyntAssumeRole ARN

The role isn't in Outputs (template quirk) — find it in IAM:

1. AWS Console → **IAM** → **Roles**.
2. Search for the fragment `SaviyntAssumeRole`. You'll see the role with a CFN-generated name like `Saviynt-PulumiDemo-IGA-PAM-SaviyntAssumeRole-AB1CDEFGHIJK`.
3. Click into the role → copy the **ARN** from the role's Summary section into your scratch note.

### Step 3: Generate access keys for SaviyntUser

⚠️ **These are long-lived AWS credentials. Saviynt will hold them as a vaulted PAM bootstrap credential. Treat with care; rotate via Saviynt's normal PAM rotation cadence after the demo.**

1. AWS Console → **IAM** → **Users** → click `<IAMUserName>` (your `saviynt-pam-svc` or whatever).
2. **Security credentials** tab.
3. Scroll to **Access keys** → **Create access key**.
4. **Use case**: pick `Third-party service` (or `Application running outside AWS`).
5. (Optional) Tag: `purpose=saviynt-integration`.
6. **Create access key**.
7. ⚠️ Save **Access Key ID** AND **Secret Access Key** to your scratch note. **The secret is shown ONCE only** — if you close this page without copying it, you'll have to delete the key and create a new one. There's no recovery.
8. Click **Done**.

> Verify by checking the user's Security Credentials tab: you should see exactly one access key listed, status `Active`, with the access key ID you just captured.

---

## D.4 Verify the IAM resources are correctly wired

A 60-second sanity check before moving to the Saviynt side. Each one of these failing means the stack created something subtly broken.

1. **AWS Console → IAM → Users → `<IAMUserName>`**:
   - **Permissions** tab: should show one attached managed policy: `Saviynt-PulumiDemo-IGA-PAM-SaviyntAWSSTSPolicy-...` (lets the user call `sts:AssumeRole` on the role).
   - **Security credentials** tab: one access key, Active.

2. **AWS Console → IAM → Roles → `SaviyntAssumeRole`**:
   - **Trust relationships** tab: should show two trusted principals:
     - `arn:aws:iam::<your-account-id>:root` (this is what lets the IAM user, which is in this account, call AssumeRole)
     - `ec2.amazonaws.com` (service principal; doesn't matter for our use)
   - **Permissions** tab: should show four managed policies:
     - `ReadOnlyAccess` (AWS managed, broad read across services)
     - `SaviyntAWSDenyPolicy` (explicit denies for sensitive read operations — `s3:GetObject`, `sqs:ReceiveMessage`, etc.)
     - `SaviyntCloudPAMPolicy` (allows `iam:Get*`, `iam:List*`, `ec2:Describe*`, `ec2:CreateSecurityGroup`, plus IAM role/policy management)
     - `SaviyntAWSIAMPolicy` (the PAM-critical permissions: `iam:CreateAccessKey`, `iam:DeleteAccessKey`, `iam:CreateUser`, `iam:DeleteUser`, `iam:CreatePolicy`, etc.)

3. **AWS Console → CloudFormation → your stack → Resources** tab: confirm all 6 resources are `CREATE_COMPLETE`.

---

## D.5 Create the AWS Connection in Saviynt

This is the Saviynt-side wiring that uses the IAM user keys you just generated.

### Click-by-click

1. Log into Saviynt EIC as `igaadmin`.
2. Navigate to **Admin** → **Identity Repository** → **Connections**.
3. Click **Actions** → **Create Connection**.
4. **Connection Type**: select `AWS`.
5. **Connection Name**: `AWS-PulumiDemo` (this is what we'll reference from Security Systems in `05`).
6. **Connection Description**: `Saviynt-managed AWS integration for Pulumi demo (IGA + PAM via IAM user)`. Free text.
7. **Default SAV Role**: leave blank — we're not importing AWS IAM users as Saviynt users.

Then "Enter your application details" — fill the visible fields:

| Field | Value | Notes |
|---|---|---|
| **AWS ACCOUNT ID** | Your **customer** AWS account ID (12 digits) | The new AWS account, NOT Saviynt's master account ID |
| **External ID** | leave blank | Not used by this template's auth pattern |
| **Cross Account Role ARN** | leave blank | Not used by this template's auth pattern |
| **Stack Role Name** | leave blank | Not used |
| **ACCESS KEY ID** | The Access Key ID from D.3 Step 3 | Saviynt authenticates as the IAM user with this |
| **SECRET ACCESS KEY** | The Secret Access Key from D.3 Step 3 | Pair to the Access Key ID; this is what makes Saviynt able to call AssumeRole |
| **Role ARN** | The **SaviyntAssumeRole** ARN from D.3 Step 2 | The role Saviynt assumes after authenticating as the user |

Other fields visible on the form (set if shown):
- **PULL_GOV_REGION_ONLY**: `No` (we're on AWS PublicCloud).
- **DEFAULT_REGION**: `us-east-2`.
- **CREATEUSERS**: `NO`.

8. Optionally check **Use Credential Vault** for the SECRET ACCESS KEY if you want Saviynt's native secret vaulting (recommended for production; not required for the demo).
9. Scroll to the bottom. Click **Save and Test Connection**.

### Expected results

- **Green success message** → Saviynt logged in as the IAM user, assumed the role, made a probe IAM call, and got a valid response. You're done with Section D.
- **`InvalidClientTokenId` or `The security token included in the request is invalid`** → Access Key ID or Secret typo. Re-copy from your scratch note. If you've already closed the IAM "Create access key" page, delete the existing key in IAM Console and create a new one — you can't recover the secret.
- **`AccessDenied: User is not authorized to perform: sts:AssumeRole`** → The role ARN is wrong OR the STS policy on the IAM user didn't deploy correctly. Re-verify D.4 step 1.
- **`AccessDenied` on subsequent IAM operations** → Role ARN is correct but the role's permissions are missing. Re-verify D.4 step 2 — the four managed policies should all be attached.

### Verify via API

After Save and Test passes, confirm the connection is queryable:

```
POST https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5/getConnections

Headers:
  Authorization: Bearer <fresh token>
  Content-Type: application/json

Body:
{
  "connectionname": "AWS-PulumiDemo"
}
```

Expected: one record with `connectiontype: "AWS"` and `status: "1"` (active).

---

## D.6 Update broker/.env if not yet set

The broker doesn't talk to AWS directly — it goes through Saviynt — so no AWS credentials live in `broker/.env`. The connection name you used here (`AWS-PulumiDemo`) gets referenced when we create the Security System and Endpoint in `05-aws-iam-pam-endpoint.md`. No `.env` change needed at this stage.

---

## Common Gotchas — Section D

| Symptom | Cause | Fix |
|---|---|---|
| **Save and Test fails with InvalidClientTokenId** | Access Key ID or Secret was typed wrong, OR secret was lost between IAM and Saviynt UI | Delete the access key in IAM, generate a new one, paste fresh into Saviynt |
| **Save and Test fails with AssumeRole AccessDenied** | Role ARN typo, OR the role's trust policy didn't include the IAM user's account, OR the STS policy didn't attach to the user | D.4 verification check #1 and #2 |
| **Saviynt can authenticate but IAM operations fail** | The four managed policies didn't attach to the role | D.4 step 2 — confirm all four policies are on the role; if not, the stack didn't fully apply (rerun with a different stack name) |
| **Secret Access Key lost (closed the IAM page before copying)** | One-time-display policy | Delete the existing access key in IAM Console → Security Credentials → trash icon; click **Create access key** to make a new one; paste fresh into Saviynt and re-test |
| **CFN stack rollback with `EntityAlreadyExists`** | The IAM user name collided with one from a prior run | Delete the orphaned user in IAM, OR re-run the stack with a different `IAMUserName` parameter |
| **`PULL_GOV_REGION_ONLY` field not visible** | UI version differs | Look for it under "Connection Attributes" or expandable section; if absent entirely, that's fine — defaults to PublicCloud |
| **`AWS_ACCOUNT_ID` blank when you submit** | Forgot the field — it's marked required | Paste your customer AWS account ID; **NOT** Saviynt's master account ID |

---

## AWS Cost & Free Tier Notes

Nothing in Section D costs money on its own. Specifically:

| Resource | Cost | Notes |
|---|---|---|
| CloudFormation Stack | $0 | No charge for stacks themselves; only the resources they create |
| IAM User + Role (created by the Stack) | $0 | IAM is always free |
| IAM Policy attachments | $0 | Free |
| Access keys for the IAM user | $0 | Free, including the keys Saviynt will generate at PAM checkout in `05` |
| STS AssumeRole calls (Saviynt as IAM user → role) | $0 | Free |

⚠️ **Don't pick the "Real Time Monitoring" variants** from the template table. Those create CloudWatch event rules + SQS queues that have free-tier caps. **Security Analyzer + IGA + PAM** is the right choice — permissions only, no infrastructure.

**Use a fresh AWS account** if you want the full 12-month free tier on the downstream EC2 deploys (which happen in Pulumi, not here). If you reuse an account older than 12 months, t2.micro starts at ~$8.50/month and the cost story changes — though `pulumi destroy` after each demo run keeps it cents-per-day.

---

## What's next

With the `AWS-PulumiDemo` connection saved & tested green in Saviynt, move to **`05-aws-iam-pam-endpoint.md`**. That covers:

1. Create the `AWS-IAM-Endpoint` Security System and Endpoint in Saviynt (using this connection).
2. Create the `pulumi-deployer` IAM user in your customer AWS account with EC2 deploy permissions.
3. Import IAM users from AWS into Saviynt (the first sync proves the connection works end-to-end for read).
4. Onboard `pulumi-deployer` as a Saviynt PAM account with a rotation policy.
5. Test `/checkout-aws` and `/checkin-aws` through the broker — observe live key rotation.

## Settings to capture (for the broker)

After Section D, nothing in `broker/settings.py` changes — the connection lives entirely in Saviynt. The broker references it indirectly via Saviynt's PAM checkout API once we wire up the IAM endpoint in `05`. Defaults already match what we'll create:

```python
# In broker/settings.py — already set, no change needed at this stage
pam_endpoint_aws    = "AWS-IAM-Endpoint"     # to be created in 05
pam_account_aws_iam = "pulumi-deployer"      # to be created in 05
```
