# 04 — AWS Cross-Account Trust (Saviynt ↔ Customer AWS)

> **Goal:** Establish trust between the Saviynt EIC tenant (hosted in Saviynt's own AWS account) and your customer AWS account using AWS's **cross-account IAM role** pattern. Saviynt's EC2 IAM role calls `sts:AssumeRole` against a role you create in your account; AWS grants short-lived temporary credentials; Saviynt uses those to perform IAM/PAM operations. No long-lived AWS access keys live between the two systems — Saviynt's identity is the EC2 IAM role its instance runs as, attested by AWS's instance metadata service.
>
> This is the foundation for every downstream PAM operation in the demo; **`05-aws-iam-pam-endpoint.md`** depends on this being complete.

> **Why this pattern (not IAM-user-with-keys):** Saviynt's `aws.cloud.deployment` flag is `true` for our tenant (it's running on AWS), which means the AWS Connection's backend processing path **only honors the cross-account fields** (`AWS_ACCOUNT_ID`, `Cross Account Role ARN`, `External ID`). The UI also exposes `ACCESS KEY ID`, `SECRET ACCESS KEY`, and `Role ARN` fields — those are for non-cloud Saviynt deployments and are silently ignored here even if populated. The CloudFormation template Saviynt provides creates an IAM user + role with intra-account trust by default; we deploy it as-is, then **modify the role's trust policy** to a cross-account trust against Saviynt's master account.

## Reference

- Saviynt AWS Integration Guide (PDF in repo: `aws_integration_guide_configuring_the_integration_(aws_cloud)_2026-05-11-12-04-02.pdf`). Sections: "Preparing for Integration (AWS Cloud)", "Option 1: Saviynt Identity Cloud Trusts each AWS Account", "Selecting Stack Templates", "Creating a Connection using the Connection Template".
- Page 38 of that guide has the decisive paragraph: the `update externalconnectiontype` SQL block shows that when `aws.cloud.deployment=true`, the connection's `ATTRIBUTEKEY` list includes `CROSS_ACCOUNT_ROLE_ARN` but **not** `AWS_ACCESS_KEY` / `AWS_ACCESS_SECRET_PASSWORD`. That's why the access-key fields are ignored.

## Prerequisites

1. **A customer AWS account.** Free tier is fine; for the demo we recommend a fresh AWS account so blast radius is zero. Region: `us-east-2` (matches the rest of the demo per `PROGRESS.md`).
2. **AWS Console admin access** to that account (root user or an IAM admin user).
3. **Saviynt's `aws.saas.rolearn` value** — the full ARN of the IAM role attached to Saviynt's EC2 instance in Saviynt's AWS account. This is what your role's trust policy will list as the trusted principal. Find it:
   - Log into Saviynt as `igaadmin` → Admin → Settings → **Configuration Files** → open `externalconfig.properties` → read the value of `aws.saas.rolearn`.
   - Format: `arn:aws:iam::<Saviynt-master-account-id>:role/<some-saviynt-role-name>`.
   - ⚠️ **Just the ARN value, not the `aws.saas.rolearn=` prefix.** AWS rejects the trust policy if you paste the property-file format including the key name.
4. **The "Security Analyzer + IGA + PAM" CloudFormation template** — either the S3 URL from the AWS Integration Guide's template table, OR the local JSON. The template creates: one IAM user, one IAM role, four managed policies. We'll deploy it, then keep only the role + three of its policies (delete the rest as cleanup).
5. **An External ID of your choice** — any short alphanumeric string Saviynt will pass when assuming the role, to satisfy AWS's confused-deputy protection. Pick something distinctive, e.g., `pulumi-demo-2026-05-12`. Copy it to your scratch note — you'll paste it into the trust policy *and* Saviynt's Connection.
6. **Confirm tenant deployment mode:** in `externalconfig.properties`, verify `aws.cloud.depoyment=true` (sic — the typo is in Saviynt's config). If it's `false`, the IAM-user pattern would apply instead; consult an earlier revision of this doc in `git log`.

---

## D.1 Decide on naming and capture values you'll reuse

| Variable | Example | Source | Used where |
|---|---|---|---|
| **IAMUserName** *(you choose)* | `saviynt-pam-svc` | You decide | CFN stack parameter; the IAM user this creates is incidental and will be deleted in D.6 |
| **Customer AWS account ID** | `987654321098` | AWS Console top-right account menu | Saviynt Connection's `AWS_ACCOUNT_ID` |
| **Saviynt master role ARN** | `arn:aws:iam::123456789012:role/saviynt-eic-app` | `aws.saas.rolearn` in Saviynt's `externalconfig.properties` | Role's trust policy `Principal` |
| **External ID** *(you choose)* | `pulumi-demo-2026-05-12` | You decide | Role's trust policy `Condition`, AND Saviynt Connection's `External ID` field |
| **CFN stack name** | `Saviynt-PulumiDemo-IGA-PAM` | You decide | AWS Console only |
| **CFN template URL or local file** | `https://saviynt-cf-templates.s3.amazonaws.com/.../security-analyzer-iga-pam.json` | From Saviynt support or PDF link | CFN Step 1 |
| **SaviyntAssumeRole ARN** | `arn:aws:iam::987654321098:role/Saviynt-PulumiDemo-IGA-PAM-SaviyntAssumeRole-XXXXXXX` | IAM Console → Roles → search `SaviyntAssumeRole` after stack creates (NOT in Outputs) | Saviynt Connection's `Cross Account Role ARN` |
| **Connection name in Saviynt** | `AWS-PulumiDemo` | You decide | Used as the link from Security System in `05-aws-iam-pam-endpoint.md` |

---

## D.2 Deploy the CloudFormation Stack

This creates `SaviyntUser` (we'll delete in D.6), `SaviyntAssumeRole` (we'll modify its trust policy in D.4), and four managed policies.

### Click-by-click

1. Log into the **AWS Console** as admin in your customer AWS account.
2. Switch region to **us-east-2**.
3. Navigate to **CloudFormation**.
4. **Create stack** → **With new resources (standard)**.
5. **Prepare template**: `Template is ready` → **Template source**: `Amazon S3 URL` (or upload the local JSON).
6. Paste the URL or upload the file.
7. **Next** → fill in:
   - **Stack name**: `Saviynt-PulumiDemo-IGA-PAM`
   - **Parameters → IAMUserName**: e.g., `saviynt-pam-svc` (the user will exist briefly; we delete in D.6)
8. **Next** → defaults → **Next** → tick **I acknowledge that AWS CloudFormation might create IAM resources with custom names** → **Create stack**.
9. Wait for `CREATE_COMPLETE` (30-60 seconds).

---

## D.3 Find the SaviyntAssumeRole ARN

The role ARN isn't in the stack's Outputs (a template quirk — only `SaviyntUser` is exported).

1. AWS Console → **IAM** → **Roles**.
2. Search for `SaviyntAssumeRole`. You'll see a CFN-generated name like `Saviynt-PulumiDemo-IGA-PAM-SaviyntAssumeRole-AB1CDEFGHIJK`.
3. Click into the role → copy the **ARN** from the Summary panel → save in your scratch note.

---

## D.4 Replace the role's trust policy with cross-account trust

This is the critical step that converts the template's default intra-account trust into the cross-account pattern Saviynt needs.

### Current trust (what the template created)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": ["ec2.amazonaws.com"],
        "AWS": "arn:aws:iam::<your-account-id>:root"
      }
    }
  ]
}
```

This trusts your *own* account's root + the EC2 service. Saviynt's account can't assume the role with this policy.

### New trust (cross-account to Saviynt)

1. In IAM → Roles → `SaviyntAssumeRole` → **Trust relationships** tab → **Edit trust policy**.
2. Replace the entire JSON with:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "<paste-the-real-aws.saas.rolearn-VALUE-here>"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "<paste-your-chosen-External-ID-here>"
        }
      }
    }
  ]
}
```

3. **Update policy**.

Filled-in example (using sanitized values):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::123456789012:role/saviynt-eic-app"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "pulumi-demo-2026-05-12"
        }
      }
    }
  ]
}
```

⚠️ **Common typo:** if you copy from `externalconfig.properties`, strip the `aws.saas.rolearn=` prefix. The principal value is **just the ARN**.

### Verify

After saving, the **Trust relationships** tab should show:
- Trusted entity: AWS account `<Saviynt-master-account-id>` (or the role identity inside it)
- Conditions: `sts:ExternalId` `StringEquals` `<your-chosen-value>`

---

## D.5 Create the AWS Connection in Saviynt

### Click-by-click

1. Log into Saviynt as `igaadmin`.
2. **Admin** → **Identity Repository** → **Connections** → **Actions** → **Create Connection**.
3. Set:
   - **Connection Type**: `AWS`
   - **Connection Name**: `AWS-PulumiDemo`
   - **Connection Description**: `Cross-account connection to customer AWS for Pulumi pipeline demo (IGA + PAM)`
   - **Default SAV Role**: leave blank
4. Under "Enter your application details":

| Field | Value |
|---|---|
| **AWS ACCOUNT ID** | Your **customer** AWS account ID (12 digits) — NOT Saviynt's master account ID |
| **External ID** | The same External ID string you typed into the trust policy in D.4 |
| **Cross Account Role ARN** | The `SaviyntAssumeRole` ARN from D.3 |
| **Stack Role Name** | Leave blank (optional; `aws.saas.rolestackname` in tenant externalconfig covers it) |
| **ACCESS KEY ID** | Leave blank ⚠️ |
| **SECRET ACCESS KEY** | Leave blank ⚠️ |
| **Role ARN** | Leave blank ⚠️ |

⚠️ **The three "leave blank" fields are visible in the UI because Saviynt's connection form covers both auth patterns, but for cloud-hosted Saviynt the backend ignores them.** Filling them in with values from a misread of the docs is what tripped us up the first time — leave them empty.

5. **Save and Test Connection**.

### Expected results

- **Green success** → cross-account trust working end-to-end. Done with Section D.
- **`AccessDenied: sts:AssumeRole`** → trust policy doesn't match the assuming principal, or External ID mismatch. Re-check D.4: the `Principal.AWS` value must exactly equal `aws.saas.rolearn`; the `Condition.StringEquals.sts:ExternalId` must exactly equal the value in Saviynt's `External ID` field.
- **`InvalidClientTokenId`** → `Cross Account Role ARN` typo. Re-paste from D.3.
- **Connection error with no specific message** → most often, the tenant is processing the access-key fields (despite `aws.cloud.deployment=true`) and they were populated. Clear them, retry.

### Verify via API

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

Expected: one record with `connectiontype: "AWS"` and `status: "1"`.

---

## D.6 Cleanup the unused IAM user

The CFN template creates `SaviyntUser` (IAM user) and `SaviyntAWSSTSPolicy` (managed policy attached to it) for the non-cloud auth pattern we're not using. They're dead weight; safest to delete to minimize attack surface.

### Click-by-click

1. AWS Console → **IAM** → **Users** → click `<IAMUserName>` (your `saviynt-pam-svc`).
2. **Security credentials** tab: confirm there are no access keys (we never created any). If there are by accident, delete them first.
3. Back to the user's main page → **Delete** (top right) → type the username to confirm → **Delete**.
4. **IAM** → **Policies** → search `Saviynt-PulumiDemo-IGA-PAM-SaviyntAWSSTSPolicy`. If present, **Delete** it too. (May fail if still attached to a user — if the user is already deleted, IAM lets the policy go.)

### Note about CloudFormation drift

After this cleanup, CloudFormation will flag the stack as "drifted" if you run a drift detection — because the live resources don't match the template. That's expected and harmless for our purposes. If you ever delete the stack, the drift on those two resources will be ignored since they no longer exist.

The three managed policies that grant the role its actual PAM permissions stay:
- `SaviyntAWSDenyPolicy` (explicit denies on sensitive read operations)
- `SaviyntCloudPAMPolicy` (`iam:Get*`, `iam:List*`, `ec2:Describe*`, plus security-group / IAM role management)
- `SaviyntAWSIAMPolicy` (the PAM-critical: `iam:CreateAccessKey`, `iam:DeleteAccessKey`, `iam:CreateUser`, etc.)
- Plus the AWS managed `ReadOnlyAccess` from the template

Those four together are what `SaviyntAssumeRole` gives Saviynt the ability to do once it assumes.

---

## Common Gotchas — Section D

| Symptom | Cause | Fix |
|---|---|---|
| **Trust policy save: "Invalid principal in policy: 'aws.saas.rolearn=arn:...'"** | Pasted the property-file format including the `aws.saas.rolearn=` key prefix | Strip the prefix; the `Principal.AWS` value is just the ARN |
| **Save and Test fails with AssumeRole AccessDenied** | Trust policy doesn't list `aws.saas.rolearn` value as principal, OR External ID mismatch between trust policy condition and Saviynt's External ID field | Compare both character-for-character; re-paste from scratch note |
| **Save and Test fails with InvalidClientTokenId** | Wrong `Cross Account Role ARN` | Re-copy from IAM Console (D.3); strip any trailing whitespace |
| **Save and Test fails despite trust policy being correct** | The three "leave blank" fields (ACCESS KEY ID, SECRET, Role ARN) are populated. The backend may attempt the IAM-user auth path even when cross-account fields are also set, depending on tenant config | Clear the access-key fields entirely; retry |
| **"You don't have permission" on Edit trust policy** | AWS user lacks IAM permissions | Use root user or an IAM user with `AdministratorAccess` for this one-time edit |
| **CFN stack rollback with `EntityAlreadyExists`** | The IAMUserName collided with a prior run | Delete the orphan user in IAM, OR re-run with a different `IAMUserName` |
| **External ID looks invisible in Saviynt UI after Save** | Saviynt may mask it as a credential field | That's fine — it's stored; re-test to confirm |
| **`PULL_GOV_REGION_ONLY` field not visible** | UI version differs | Look for it in expandable sections; if absent entirely, defaults to PublicCloud |

---

## AWS Cost & Free Tier Notes

Nothing in Section D costs money on its own:

| Resource | Cost | Notes |
|---|---|---|
| CloudFormation Stack | $0 | No charge for stacks |
| IAM Role + Policies | $0 | IAM is always free |
| STS AssumeRole calls (Saviynt → your role) | $0 | Free |
| Short-lived credentials issued by AWS to Saviynt | $0 | Free |

⚠️ **Don't pick the "Real Time Monitoring" variants** of the CFN template — those create CloudWatch + SQS infrastructure that has free-tier caps. **Security Analyzer + IGA + PAM** is permissions-only.

**Use a fresh AWS account** for the full 12-month free tier on the downstream EC2 deploys (handled in Pulumi, not here). `pulumi destroy` after each demo run keeps cost at pennies even if you reuse an older account.

---

## Bootstrap-secrets inventory (talk-track note)

The cross-account pattern means **NO new long-lived secrets** are introduced between Saviynt and your AWS account. Saviynt's identity is its EC2 IAM role, attested by AWS's instance metadata service (continuously short-lived, never seen by Saviynt's code). Your trust policy gates everything on that principal + the External ID condition. The External ID itself isn't a secret — it's a confused-deputy mitigation; an attacker who knew it still couldn't impersonate Saviynt without controlling Saviynt's EC2 instance metadata.

The demo's standing-secrets count remains **two**:
1. Saviynt SA password — broker's `.env`
2. HMAC secret — broker's `.env` + GitHub repo secret

This pattern would have been **three** had we used the IAM-user-with-keys auth model. Worth a one-line mention in `TALK_TRACK.md`'s talking points: *"We chose cross-account role trust over IAM-user-with-keys explicitly because the former eliminates one standing AWS credential — same risk surface as a typical enterprise integration."*

---

## What's next

With the `AWS-PulumiDemo` connection green, move to **`05-aws-iam-pam-endpoint.md`**:

1. Create the `AWS-IAM-Endpoint` Security System and Endpoint in Saviynt (using this connection).
2. Create the `pulumi-deployer` IAM user in your customer AWS account with EC2 deploy permissions.
3. Import IAM users from AWS into Saviynt (first sync proves the connection works end-to-end for read).
4. Onboard `pulumi-deployer` as a Saviynt PAM account with a rotation policy.
5. Test `/checkout-aws` and `/checkin-aws` through the broker — observe live key rotation.

## Settings to capture (for the broker)

After Section D, nothing in `broker/settings.py` changes — the connection lives entirely in Saviynt. The broker references it indirectly via Saviynt's PAM checkout API once we wire up the IAM endpoint in `05`. Defaults already match what we'll create:

```python
pam_endpoint_aws    = "AWS-IAM-Endpoint"     # to be created in 05
pam_account_aws_iam = "pulumi-deployer"      # to be created in 05
```
