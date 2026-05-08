# 02 — Entitlement Types, Workflows, and Entitlements

> ## ⚠️ Architecture Correction — Read This First (post-verification, 2026-05-08)
>
> The original guidance below tries to bind a different workflow to each Entitlement Type's "Add Workflow" field. **This does not work in this Amsterdam GA tenant** for createrequest add operations. Saviynt's runtime resolves the Add Access workflow at the **Security System level**, not the entitlement-type level. The `workflow` field on the entitlement type (with the `enableEntitlementToRoleSync` JSON wrapper) is consulted for role-sync, not for Add Access requests.
>
> **What actually works (verified end-to-end against tenant):**
> 1. **One workflow** at the Security System level (`accessAddWorkflow` field on SS), named e.g. `WF-PulumiPipeline-AddAccess`.
> 2. **Workflow Type = Parallel** (mandatory — Serial workflows can't see the `entitlement` object, so If-Else conditions on entitlement type fail at runtime).
> 3. **If-Else inside the workflow** branches on entitlement type:
>    - Condition (Groovy): `entitlement.entitlementtypekey.entitlementname.equals('EntProd') eq true`
>    - True branch: Custom Assignment (Username = approver, e.g. `wes-approver`) → Grant Access → End. Wire Rejected Access → End and Escalation → End.
>    - False branch: Grant Access → End (auto-approves dev requests).
> 4. **Workflow lifecycle is two-step.** Every edit creates a Composing version. After saving, click **Send For Approval** in the editor, then go to **Admin → Workflow → Workflow Approval** and click Accept. Old versions go Inactive on each new edit; only the latest Active version is what runtime uses.
> 5. **Approval block (Custom Assignment) requires:** Notification Email Template populated, all three outputs (Approved/Rejected/Escalation) wired to End nodes, and the assigned approver to have a SAV Role (ROLE_END_USER or ROLE_ADMIN).
>
> The original "two types, two workflows" content below is preserved for context but should be treated as superseded. Section B.1 (creating the two Entitlement Types) and B.4 (creating the two entitlements) are still correct — only the workflow binding strategy changed.
>
> **Goal (corrected):** Stand up the IGA structure that drives the demo's two outcomes — auto-approve for dev and manual-approve for prod — using **two Entitlement Types** under one endpoint and **one SS-level workflow** that branches on the entitlement type via If-Else. Then create the two entitlements as instances under their corresponding types.

## Prerequisites
- Section A (`01-application-onboarding.md`) completed
- For demo v1, both the broker SA and the prod-approver are `igaadmin`. Section C still creates `wes-dev` as the *beneficiary*. The **approver** in the workflow we're about to build is `igaadmin`.

## Tenant base URL

```
BASE="https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5"
```

---

## Where the workflow actually binds

Important Amsterdam GA finding — there is **no per-entitlement Workflow field**. The workflow that fires when a user requests an entitlement is resolved by walking up this hierarchy:

1. **Entitlement Type → Add Workflow** ← we use this
2. Endpoint → default workflow fields (fallback)
3. Security System → default workflow fields (fallback)

Because (1) is type-wide, two entitlements that need *different* add-workflows must live under *different* Entitlement Types. That's why this doc creates **two types** under the single `Pulumi-Pipeline-AWS` endpoint instead of one.

| Layer | Dev side | Prod side |
|---|---|---|
| Endpoint (one, shared) | `Pulumi-Pipeline-AWS` | same |
| Entitlement Type | `EntDev` (display `Pipeline Access - Dev`) — Add Workflow = `WF-EC2Deploy-Dev-AutoApprove` | `EntProd` (display `Pipeline Access - Prod`) — Add Workflow = `WF-EC2Deploy-Prod-ManualApprove` |
| Entitlement | `EC2Deploy-Dev` | `EC2Deploy-Prod` |

## Build order

Workflow binding on the Entitlement Type is a chicken-and-egg with the workflows themselves, so the build order matters:

1. **B.1** — Create both Entitlement Type *shells* (Add Workflow blank for now).
2. **B.2** — Create / clone the auto-approve workflow.
3. **B.3** — Create / clone the manual-approve workflow.
4. **B.1 (return)** — Edit each Entitlement Type and bind its Add Workflow.
5. **B.4** — Create the two entitlements, each under its corresponding type.
6. **B.5** — End-to-end API smoke test.

---

## B.1 Entitlement Types

Saviynt requires entitlements to belong to an **Entitlement Type**. The type is also where the **Add Workflow** binding lives in Amsterdam — the entitlement itself doesn't have a per-entitlement workflow field.

> **Mental model — two stacked layers, both confusingly called some flavor of "entitlement":**
>
> | Layer | Role |
> |---|---|
> | **Entitlement Type** *(this section)* | Per-endpoint *category*. Carries the **Add Workflow** for any entitlement of this type. Analogous to an AD object class (`Group`), Salesforce `Profile` vs `PermissionSet`, or a database table schema. |
> | **Entitlement** *(B.4 below)* | An *instance* under a type. The actual permission a user requests or holds. |
>
> ⚠️ **Type assignment is final.** When you create individual entitlements in B.4, the type dropdown on the create form is the only place this association is made. You cannot reassign the type later, and most tenants won't let you delete an entitlement that has any history — so a wrong type pick at create time means recreating with a fresh entitlement value.

### Click-by-click

Repeat steps 1–5 **twice** — once for `EntDev`, once for `EntProd`.

1. Log in as `igaadmin`.
2. Navigate to **Admin** → **Identity Repository** → **Entitlement Types**.
   - **VERIFY (Amsterdam UI)**: alternate path is editing the endpoint directly and using its **Entitlement Types** sub-tab.
3. Click **Actions** → **Create Entitlement Type**.
4. Fill in (one row per type):

   | Field | EntDev value | EntProd value |
   |---|---|---|
   | **Entitlement Type** *(technical name)* | `EntDev` | `EntProd` |
   | **Endpoint** | `Pulumi-Pipeline-AWS` | `Pulumi-Pipeline-AWS` |
   | **Display Name** | `Pipeline Access - Dev` | `Pipeline Access - Prod` |
   | **Description** | `Pipeline deployment — dev (auto-approved)` | `Pipeline deployment — prod (manual approval)` |
   | **Add Workflow** | leave blank for now (bind after B.2) | leave blank for now (bind after B.3) |
   | **Request Option** | Requestable / Yes | Requestable / Yes |

5. **Save**.

### Bind workflows (return here after B.2 and B.3)

Once both workflows exist:

1. Open the **EntDev** type → **Add Workflow** → select `WF-EC2Deploy-Dev-AutoApprove` → **Save**.
2. Open the **EntProd** type → **Add Workflow** → select `WF-EC2Deploy-Prod-ManualApprove` → **Save**.

### Verify both Entitlement Types

`getEntitlementTypes` is a **GET** endpoint with query parameters.

```bash
curl -s -G "$BASE/getEntitlementTypes" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "endpointname=Pulumi-Pipeline-AWS" \
  --data-urlencode "max=10" \
  | jq '.'
```

**Expected:** two records — `entitlementType: "EntDev"` and `entitlementType: "EntProd"` — both on `endpoint: "Pulumi-Pipeline-AWS"`.

If you used different technical names, override `ENTITLEMENT_TYPE_DEV` / `ENTITLEMENT_TYPE_PROD` in `broker/.env`.

---

## B.2 Approval Workflow #1 — Auto-Approve (will bind to EntDev)

This workflow auto-approves any request without human intervention.

> **Recommended path: clone an OOB auto-approval workflow.** Saviynt ships an auto-approve workflow stock (`AutoApproveWorkflow` / `AutoApprove` / `SimpleAutoApproval` depending on build). Cloning it skips the workflow editor's expression-language minefield entirely. The from-scratch If-Else build is documented further down as a fallback.

### Path A — Clone an OOB auto-approval (recommended)

1. **Admin** → **Workflows**. Find the stock auto-approve workflow. Likely names: `AutoApproveWorkflow`, `AutoApprove`, or `SimpleAutoApproval`.
2. **Verify before cloning** — open it and confirm:
   - **Status**: Active / Published.
   - The flow actually auto-approves end-to-end (some OOB "Auto*" workflows auto-*route*, not auto-*approve* — don't trust the name; trace the canvas).
   - The internal *category* matches access-add (API name `AccessAddWorkflow`). Amsterdam UIs may not expose this directly; if the OOB workflow appears in another Entitlement Type's Add Workflow dropdown anywhere in the tenant, that confirms the category is right. If you can't tell, clone it anyway and check that your clone shows up in the EntDev Add Workflow dropdown when you bind it (return to B.1).
3. Use the **Clone** / **Copy** action (right-click or Actions menu).
4. On the clone, set:
   - **Name**: `WF-EC2Deploy-Dev-AutoApprove`
   - **Description**: `Auto-approve workflow for EntDev type (cloned from <OOB name>)`
   - **Workflow Type** (execution model): `Parallel` or `Serial`. With auto-approve / no human step both behave identically — pick `Parallel`. The clone inherits the OOB original's *category* (`AccessAddWorkflow` in API terms), which is what makes it eligible to be bound to an Entitlement Type.
5. **Save**.
6. **Activate** / **Publish** the clone. ⚠️ critical — without activation, the workflow exists but won't fire when bound, and may not even appear in EntDev's Add Workflow dropdown.
7. **Bind to EntDev** — return to **B.1** → edit the `EntDev` type → set **Add Workflow** = `WF-EC2Deploy-Dev-AutoApprove` → **Save**.

**Don't edit the OOB original in place.** It's often wired into other tenant defaults (the global access-request page, etc.); modifying it has side effects.

### Path B — Build from scratch (fallback)

Use this only if no suitable OOB workflow exists, or cloning isn't permitted on your tenant.

1. Navigate to **Admin** → **Workflows**.
2. **Actions** → **Create Workflow**.
3. Fill in:
   - **Name**: `WF-EC2Deploy-Dev-AutoApprove`
   - **Workflow Type** (execution model): `Parallel`.
   - **Description**: `Auto-approve workflow for EntDev type`
   - If your form exposes a **Workflow Category** (or **Used For** / **Module** / **Object Type**), set it to the access-add option (API name `AccessAddWorkflow`). If no such field is visible, the category is auto-set or hidden in your build — that's fine.
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

6. **Save** and **Activate** / **Publish**.
7. **Bind to EntDev** as in Path A step 7.

### ⚠️ Gotcha: requestor = beneficiary auto-approve restriction

Saviynt OOB rule (verified): **"When the requestor, beneficiary and the approver is the same, the system doesn't allow the request to auto approve."**

For our demo this is **not a problem** because:
- Requestor: `igaadmin` (the broker SA)
- Beneficiary: `wes-dev`
- Approver: auto-approve / `igaadmin`

These are different user identities (or auto-approve, which doesn't count as a person) so the restriction doesn't fire. If you ever test by submitting a request manually as `wes-dev` for `wes-dev`, the auto-approve will silently fail.

---

## B.3 Approval Workflow #2 — Manual Approve (will bind to EntProd)

For demo v1, the approver is `igaadmin` (ROLE_ADMIN). This is a deliberate simplification — in production you'd separate request submission and approval into distinct identities.

> **Recommended path: clone an OOB single-step approval workflow** and change the approver to `igaadmin`. Same reasoning as B.2 — skip the editor where you can.

### ⚠️ Why the approver field actually matters (don't skip it)

When a request hits an Approval block, Saviynt creates an approval task **assigned to the named user**. The task lands in **that user's** approval inbox. ROLE_ADMIN can usually *view* any pending approval via admin pages, but whether ROLE_ADMIN can *approve* a task assigned to a different user depends on tenant config — some tenants enforce strict assignment.

**Demo-safe rule:** the Approval block's approver must be the same user you'll log in as during the demo (`igaadmin` for v1). Then the task lands in that user's inbox and "approve" is one click — no admin override or task reassignment needed.

### Path A — Clone an OOB single-approval workflow (recommended)

1. **Admin** → **Workflows**. Find a stock single-step approval workflow. Likely names: `SingleApproval`, `OneStepApproval`, `ManagerApproval` (the last one routes to the requestor's manager — fine to clone, just change the approver field).
2. Verify on the OOB original:
   - **Status**: Active / Published
   - Single Approval block, single End — no extra escalation/notification logic that'd surprise the demo.
   - Same category caveat as B.2 Path A: if the OOB workflow appears in any Entitlement Type's Add Workflow dropdown today, its access-add category is correct.
3. **Clone** the workflow.
4. On the clone, set:
   - **Name**: `WF-EC2Deploy-Prod-ManualApprove`
   - **Description**: `Manual approval for prod deploys (igaadmin approves in v1, cloned from <OOB name>)`
   - **Workflow Type** (execution model): `Serial` (with a single approver it's identical to Parallel; Serial is the safer default if you ever add a second approver).
5. Open the Approval block and set:
   - **Approver Type**: `User`
   - **Approver**: `igaadmin`  ← critical, see warning above
   - **Rank**: `1`
   - **Escalation**: leave blank
   - **Approval Comments Required**: ON for richer demo audit
6. **Save** and **Activate**.
7. **Bind to EntProd** — return to **B.1** → edit the `EntProd` type → set **Add Workflow** = `WF-EC2Deploy-Prod-ManualApprove` → **Save**.

### Path B — Build from scratch (fallback)

1. **Admin** → **Workflows** → **Actions** → **Create Workflow**.
2. Fill in:
   - **Name**: `WF-EC2Deploy-Prod-ManualApprove`
   - **Workflow Type** (execution model): `Serial`.
   - **Description**: `Manual approval for prod deploys (igaadmin approves in v1)`
   - **Workflow Category** / **Used For** (if exposed): access-add (API name `AccessAddWorkflow`). If no such field appears on the form, skip — it's hidden or auto-set in your build.
3. **Save**, enter editor.
4. Build the flow:
   - **Start** node
   - **Approval** block (single)
   - **End** node
5. Configure the Approval block (same fields as Path A step 5).
6. **Save** and **Activate**.
7. **Bind to EntProd** as in Path A step 7.

### ⚠️ Demo-narrative note

When demoing, you'll log in as `igaadmin` to approve. That's fine functionally, but for the talk track you may want to preface with: *"In production this approver would be a separate identity — likely an application owner or a senior engineer with the prod entitlement. For demo simplicity, our admin approves."*

This keeps the demo honest. Section C documents an optional `wes-approver` user if you'd rather demonstrate the cleaner separated-duties variant later.

---

## B.4 Create the Two Entitlements

Each entitlement goes under its corresponding type. The workflow is inherited from the type's **Add Workflow** field — there is **no Workflow field on the entitlement create form** in Amsterdam (this is the trap that bit us once already).

The Amsterdam entitlement form is also a **two-pass** flow: the Create screen exposes a minimal subset (Value, Type, Endpoint, Description). The rest (Requestable, Risk, Status, etc.) only appear on **Edit** after the entitlement exists. Don't expect to set everything in one shot.

### EC2Deploy-Dev (under EntDev)

**Pass 1 — Create:**

1. **Admin** → **Identity Repository** → **Entitlements**.
2. **Actions** → **Create Entitlement**.
3. Fill in:
   - **Entitlement Value**: `EC2Deploy-Dev`
   - **Display Name**: `Deploy to EC2 Dev Environment`
   - **Endpoint**: `Pulumi-Pipeline-AWS`
   - **Entitlement Type**: `EntDev`  ⚠️ pick the right type — the type assignment is final
   - **Description**: `Permission to run the pipeline against the dev environment. Auto-approved.`
4. **Save**.

**Pass 2 — Edit and finish the rest:**

5. Reopen the entitlement in **Edit**.
6. Set:
   - **Status**: `1` (active)
   - **Requestable**: `1` (yes) ⚠️ must be set or createrequest will fail with "not requestable"
   - **Risk**: `Low`
   - **Access**: `Select`
7. **Save** again.

### EC2Deploy-Prod (under EntProd)

Same procedure with:
- **Entitlement Value**: `EC2Deploy-Prod`
- **Display Name**: `Deploy to EC2 Prod Environment`
- **Entitlement Type**: `EntProd`
- **Description**: `Permission to run the pipeline against prod. Manual approval required.`
- (On Edit pass 2) **Risk**: `High`, **Requestable**: `1`

### Verify both entitlements

`getEntitlements` is **POST**, and entitlement_value filtering uses an `entQuery` SQL-like expression. Note the per-type query for completeness:

```bash
# Dev type
curl -s -X POST "$BASE/getEntitlements" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementtype": "EntDev",
    "entQuery": "ent.entitlement_value = '\''EC2Deploy-Dev'\''"
  }' | jq '.'

# Prod type
curl -s -X POST "$BASE/getEntitlements" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementtype": "EntProd",
    "entQuery": "ent.entitlement_value = '\''EC2Deploy-Prod'\''"
  }' | jq '.'
```

**Expected:** one record per call, with `requestable` and `status` indicating active and requestable.

---

## B.5 Test createRequest End-to-End from API

After both entitlements and workflows exist (and the workflows are bound to their types), validate from curl. **This is the canonical broker call.**

> Note: createrequest does **not** include `entitlementType` in the payload — Saviynt resolves the type by entitlement_value lookup. Type only matters on the read side (`getEntDetailsforUsers`, `getEntitlements`).

### ⚠️ createRequest payload shape (Amsterdam GA — VERIFIED)

The Amsterdam payload uses an **array of entitlement objects**, NOT a flat string. Earlier drafts of this doc were wrong on this — corrected below.

```bash
curl -s -X POST "$BASE/createrequest" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requesttype": "ADD",
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "securitysystem": "Pulumi-Pipeline-AWS",
    "accountname": "wes-dev",
    "comments": "Pipeline run #42 — manual approval test for prod deploy",
    "requestor": "wes-dev",
    "createaccountifnotexists": "false",
    "checksod": "false",
    "entitlement": [
      {
        "entitlementtype": "EntProd",
        "entitlementvalue": "EC2Deploy-Prod",
        "businessjustification": "Pipeline run #42 — prod deploy"
      }
    ]
  }' | jq '.'
```

Key fields:
- `requesttype: "ADD"` — string literal, not `"1"`
- `username` — the **beneficiary** (who's getting the entitlement)
- `requestor` — the **submitter**. ⚠️ **MUST equal `username` (beneficiary)** for manual approval workflows to fire. If `requestor != beneficiary` and the type is entitlement (not org/SA/role), Saviynt auto-approves silently and bypasses the workflow's approval block. The broker must pass the beneficiary's username here, not the SA name.
- `endpoint` + `securitysystem` — both required, both = `Pulumi-Pipeline-AWS`
- `accountname` — required at top level; the user's account on the endpoint (not the entitlement)
- `createaccountifnotexists` — `"false"` if account exists; `"true"` to auto-create as a fallback
- `entitlement` — **array of objects**, each with `entitlementtype` and `entitlementvalue` (one word, lowercase). Optional per-entitlement: `businessjustification`, `startdate`, `enddate`
- `comments` — captured as business justification on the parent request
- `checksod` — `"false"` for this demo; `"true"` if you've configured an SoD ruleset

### Capture the request key from the response

```json
{
  "msg": "Success",
  "requestkey": "12345",
  "errorCode": "0"
}
```

Save the `requestkey` value for the polling test below.

### Verify request status (the polling endpoint)

The Amsterdam status endpoint is **`fetchRequestApprovalDetails`**. It requires both the `requestKey` (capital K) and the approver's `userName`:

```bash
curl -s -X POST "$BASE/fetchRequestApprovalDetails" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requestKey": "12345",
    "userName": "igaadmin"
  }' | jq '.'
```

**Response shape:** the response includes `ApprovalRequestDetails.AccessRequestDetails[].modifyTasks[].approvalstatus` (and `tasksList[].approvalstatus`). Broker action by status:

| approvalstatus value | Broker action |
|---|---|
| `PENDING` | Continue polling |
| `APPROVED` | Resume pipeline |
| `REJECTED` | Fail pipeline with clear message |

> The exact set of values used by your tenant may include additional states (e.g., `Task Created`, `Approval In Progress`). The broker should treat anything other than `APPROVED` or `REJECTED` as "still pending."

### Test auto-approve path

For the dev path, submit for a user who doesn't already hold the entitlement:

```bash
# Use any test user who doesn't currently hold EC2Deploy-Dev
curl -s -X POST "$BASE/createrequest" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requesttype": "ADD",
    "username": "some-test-user",
    "endpoint": "Pulumi-Pipeline-AWS",
    "securitysystem": "Pulumi-Pipeline-AWS",
    "entitlement": "EC2Deploy-Dev",
    "comments": "Auto-approve smoke test",
    "requestor": "igaadmin",
    "checksod": "false"
  }' | jq '.'
```

Within seconds, polling `fetchRequestApprovalDetails` should return `approvalstatus: "APPROVED"` (or equivalent terminal state).

> Don't use `wes-dev` here — Section C assigns EC2Deploy-Dev to them directly.

---

## B.6 Optional: SoD policy

If you want the approver's view of a prod request to display "SoD check passed" — or block the request entirely if violated — configure an SoD ruleset that flags simultaneous holding of `EC2Deploy-Dev` + `EC2Deploy-Prod`.

Then the broker can pass `checksod: "true"` in createRequest, and `fetchRequestApprovalDetails` (with `fetchSod: true`) will surface the result.

**Recommendation: skip for v1 demo, mention as roadmap item.** It's genuinely valuable in the talk track but is non-trivial to configure correctly. Document under `docs/saviynt-sod-setup.md` if pursued later.

---

## Common Gotchas — Section B (verified against tenant)

| Symptom | Cause | Fix |
|---|---|---|
| **All entitlement add requests auto-approve regardless of type-level workflow** | SS-level `accessAddWorkflow` overrides type-level bindings. Or type-level bindings simply don't fire for Add Access requests in this tenant. | Use one SS-level workflow with If-Else on entitlement type — see the Architecture Correction at the top of this file. |
| **Request is auto-discontinued (Comments contain "Request discontinued" + literal `null`)** | Workflow runtime null-pointered. Common causes: (1) `requestor != beneficiary` for entitlement requests triggers a silent admin-on-behalf auto-approve path that fails to assign, (2) workflow Type is Serial not Parallel, (3) approval block Escalation output not wired, (4) Notification Email Template empty, (5) approver user has no SAV Role | Set `requestor: <beneficiary username>` in createrequest. Switch workflow Type to Parallel. Wire Escalation→End. Populate Notification Email Template. Assign ROLE_END_USER to the approver. |
| **Workflow shows Active but new edits don't take effect** | Forgot the two-step lifecycle: Send For Approval → Accept in Workflow Approval. Each edit creates a Composing version; previous Active version goes Inactive. | After every edit, click Send For Approval → go to Admin → Workflow → Workflow Approval → click Accept. Verify status becomes Active in Workflow List. |
| Entitlement Type's **Add Workflow** field has no effect | This is by design in Amsterdam GA — the field exists but isn't consulted for Add Access requests. The SS-level `accessAddWorkflow` is what fires. | Don't rely on type-level bindings. Use SS-level workflow with If-Else. |
| Auto-approve workflow doesn't actually auto-approve | Workflow not Active (still in Composing or Pending Approval), or workflow Type is Serial when an entitlement-object If-Else is used | Verify Active status; switch to Parallel |
| Entitlement created but not visible in request UI | User has no account on the endpoint — Saviynt UI hides entitlements for endpoints where the user has no account record | Create a stub account via API or UI: `accountname=<username>`, owner=`<username>`, status=Active, then verify via `getAccounts` that `userKey`/`username` populate (account is mapped) |
| `getEntitlements` returns empty when filtered by endpoint | Wrong endpoint or wrong `entitlementtype`. We have two — `EntDev` and `EntProd`. | Pick the right type per query, OR drop the filter and inspect what's returned |
| `createrequest` returns 1 with "No Workflow Associated for Add Request" | No `accessAddWorkflow` set on the SS, AND the type-level field isn't being honored either | Set the SS-level Access Add Workflow. The type-level field is essentially decorative for entitlement add. |
| `fetchRequestApprovalDetails` returns 500 / generic HTML error | Likely missing or misnamed required field in body | `userName` is camelCase. Field must be present and non-empty; setting it to a non-existent user causes server crash |
| Workflow won't save / Activate — If-Else condition rejected | Groovy parser quirks | Try simpler form: `entitlement.entitlementtypekey.entitlementname == 'EntProd'` instead of `.equals('EntProd') eq true` |
| Approver doesn't see the request even with ROLE_ADMIN | Approval task assigned to wes-approver but workflow couldn't resolve them due to missing SAV role at the time of assignment | Verify `getUser` shows the SAV role; if not, assign in UI and retry |

---

## What's next

Move to **03-roles-and-users.md** to create `wes-dev` and assign `EC2Deploy-Dev` directly so the dev pipeline run skips the request flow.
