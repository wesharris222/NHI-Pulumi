# 02 — Entitlements + Approval Workflows

> **Goal:** Create the two entitlements (`Deploy-EC2-Dev` auto-approve, `Deploy-EC2-Prod` manual approve) under the `Pulumi-Pipeline-AWS` endpoint, and wire up the workflows that drive the demo's two outcomes.

## Prerequisites
- Section A (`01-application-onboarding.md`) completed
- For demo v1, both the broker SA and the prod-approver are `igaadmin`. Section C still creates `wes-dev` and (optionally) `wes-approver` as the *beneficiary*. The **approver** in the workflow we're about to build is `igaadmin`.

## Tenant base URL

```
BASE="https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5"
```

---

## B.1 Entitlement Type

Saviynt requires entitlements to belong to an **Entitlement Type**, which is a per-endpoint definition of what kind of access this endpoint manages. We'll use `Entitlement` as our type name.

### Click-by-click

1. Log in as `igaadmin`.
2. Navigate to **Admin** → **Identity Repository** → **Entitlement Types**.
   - **VERIFY (Amsterdam UI)**: alternate path is editing the endpoint directly and using its **Entitlement Types** sub-tab.
3. Click **Actions** → **Create Entitlement Type**.
4. Fill in:
   - **Entitlement Type**: `Entitlement`
   - **Endpoint**: select `Pulumi-Pipeline-AWS`
   - **Display Name**: `Pipeline Access`
   - **Description**: `Pipeline deployment permission`
   - **Workflow**: leave blank (overridden per-entitlement below)
   - **Request Option**: **Requestable** (or "Yes" depending on UI version)
5. **Save**.

> If `Entitlement` already exists on this endpoint, just use it.

### Verify Entitlement Type

`getEntitlementTypes` is a **GET** endpoint with query parameters.

```bash
curl -s -G "$BASE/getEntitlementTypes" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "endpointname=Pulumi-Pipeline-AWS" \
  --data-urlencode "max=10" \
  | jq '.'
```

**Expected:** record with `entitlementType: "Entitlement"` (or whatever you used) on `endpoint: "Pulumi-Pipeline-AWS"`.

If the type name you used differs from `Entitlement`, set `ENTITLEMENT_TYPE` in `broker/settings.py` accordingly.

---

## B.2 Approval Workflow #1 — Auto-Approve (for Deploy-EC2-Dev)

This workflow auto-approves any request without human intervention.

> **Recommended path: clone an OOB auto-approval workflow.** Saviynt ships an auto-approve workflow stock (`AutoApproveWorkflow` / `AutoApprove` / `SimpleAutoApproval` depending on build). Cloning it skips the workflow editor's expression-language minefield entirely. The from-scratch If-Else build is documented further down as a fallback.

### Path A — Clone an OOB auto-approval (recommended)

1. **Admin** → **Workflows**. Find the stock auto-approve workflow. Likely names: `AutoApproveWorkflow`, `AutoApprove`, or `SimpleAutoApproval`.
2. **Verify before cloning** — open it and confirm:
   - **Workflow Type**: `AccessAddWorkflow` (or generic enough to bind to entitlement requests). Wrong type → the bind in B.4 will fail.
   - **Status**: Active / Published.
   - The flow actually auto-approves end-to-end (some OOB "Auto*" workflows auto-*route*, not auto-*approve* — don't trust the name; trace the canvas).
3. Use the **Clone** / **Copy** action (right-click or Actions menu).
4. On the clone, set:
   - **Name**: `WF-DeployEC2-Dev-AutoApprove`
   - **Description**: `Auto-approve workflow for Deploy-EC2-Dev entitlement (cloned from <OOB name>)`
   - **Workflow Type**: confirm `AccessAddWorkflow`
5. **Save**.
6. **Activate** / **Publish** the clone. ⚠️ critical — without activation, the workflow exists but won't fire when bound.

**Don't edit the OOB original in place.** It's often wired into other tenant defaults (the global access-request page, etc.); modifying it has side effects.

### Path B — Build from scratch (fallback)

Use this only if no suitable OOB workflow exists, or cloning isn't permitted on your tenant.

1. Navigate to **Admin** → **Workflows**.
2. **Actions** → **Create Workflow**.
3. Fill in:
   - **Name**: `WF-DeployEC2-Dev-AutoApprove`
   - **Workflow Type**: `AccessAddWorkflow`
   - **Description**: `Auto-approve workflow for Deploy-EC2-Dev entitlement`
4. **Save** to create the empty workflow shell, then enter the **Workflow Editor**.
5. Build the flow using the **If-Else with `true` condition** pattern:

   ```
   Start → If-Else (condition: true) → Auto-Approve End
                                     → (false branch → End)
   ```

   In the If-Else block, set the condition:

   - **Expression Language** dropdown → if a `Static` / `Constant` / `Boolean` option is offered, **pick that** — it converts the field to a true/false toggle and bypasses the parser entirely. Otherwise pick `Groovy` (or `GroovyScript`).
   - **Expression** body → type the single word below, nothing else. **Do not include backticks or the word `groovy`** — those are markdown formatting in this doc, not part of the expression:

         true

   - If `true` alone is rejected by the parser, fall back in order: `1 == 1`, `Boolean.TRUE`, `return true`. All evaluate to true and parse unambiguously as Groovy.
   - Both branches (true *and* false) must terminate at an **End** node, even though the false branch is never taken. An unconnected branch is the most common reason Activate stays greyed out.

6. **Save**.
7. **Activate** / **Publish** the workflow.

### ⚠️ Gotcha: requestor = beneficiary auto-approve restriction

Saviynt OOB rule (verified): **"When the requestor, beneficiary and the approver is the same, the system doesn't allow the request to auto approve."**

For our demo this is **not a problem** because:
- Requestor: `igaadmin` (the broker SA)
- Beneficiary: `wes-dev`
- Approver: auto-approve / `igaadmin`

These are different user identities (or auto-approve, which doesn't count as a person) so the restriction doesn't fire. If you ever test by submitting a request manually as `wes-dev` for `wes-dev`, the auto-approve will silently fail.

---

## B.3 Approval Workflow #2 — Manual Approve via igaadmin (for Deploy-EC2-Prod)

For demo v1, the approver is `igaadmin` (ROLE_ADMIN). This is a deliberate simplification — in a production design you'd separate request submission and approval into distinct identities.

> **Recommended path: clone an OOB single-step approval workflow** and change the approver to `igaadmin`. Same reasoning as B.2 — skip the editor where you can.

### ⚠️ Why the approver field actually matters (don't skip it)

When a request hits an Approval block, Saviynt creates an approval task **assigned to the named user**. The task lands in **that user's** approval inbox. ROLE_ADMIN can usually *view* any pending approval via admin pages, but whether ROLE_ADMIN can *approve* a task assigned to a different user depends on tenant config — some tenants enforce strict assignment.

**Demo-safe rule:** the Approval block's approver must be the same user you'll log in as during the demo (`igaadmin` for v1). Then the task lands in that user's inbox and "approve" is one click — no admin override or task reassignment needed.

### Path A — Clone an OOB single-approval workflow (recommended)

1. **Admin** → **Workflows**. Find a stock single-step approval workflow. Likely names: `SingleApproval`, `OneStepApproval`, `ManagerApproval` (the last one routes to the requestor's manager — fine to clone, just change the approver field).
2. Verify on the OOB original:
   - **Workflow Type**: `AccessAddWorkflow`
   - **Status**: Active / Published
   - Single Approval block, single End — no extra escalation/notification logic that'd surprise the demo.
3. **Clone** the workflow.
4. On the clone, set:
   - **Name**: `WF-DeployEC2-Prod-ManualApprove`
   - **Description**: `Manual approval for prod deploys (igaadmin approves in v1, cloned from <OOB name>)`
   - **Workflow Type**: confirm `AccessAddWorkflow`
5. Open the Approval block and set:
   - **Approver Type**: `User`
   - **Approver**: `igaadmin`  ← critical, see warning above
   - **Rank**: `1`
   - **Escalation**: leave blank
   - **Approval Comments Required**: ON for richer demo audit
6. **Save** and **Activate**.

### Path B — Build from scratch (fallback)

1. **Admin** → **Workflows** → **Actions** → **Create Workflow**.
2. Fill in:
   - **Name**: `WF-DeployEC2-Prod-ManualApprove`
   - **Workflow Type**: `AccessAddWorkflow`
   - **Description**: `Manual approval for prod deploys (igaadmin approves in v1)`
3. **Save**, enter editor.
4. Build the flow:
   - **Start** node
   - **Approval** block (single)
   - **End** node
5. Configure the Approval block (same fields as Path A step 5).
6. **Save** and **Activate**.

### ⚠️ Demo-narrative note

When demoing, you'll log in as `igaadmin` to approve. That's fine functionally, but for the talk track you may want to preface with: *"In production this approver would be a separate identity — likely an application owner or a senior engineer with the prod entitlement. For demo simplicity, our admin approves."*

This keeps the demo honest. Section C documents an optional `wes-approver` user if you'd rather demonstrate the cleaner separated-duties variant later.

---

## B.4 Create the Two Entitlements

### Deploy-EC2-Dev

1. **Admin** → **Identity Repository** → **Entitlements**.
2. **Actions** → **Create Entitlement**.
3. Fill in:
   - **Entitlement Value**: `Deploy-EC2-Dev`
   - **Display Name**: `Deploy to EC2 Dev Environment`
   - **Endpoint**: `Pulumi-Pipeline-AWS`
   - **Entitlement Type**: `Entitlement`
   - **Description**: `Permission to run the pipeline against the dev environment. Auto-approved on request.`
   - **Status**: `1` (active)
   - **Requestable**: `1` (yes) ⚠️ must be set
   - **Access**: `Select`
   - **Risk**: `Low`
   - **Workflow**: `WF-DeployEC2-Dev-AutoApprove`
4. **Save**.

### Deploy-EC2-Prod

Repeat with:
- **Entitlement Value**: `Deploy-EC2-Prod`
- **Display Name**: `Deploy to EC2 Prod Environment`
- **Description**: `Permission to run the pipeline against prod. Requires manual approval.`
- **Risk**: `High`
- **Workflow**: `WF-DeployEC2-Prod-ManualApprove`

### Verify both entitlements

`getEntitlements` is **POST**, and entitlement_value filtering uses an `entQuery` SQL-like expression:

```bash
curl -s -X POST "$BASE/getEntitlements" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementtype": "Entitlement",
    "entQuery": "ent.entitlement_value like '\''Deploy-EC2-%'\''"
  }' | jq '.'
```

**Expected:** two records, one for each entitlement, each with `requestable` and `status` indicating active and requestable.

For a single-entitlement check:

```bash
curl -s -X POST "$BASE/getEntitlements" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementtype": "Entitlement",
    "entQuery": "ent.entitlement_value = '\''Deploy-EC2-Prod'\''"
  }' | jq '.'
```

---

## B.5 Test createRequest End-to-End from API

After both entitlements and workflows exist, validate from curl. **This is the canonical broker call.**

### ⚠️ createRequest payload shape (Amsterdam GA)

The Amsterdam payload is **flat-fielded** with `requesttype: "ADD"`:

```bash
curl -s -X POST "$BASE/createrequest" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requesttype": "ADD",
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "securitysystem": "Pulumi-Pipeline-AWS",
    "entitlement": "Deploy-EC2-Prod",
    "comments": "Pipeline run #42 — manual approval test for prod deploy",
    "requestor": "igaadmin",
    "checksod": "false"
  }' | jq '.'
```

Key fields:
- `requesttype: "ADD"` — string literal, not `"1"`
- `username` — the **beneficiary** (who's getting the entitlement)
- `requestor` — the **submitter** (the broker SA, `igaadmin` for v1)
- `endpoint` + `securitysystem` — both required, both = `Pulumi-Pipeline-AWS`
- `entitlement` — the entitlement value as a plain string, NOT an array
- `comments` — captured as business justification on the request
- `checksod` — `"false"` for this demo; `"true"` if you've configured an SoD ruleset

### Capture the request key from the response

The response will contain a request identifier — note the field name your tenant returns (typical: `requestkey`, `requestid`, or both). The broker uses this for status polling:

```json
{
  "msg": "Success",
  "requestkey": "12345",
  "errorCode": "0"
}
```

Save the `requestkey` value for the polling test below.

### Verify request status (the polling endpoint)

The Amsterdam status endpoint is **`fetchRequestApprovalDetails`** (NOT `checkRequestStatus`). It requires both the `requestKey` (capital K) and the approver's `userName`:

```bash
curl -s -X POST "$BASE/fetchRequestApprovalDetails" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requestKey": "12345",
    "userName": "igaadmin"
  }' | jq '.'
```

**Response shape:** the response includes `ApprovalRequestDetails.AccessRequestDetails[].modifyTasks[].approvalstatus` (and `tasksList[].approvalstatus`). The broker polls and reads `approvalstatus` to decide pipeline next-steps:

| approvalstatus value | Broker action |
|---|---|
| `PENDING` | Continue polling |
| `APPROVED` | Resume pipeline |
| `REJECTED` | Fail pipeline with clear message |

> The exact set of values used by your tenant may include additional states (e.g., `Task Created`, `Approval In Progress`). The broker should treat anything other than `APPROVED` or `REJECTED` as "still pending."

### Test auto-approve path

For the dev path, submit for a user who doesn't already hold the entitlement:

```bash
# Use any test user who doesn't currently hold Deploy-EC2-Dev
curl -s -X POST "$BASE/createrequest" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requesttype": "ADD",
    "username": "some-test-user",
    "endpoint": "Pulumi-Pipeline-AWS",
    "securitysystem": "Pulumi-Pipeline-AWS",
    "entitlement": "Deploy-EC2-Dev",
    "comments": "Auto-approve smoke test",
    "requestor": "igaadmin",
    "checksod": "false"
  }' | jq '.'
```

Within seconds, polling `fetchRequestApprovalDetails` should return `approvalstatus: "APPROVED"` (or equivalent terminal state).

> Don't use `wes-dev` here — Section C assigns Deploy-EC2-Dev to them directly.

---

## B.6 Optional: SoD policy

If you want the approver's view of a prod request to display "SoD check passed" — or block the request entirely if violated — configure an SoD ruleset that flags simultaneous holding of `Deploy-EC2-Dev` + `Deploy-EC2-Prod`.

Then the broker can pass `checksod: "true"` in createRequest, and `fetchRequestApprovalDetails` (with `fetchSod: true`) will surface the result.

**Recommendation: skip for v1 demo, mention as roadmap item.** It's genuinely valuable in the talk track but is non-trivial to configure correctly. Document under `docs/saviynt-sod-setup.md` if pursued later.

---

## Common Gotchas — Section B

| Symptom | Cause | Fix |
|---|---|---|
| Auto-approve workflow doesn't actually auto-approve | Workflow not activated/published | Edit workflow → click Activate or Publish |
| Auto-approve fails when requestor = beneficiary | Saviynt OOB restriction | Always submit via `requestor: "igaadmin"` |
| Entitlement created but not requestable in API | `requestable` field missed during create | Edit entitlement, set Requestable=1, Save |
| `getEntitlements` returns empty when filtered by endpoint | Wrong endpoint or entitlementtype | Verify entitlement's parent endpoint via UI |
| `createrequest` returns 200 with `errorCode != "0"` | Workflow not bound, not activated, or entitlement not requestable | Check workflow active, attached to entitlement, requestable=1 |
| Manual approval workflow exists but approver doesn't see request | Approver field set to wrong user, or notification not configured | Have approver log in and check inbox; fix approver field |
| Prod entitlement workflow auto-approves anyway | Wrong workflow attached | Edit entitlement → Workflow field → confirm `WF-DeployEC2-Prod-ManualApprove`, save |
| `fetchRequestApprovalDetails` returns empty/error | `userName` doesn't match the approver, or `requestKey` is wrong | The `userName` must be the approver username; for v1 always `igaadmin` |
| Workflow editor blank canvas after save | Browser cache | Hard refresh (Ctrl+Shift+R) |
| Workflow won't save / Activate greyed out — If-Else condition rejected | Tenant's Groovy parser doesn't accept literal `true`, OR the `false` branch isn't connected to an End node | Try `1 == 1` / `Boolean.TRUE` / `return true`; connect the false branch. If it still won't save, **abandon the from-scratch path and clone an OOB auto-approval workflow instead** (see B.2 Path A). |
| Approver doesn't see the request even though they're ROLE_ADMIN | Approval task is assigned to a *different* user; ROLE_ADMIN can view but not approve someone else's task on this tenant | Set the Approval block's approver to the user you'll log in as for the demo (`igaadmin` for v1) |

---

## What's next

Move to **03-roles-and-users.md** to create `wes-dev` and assign `Deploy-EC2-Dev` directly so the dev pipeline run skips the request flow.
