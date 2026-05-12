# 04 — AWS Cross-Account Trust (Saviynt ↔ Customer AWS)

> **Goal:** Establish bidirectional trust between the Saviynt EIC tenant (hosted in Saviynt's AWS account) and your customer AWS account. Saviynt assumes an IAM role in your account to perform IAM/PAM operations — create/delete IAM users, generate and rotate access keys, attach policies. This is the foundation for every downstream PAM operation in the demo; **`05-aws-iam-pam-endpoint.md`** depends on this being complete.

## Reference

- Saviynt AWS Integration Guide (PDF in repo: `aws_integration_guide_configuring_the_integration_(aws_cloud)_2026-05-11-12-04-02.pdf`). Sections referenced: "Preparing for Integration (AWS Cloud)", "Option 1: Saviynt Identity Cloud Trusts each AWS Account", "Selecting Stack Templates", "Creating a Connection using the Connection Template".
- Saviynt-deployment model: this tenant is `eic-poc-wesharris.saviyntcloud.com` — Saviynt-hosted on AWS. The AWS account hosting Saviynt is the **Master Account**. Your AWS account (the one we're creating now) is the **Customer Account** that Saviynt will trust.

## Prerequisites

1. **A customer AWS account.** Free tier is fine; for the demo we recommend a fresh AWS account so blast radius is zero. Region: `us-east-2` (matches the rest of the demo per `PROGRESS.md`).
2. **AWS Console admin access** to that account (root user or an IAM admin user).
3. **Saviynt's master AWS account ID** (12-digit). This identifies which Saviynt instance is allowed to assume the role you'll create. Two ways to get it:
   - **Preferred:** Log into Saviynt as `igaadmin` → Admin → Settings → **Configuration Files** → open `externalconfig.properties` → read the value of `aws.saas.accountid`. Copy the 12 digits.
   - **Fallback:** Open a Saviynt support ticket. The CloudOps team will provide it. Don't proceed without this value — it's the trust anchor for the entire integration.
4. **CloudFormation template URL** for `Security Analyzer + IGA + PAM` (read/write, includes PAM operations). Source: the Saviynt AWS Integration Guide PDF, "Selecting Stack Templates" table, the **"Security Analyzer + IGA + PAM"** row's "Click to Download" link. Copy the **S3 URL** from that link — that's the value we'll paste into CloudFormation.
   - If you only have the PDF without an active hyperlink, open a Saviynt support ticket and ask for the current S3 template URL for "Security Analyzer + IGA + PAM" for the Amsterdam GA release.
5. An **External ID** of your choice — any string Saviynt will pass when assuming the role, to satisfy AWS's confused-deputy protection. Pick something distinctive, e.g., `pulumi-demo-2026-05-11`. Write it down — you'll paste it into both AWS *and* Saviynt.

---

## D.1 Decide on naming and capture values you'll reuse

Open a scratch note and fill these in as you go. Each gets used at least twice during this section.

| Variable | Example | Where you'll need it |
|---|---|---|
| Saviynt master AWS account ID | `123456789012` *(from `externalconfig.properties`'s `aws.saas.accountid`)* | CloudFormation `MasterAccID` parameter |
| Customer AWS account ID | `987654321098` *(the new free-tier account)* | Saviynt Connection's `AWS_ACCOUNT_ID` field |
| External ID | `pulumi-demo-2026-05-11` | CloudFormation `EXTERNAL_ID` parameter AND Saviynt Connection's `EXTERNAL_ID` field — must match exactly |
| CloudFormation stack name | `Saviynt-PulumiDemo-IGA-PAM` | AWS Console only |
| CloudFormation template URL | `https://saviynt-cf-templates.s3.amazonaws.com/.../security-analyzer-iga-pam.json` *(from Saviynt support or PDF)* | CloudFormation Step 1 |
| CROSS_ACCOUNT_ROLE_ARN | `arn:aws:iam::987654321098:role/Saviynt-PulumiDemo-IGA-PAM-SaviyntAWSRole-XXXXXXXXXXXXX` *(produced by CFN, captured from Stack Outputs)* | Saviynt Connection's `CROSS_ACCOUNT_ROLE_ARN` field |
| Saviynt admin email | `igaadmin@your-org.com` | Saviynt Connection's `ADMIN_EMAIL` field |
| Connection name in Saviynt | `AWS-PulumiDemo` | Used as the connection link from the Security System in `05-aws-iam-pam-endpoint.md` |

---

## D.2 Deploy the CloudFormation Stack in your AWS account

This creates the cross-account IAM Role with all permissions Saviynt needs.

### Click-by-click

1. Log into the **AWS Console** as admin in your customer AWS account.
2. Switch region to **us-east-2** (top-right region selector). CloudFormation stacks are region-scoped; the role itself is global but it's tidier to do this in our designated demo region.
3. Navigate to **CloudFormation** (search in the top services bar).
4. Click **Create stack** → **With new resources (standard)**.
5. On the **Create stack** wizard:
   - **Prerequisite — Prepare template**: Choose `Template is ready`.
   - **Specify template** → **Template source**: Choose `Amazon S3 URL`.
   - **Amazon S3 URL**: paste the URL from the **"Security Analyzer + IGA + PAM"** template you captured in prerequisites #4.
6. Click **Next** → you reach **Step 2 — Specify stack details**.
7. Fill in:
   - **Stack name**: `Saviynt-PulumiDemo-IGA-PAM` (or whatever you put in your scratch note). Must be alphanumeric + hyphens; ≤128 chars; starts with a letter.
   - **Parameters → MasterAccID**: Saviynt's master AWS account ID (12 digits, from prerequisite #3). ⚠️ **Not your account ID — Saviynt's.**
   - **Parameters → EXTERNAL_ID**: the External ID string you picked (e.g., `pulumi-demo-2026-05-11`). ⚠️ Copy it character-perfect; you'll paste the same value into Saviynt later.
8. Click **Next** → **Step 3 — Configure stack options**.
9. (Optional) Add a tag: Key=`Project`, Value=`PulumiSaviyntDemo`. Anything else default.
10. Click **Next** → **Step 4 — Review**.
11. Scroll to the bottom. Tick:
   - ☑ **I acknowledge that AWS CloudFormation might create IAM resources with custom names**
   - ☑ (if shown) **I acknowledge that AWS CloudFormation might require the following capability: CAPABILITY_AUTO_EXPAND**
12. Click **Create stack**.
13. Wait. Status goes `CREATE_IN_PROGRESS` → `CREATE_COMPLETE` (usually 30-60 seconds).

### If you get errors

| Symptom | Cause | Fix |
|---|---|---|
| `Template format error: At least one Resources member must be defined` | Wrong S3 URL — pointed at non-template or empty file | Re-verify the URL with Saviynt support; ensure it's the IGA+PAM variant, not Security Analyzer alone |
| `User: arn:aws:iam::...:user/... is not authorized to perform: iam:CreateRole` | AWS user lacks IAM permissions | Use root user or an IAM user with `AdministratorAccess` for this one-time stack creation |
| `Stack rollback initiated` | Some resource creation failed | Click into Stack → Events tab → find the first FAILED line; usually a name collision (run again with a different stack name) |

---

## D.3 Capture the Stack Outputs

1. Once the stack reaches `CREATE_COMPLETE`, click the stack name to open it.
2. Click the **Outputs** tab.
3. Note the **SaviyntAWSRole** key's value — this is your **`CROSS_ACCOUNT_ROLE_ARN`**. Copy it into your scratch note. Format will look like:
   ```
   arn:aws:iam::987654321098:role/Saviynt-PulumiDemo-IGA-PAM-SaviyntAWSRole-AB1CDEFGHIJK
   ```
4. Confirm the **ExternalID** you used matches what's in your scratch note (the value is the parameter you typed in Step 2, not in Outputs).

> **Both the Role ARN and the External ID go into Saviynt next. Either typo blocks the entire integration with a `STS AssumeRole` failure.**

---

## D.4 (Optional but recommended) Verify the role exists in IAM

A 30-second sanity check before moving to the Saviynt side:

1. AWS Console → **IAM** → **Roles**.
2. Search for the role name fragment (`Saviynt-PulumiDemo-IGA-PAM-SaviyntAWSRole`).
3. Click into the role → **Trust relationships** tab.
4. Confirm:
   - **Principal**: `arn:aws:iam::<Saviynt-master-account-ID>:role/<some-saviynt-role>` — i.e., Saviynt's account is listed as the trusted entity.
   - **Condition**: `StringEquals` on `sts:ExternalId` matching your External ID.
5. **Permissions** tab: you should see one or more managed policies attached covering IAM (`iam:*`), STS, and PAM-related permissions. (Read-only-ish if you mistakenly picked the wrong template — go back to D.2.)

---

## D.5 Create the AWS Connection in Saviynt

This is the Saviynt-side wiring that uses the role you just created.

### Click-by-click

1. Log into Saviynt EIC as `igaadmin`.
2. Navigate to **Admin** → **Identity Repository** → **Connections**.
3. Click **Actions** → **Create Connection**.
4. On the **Add/Update Connection** page, fill in:

| Field | Value | Notes |
|---|---|---|
| **Connection Name** | `AWS-PulumiDemo` | Used as the link from Security System in 05 |
| **Connection Description** | `Cross-account connection to customer AWS for Pulumi pipeline demo (IGA+PAM)` | Free text |
| **Connection Type** | `AWS` | Dropdown |
| **Email Template** | Leave blank | Optional notifications |
| **Default SAV Role** | Leave blank | We're not importing Saviynt users from AWS |
| **AWS_ACCOUNT_ID** | Your **customer** AWS account ID (12-digit) | ⚠️ NOT Saviynt's master account ID. This is your new account. |
| **ADMIN_EMAIL** | `igaadmin@your-org.com` (or any valid email) | Default email for admin user during account onboarding |
| **CROSS_ACCOUNT_ROLE_ARN** | The full ARN you captured from Stack Outputs in D.3 | Format: `arn:aws:iam::<your-account-id>:role/Saviynt-...-SaviyntAWSRole-...` |
| **AWS_STACK_ROLE_NAME** | Leave blank | Optional when `aws.saas.rolearn` is set in externalconfig (it is for cloud-hosted Saviynt) |
| **EXTERNAL ID** | Same External ID string you typed into the CFN stack | Must match exactly, character-for-character |
| **PULL_GOV_REGION_ONLY** | `No` | We're on AWS PublicCloud, not GovCloud |
| **DEFAULT_REGION** | `us-east-2` | Matches the rest of the demo |
| **CREATEUSERS** | `NO` | We don't want Saviynt to auto-create Saviynt-side identities from imported IAM users |

5. Scroll to the bottom. Click **Save and Test Connection**.

### Expected results

- **Green "Connection Successful" / similar message** → Saviynt assumed the role, made a probe IAM call, and got a valid response. You're done with Section D.
- **`AccessDenied: User: arn:aws:iam::<Saviynt-account>:role/<saviynt-role> is not authorized to perform: sts:AssumeRole`** → External ID mismatch or trust policy didn't deploy correctly. Re-verify D.4 trust relationship; re-confirm the External ID in Saviynt matches what's in the CFN stack character-for-character.
- **`InvalidClientTokenId`** → typo in `CROSS_ACCOUNT_ROLE_ARN`. Re-paste from your scratch note.
- **Timeout / no response** → tenant's `aws.saas.rolearn` / `aws.saas.rolestackname` in externalconfig.properties is missing or misconfigured. Check those values, or open a Saviynt support ticket.

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

The broker doesn't talk to AWS directly — it goes through Saviynt — so no AWS credentials live in `broker/.env`. But the connection name you used here gets referenced when we create the Security System and Endpoint in `05-aws-iam-pam-endpoint.md`. No `.env` change needed at this stage.

---

## Common Gotchas — Section D

| Symptom | Cause | Fix |
|---|---|---|
| **Save and Test fails with AssumeRole AccessDenied** | External ID mismatch between CFN stack parameter and Saviynt Connection's External ID field | Compare character-for-character; common issues are trailing whitespace or invisible Unicode from copy-paste |
| **Save and Test fails with InvalidClientTokenId / Role does not exist** | Wrong CROSS_ACCOUNT_ROLE_ARN | Re-copy from Stack Outputs → SaviyntAWSRole value; ensure no leading/trailing spaces |
| **CFN stack rollback with `InvalidAction: PutAccountPasswordPolicy`** | Customer AWS account is part of an Organization that overrides account password policies | Choose a free-tier standalone account, or get the OU policy adjusted; for demo simplicity use standalone |
| **`PULL_GOV_REGION_ONLY` field not visible** | UI version differs | Look for it under "Connection Attributes" or "Connection Properties" expandable section |
| **Saviynt master AWS account ID hard to find** | `externalconfig.properties` is admin-restricted and may not be visible in the tenant UI | Open a Saviynt support ticket. The CloudOps team will provide it within hours. |
| **Trust policy in CFN role is missing `sts:ExternalId` condition** | Used the wrong CF template (one that doesn't take External ID parameter) | Re-create stack with the IGA+PAM template; the External ID is mandatory for cross-account roles |
| **"Region not supported"** when saving connection | DEFAULT_REGION doesn't match a region the AWS connector supports | Use `us-east-2`. China regions (`cn-*`) are explicitly NOT supported per the Saviynt guide. |

---

## AWS Cost & Free Tier Notes

Nothing in Section D costs money on its own. Specifically:

| Resource | Cost | Notes |
|---|---|---|
| CloudFormation Stack | $0 | No charge for stacks themselves; only the resources they create |
| IAM Role (created by the Stack) | $0 | IAM is always free |
| IAM Policy attachments | $0 | Free |
| STS AssumeRole calls (Saviynt → your account) | $0 | Free |

⚠️ **Don't pick the "Real Time Monitoring" variants** from the template table. Those create CloudWatch event rules + SQS queues that have free-tier caps (10 metrics, 1M API requests/month, etc.). For a demo run-and-tear-down pattern you'd stay under, but they add operational surface area for zero demo value here. **Security Analyzer + IGA + PAM** is the right choice — permissions only, no infrastructure.

**Use a fresh AWS account** if you want the full 12-month free tier on the downstream EC2 deploys (which happen in Pulumi, not here). If you reuse an account older than 12 months, t2.micro starts at ~$8.50/month and the cost story changes — though `pulumi destroy` after each demo run keeps it cents-per-day.

## What's next

With the cross-account trust working and the `AWS-PulumiDemo` connection saved & tested green in Saviynt, move to **`05-aws-iam-pam-endpoint.md`**. That covers:

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
