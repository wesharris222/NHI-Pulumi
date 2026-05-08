# 03 — Users + Direct Entitlement Assignment

> ## ⚠️ Verification Notes (2026-05-08, post-tenant testing) — Read These First
>
> 1. **`wes-approver` is now MANDATORY, not optional.** The original C.2 marked it optional with the plan to use `igaadmin` as both broker SA and approver. That doesn't work — when `requestor == approver`, Saviynt's auto-approve trap fires for entitlement requests where beneficiary differs, and the workflow's approval block silently never runs. Create `wes-approver` and use them as the workflow approver.
> 2. **`requestor` MUST equal `username` (beneficiary) in createrequest** for manual approval to fire. The broker passes `requestor: <pipeline-user>` (e.g., `wes-dev`), not the SA name. Authentication still happens with the SA's bearer token; the `requestor` field is just metadata about whose behalf the request represents.
> 3. **`getUserRequestableEntitlements` does NOT exist** in this tenant's API collection. Diagnostics use `getEntitlements` + `getAccounts` + `getEntDetailsforUsers` instead.
> 4. **A stub account on the endpoint** is required for the user to see entitlements in the Saviynt request catalog UI. The account must be mapped to the user (non-empty `userKey`/`username` after creation). For our governance-only endpoint, this is purely an internal Saviynt record — no real downstream system.
> 5. **The createrequest `entitlement` field is an array of objects**, not a flat string. See updated C.4 Path B below.
> 6. **Provisioning tasks for disconnected endpoints don't auto-complete on approval.** Even with `instantprovision: true` on the SS, you'll need to either (a) have the broker call `updateTasks` to close the task, (b) try `automatedProvisioning: true` on the SS, or (c) manually mark complete in Admin → Tasks. Plan: option (a) for the broker design.
>
> **Goal:** Create `wes-dev` (beneficiary), `wes-approver` (manual-approval approver), and stub accounts on the Pulumi-Pipeline-AWS endpoint. Then directly assign `EC2Deploy-Dev` to `wes-dev` so the dev-environment pipeline run finds the entitlement on `/preflight` immediately and skips the request flow entirely. Leave `EC2Deploy-Prod` *un*assigned so the prod path triggers the manual-approval workflow.

## Prerequisites
- Section A complete (endpoint exists)
- Section B complete (entitlements exist; prod workflow has `igaadmin` as approver)

## Tenant base URL

```
BASE="https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5"
```

---

## C.1 Create wes-dev

### Click-by-click

1. Log in as `igaadmin`.
2. Navigate to **Admin** → **Identity Repository** → **Users**.
3. **Actions** → **Create User**.
4. Fill in:
   - **Username**: `wes-dev`
   - **First Name**: `Wes`
   - **Last Name**: `Developer`
   - **Email**: `wes-dev@homelab.local` (any valid format; doesn't need to actually receive)
   - **Display Name**: `Wes Dev (Demo Developer)`
   - **Password**: temporary; mark **Force Password Change on First Login** OFF
   - **User Type**: `Internal` or `Employee`
   - **Status**: `Active` (`statuskey: 1`)
   - **Manager**: `igaadmin` (some Saviynt tenants have OOB workflows that route to manager — having an active manager set avoids "no manager found" errors)
   - **SAV Role**: leave blank — `wes-dev` is a normal end user with no admin privileges
   - **Customproperties**: leave blank unless your tenant has required ones
5. **Save**.

### Common save error

> "User cannot be saved: missing required attribute X"

Saviynt tenants often have org-specific required user attributes (department, location, employeetype). Add any required field with a placeholder value (`Demo`, `IT`) and re-save.

---

## C.2 Create wes-approver (MANDATORY)

⚠️ **No longer optional.** Saviynt's runtime auto-approves entitlement requests when `requestor == approver` even with a workflow approval block in the canvas — so the approver in the workflow must be a different identity from the broker's SA (`igaadmin`). Without `wes-approver`, the prod-path manual-approval gate doesn't fire and the demo's governance proof point is lost.

Same click-by-click as C.1 with these values:
- **Username**: `wes-approver`
- **First Name**: `Wes`
- **Last Name**: `Approver`
- **Email**: `wes-approver@homelab.local` (or any valid format)
- **Display Name**: `Wes Approver (Demo Senior Engineer)`
- **User Type**: `Internal`
- **Status**: `Active`
- **Manager**: `igaadmin`
- **SAV Role**: `ROLE_ADMIN` (verified working). `ROLE_END_USER` should also work but wasn't tested in this iteration.

⚠️ **`getUser` doesn't return SAV role assignments in its response payload** — verify in the UI by reopening the user record and checking the SAV Role section.

The Custom Assignment block in `WF-PulumiPipeline-AddAccess` will reference this user by username when routing the prod-path approval.

---

## C.3 Verify wes-dev exists

`getUser` is **POST**, and username goes inside `filtercriteria`:

```bash
TOKEN=$(curl -s -X POST "https://eic-poc-wesharris.saviyntcloud.com/ECM/api/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"igaadmin","password":"YOUR_ADMIN_PASSWORD"}' \
  | jq -r '.access_token')

curl -s -X POST "$BASE/getUser" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "filtercriteria": {"username": "wes-dev"}
  }' | jq '.'
```

**Expected:** the response includes `wes-dev` with `statuskey: "1"` (active) and the basic attributes (firstname, lastname, email).

---

## C.4 Direct Assignment of EC2Deploy-Dev to wes-dev

### Prerequisite: stub account on the endpoint (REQUIRED)

⚠️ **`wes-dev` must have an account on `Pulumi-Pipeline-AWS` before any entitlement assignment.** Saviynt grants entitlements to user-account pairs — without an account, the entitlement assignment has nothing to bind to. Also: the user can't see entitlements in the Saviynt request UI until they have an account on the endpoint.

UI path:
1. Admin → Identity Repository → **Accounts** → **Create Account**.
2. Fields:
   - **Account Name**: `wes-dev`
   - **Display Name**: `wes-dev`
   - **Endpoint**: `Pulumi-Pipeline-AWS`
   - **Status**: Active
   - **Owner / User Mapping**: link to user `wes-dev` (some Amsterdam UIs require a separate "Map to User" action after account creation)
3. Save.

Verify the account is correctly mapped:

```bash
curl -s -X POST "$BASE/getAccounts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "advsearchcriteria": {
      "endpoint": "Pulumi-Pipeline-AWS",
      "name": "wes-dev"
    }
  }' | jq '.'
```

The response must show `username: "wes-dev"` and a non-empty `userKey`. If those are blank, the account exists but isn't mapped — fix in UI before proceeding.

### Click-by-click — Path A (UI direct assignment) — may not be available

1. Edit the `wes-dev` user.
2. Find the **Entitlements** tab (in some Amsterdam UIs: **Access** or **User Access**).
3. **Actions** → **Add Entitlement** (or **Assign Entitlement**).
4. In the picker:
   - **Endpoint**: `Pulumi-Pipeline-AWS`
   - **Entitlement Type**: `EntDev`
   - **Entitlement Value**: select `EC2Deploy-Dev`
5. Save.

⚠️ **Many Amsterdam tenants don't expose an Entitlements tab on the user record at all** — direct admin assignment isn't available. In that case use Path B.

### Click-by-click — Path B (admin-mediated request, auto-approves via SS workflow's False branch) — VERIFIED

Submit an access request as `igaadmin` for `wes-dev` for `EC2Deploy-Dev`. The SS-level workflow's If-Else False branch (Grant Access) handles it instantly because EntDev doesn't match the EntProd condition.

⚠️ Note that for *baseline assignment* it's OK to use `requestor: igaadmin` because EntDev hits the auto-approve branch — the requestor=approver auto-approve trap doesn't matter when there's no human approval step. For the prod-path *demo* run (where manual approval matters), `requestor` must equal the beneficiary.

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
    "comments": "Baseline assignment for demo - Wes Dev needs dev environment access",
    "requestor": "igaadmin",
    "createaccountifnotexists": "false",
    "checksod": "false",
    "entitlement": [
      {
        "entitlementtype": "EntDev",
        "entitlementvalue": "EC2Deploy-Dev",
        "businessjustification": "Baseline dev access for demo developer"
      }
    ]
  }' | jq '.'
```

The auto-approve branch fires and the entitlement *request* is approved within seconds. **However**, the *provisioning task* will be created in Open state and won't complete automatically (disconnected endpoint). Either:

- Manually complete: Admin → Tasks → find the task → Complete
- Plan: have the broker call `updateTasks` to close the task after it sees APPROVED status

Verify via C.5.

---

## C.5 Verify EC2Deploy-Dev is on wes-dev

This is **THE** check the broker's `/preflight` endpoint relies on. Get this right.

### Use `getEntDetailsforUsers` (the broker's preflight call)

`getEntDetailsforUsers` is **GET**, but accepts a JSON body in the request (Saviynt convention). The Amsterdam docs show this endpoint returns a flat `accessDetails[]` array, which is exactly what the broker needs:

```bash
curl -s -X GET "$BASE/getEntDetailsforUsers" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementType": "EntDev",
    "entitlement_value": "EC2Deploy-Dev"
  }' | jq '.'
```

**Expected response:**

```json
{
  "msg": "Successful",
  "displayCount": 1,
  "accessDetails": [
    {
      "username": "wes-dev",
      "endpointname": "Pulumi-Pipeline-AWS",
      "entitlementType": "EntDev",
      "entitlement_value": "EC2Deploy-Dev",
      "entstatus": 1,
      ...
    }
  ],
  "errorCode": "0",
  "totalCount": 1
}
```

### Broker preflight logic

The broker's `/preflight` evaluates the response simply:

```python
# Pseudocode
response = call_get_ent_details_for_users(
    username=requesting_user,
    endpoint=APP_NAME,
    entitlementType=ENTITLEMENT_TYPE_DEV if target_env == "dev" else ENTITLEMENT_TYPE_PROD,
    entitlement_value=ent_value,
)
if response.get("errorCode") == "0" and len(response.get("accessDetails", [])) > 0:
    return {"status": "approved"}
else:
    # User does not hold entitlement → submit createRequest
    request_key = call_create_request(...)
    return {"status": "pending", "request_key": request_key}
```

### Diagnostic chain (replaces deprecated `getUserRequestableEntitlements`)

`getUserRequestableEntitlements` does NOT exist in this tenant's API collection. To diagnose "is this entitlement properly configured and visible to this user," use these three calls in sequence:

**1. Catalog check — does the entitlement exist with the right type/endpoint/status?**

```bash
curl -s -X POST "$BASE/getEntitlements" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementtype": "EntDev"
  }' | jq '.'
```

Look for `entitlement_value: "EC2Deploy-Dev"`, `status: "1"`, `entitlementTypeName: "EntDev"`.

**2. Account-mapping check — does the user have a mapped account on the endpoint?**

```bash
curl -s -X POST "$BASE/getAccounts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "advsearchcriteria": {
      "endpoint": "Pulumi-Pipeline-AWS",
      "name": "wes-dev"
    }
  }' | jq '.'
```

Must return one record with `username: "wes-dev"` and non-empty `userKey`. Empty result or missing `userKey` = fix the account mapping before continuing.

**3. Held entitlements — does the user actually hold this specific entitlement?** (This is what the broker's `/preflight` calls.) See section C.5 above.

If catalog + account mapping are both healthy and the user *should* hold the entitlement but `getEntDetailsforUsers` returns empty, the cause is almost always an open provisioning task that needs manual completion — see "Disconnected endpoint provisioning" note in section C.4.

---

## C.6 Confirm wes-dev does NOT hold EC2Deploy-Prod

The prod entitlement should NOT be on wes-dev (this is what makes the demo's prod path interesting):

```bash
curl -s -X GET "$BASE/getEntDetailsforUsers" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementType": "EntProd",
    "entitlement_value": "EC2Deploy-Prod"
  }' | jq '.'
```

**Expected:** `accessDetails: []` (empty) and `displayCount: 0`. Broker maps this to "user does not hold the entitlement → submit request."

---

## C.7 End-to-end demo dry run

After Sections A, B, and C, you should be able to validate both demo paths from curl alone:

### Dry run: dev path (returns "approved" immediately)

The broker's `/preflight` for the dev pipeline run executes:

```bash
curl -s -X GET "$BASE/getEntDetailsforUsers" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementType": "EntDev",
    "entitlement_value": "EC2Deploy-Dev"
  }' | jq '.accessDetails | length'
```

**Expected:** `1` (or higher). Non-zero means the broker returns `{"status": "approved"}`.

### Dry run: prod path (returns "pending" → approval → "approved")

Step 1 — preflight check (returns 0):

```bash
curl -s -X GET "$BASE/getEntDetailsforUsers" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementType": "EntProd",
    "entitlement_value": "EC2Deploy-Prod"
  }' | jq '.accessDetails | length'
```

Step 2 — broker submits createRequest:

⚠️ **Note `requestor: "wes-dev"` (the beneficiary) is critical** for the prod path. If you submit with `requestor: "igaadmin"`, Saviynt's auto-approve trap fires and the workflow's approval block silently never runs — you'll see APPROVED immediately with `assignee: []`, no manual approval, no demo.

```bash
REQ_RESPONSE=$(curl -s -X POST "$BASE/createrequest" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requesttype": "ADD",
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "securitysystem": "Pulumi-Pipeline-AWS",
    "accountname": "wes-dev",
    "comments": "Pipeline run #demo — prod deploy",
    "requestor": "wes-dev",
    "createaccountifnotexists": "false",
    "checksod": "false",
    "entitlement": [
      {
        "entitlementtype": "EntProd",
        "entitlementvalue": "EC2Deploy-Prod",
        "businessjustification": "Prod deploy approval gate"
      }
    ]
  }')
echo "$REQ_RESPONSE" | jq '.'

REQ_KEY=$(echo "$REQ_RESPONSE" | jq -r '.requestkey // empty')
echo "Request key: $REQ_KEY"
```

The response also includes a top-level `RequestId` — that's the parent ARS_Request ID; `requestkey` is the per-entitlement request key the broker uses for polling.

Step 3 — view pending requests as approver (igaadmin):

`getPendingRequests` is **POST** and requires the `SAVUSERNAME` header set to the approver's username:

```bash
curl -s -X POST "$BASE/getPendingRequests" \
  -H "Authorization: Bearer $TOKEN" \
  -H "SAVUSERNAME: igaadmin" \
  -H "Content-Type: application/json" \
  -d '{"max": "10"}' | jq '.'
```

**Expected:** the request you just submitted appears in the list.

Step 4 — broker polls status (should be PENDING with wes-approver as assignee):

```bash
curl -s -X POST "$BASE/fetchRequestApprovalDetails" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"requestKey\": \"$REQ_KEY\",
    \"userName\": \"wes-approver\"
  }" | jq '.ApprovalRequestDetails.AccessRequestDetails[0].modifyTasks[0]'
```

**Expected (verified):**
```json
{
  "approvalstatus": "NEW",
  "requestaccessStatus": "Pending Approval",
  "approvaltype": "Prod-Manual-Approval",
  "assignee": [["Wes Approver (wes-approver)"]]
}
```

⚠️ `userName` in this body is the workflow's approver, not the requestor. For our prod workflow that's `wes-approver`.

Step 5 — log into Saviynt UI **as `wes-approver`** (not igaadmin), find the request in the approval inbox, click Approve.

Step 6 — broker polls again (now approved):

```bash
# Same fetchRequestApprovalDetails call
# Expected: "APPROVED"
```

Step 7 — preflight re-check now finds the entitlement:

```bash
curl -s -X GET "$BASE/getEntDetailsforUsers" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementType": "EntProd",
    "entitlement_value": "EC2Deploy-Prod"
  }' | jq '.accessDetails | length'
```

**Expected:** `1`. Broker resumes pipeline.

### Resetting between demo runs

To replay the prod demo, you need to revoke `EC2Deploy-Prod` from `wes-dev` between runs. Two options:

**Option A** — UI: edit wes-dev → Entitlements tab → remove EC2Deploy-Prod.

**Option B** — `cancelPendingRequest` (only works on pending requests, not on already-granted entitlements):

```bash
curl -s -X POST "$BASE/cancelPendingRequest" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requestor": "igaadmin",
    "requestkey": "12345",
    "comments": "Resetting demo state"
  }' | jq '.'
```

For granted entitlements you'd use a `removeAccess` API or the UI; this isn't critical for v1 demo.

---

## Common Gotchas — Section C (verified against tenant)

| Symptom | Cause | Fix |
|---|---|---|
| **Prod request auto-approves immediately, no PENDING state** | `requestor` ≠ beneficiary in the createrequest payload (the admin-on-behalf trap) | Set `requestor: "wes-dev"` (or whatever the pipeline user is) — must match `username` |
| **Request immediately discontinued with `null` in Comments** | Workflow runtime null-pointered. Common: workflow Type=Serial when If-Else uses entitlement object; Escalation output unwired; approver lacks SAV role | Switch workflow to Parallel; wire Escalation→End; assign ROLE_END_USER (or ROLE_ADMIN) to approver |
| **Workflow status shows Active in editor but new edits don't apply** | Each edit creates a Composing version; old version goes Inactive; new version needs Send For Approval → Accept | After every edit: Send For Approval → Admin → Workflow → Workflow Approval → Accept |
| **"No Workflow Associated for Add Request"** | SS-level `accessAddWorkflow` field is empty or points at a workflow that's no longer Active | Set Security System's Access Add Workflow to a known-Active workflow |
| Cannot create user: "Manager is required" | Tenant requires manager | Set Manager to `igaadmin` |
| Cannot create user: "Department/Location required" | Tenant has required custom user attributes | Set placeholder values |
| User created but `getUser` returns nothing | User in inactive state | Edit user, set Status to Active |
| `getUser` doesn't return SAV role assignments | API quirk in this tenant | Verify SAV role in the UI by reopening the user record |
| **Entitlement not visible in Saviynt request UI catalog** | User has no account on the endpoint | Create a stub account, verify it's mapped (`getAccounts` shows non-empty `userKey`/`username`) |
| **getAccounts returns account but `userKey` and `username` are empty** | Account exists but isn't linked to the user record | UI: edit account → Owner = the user; or "Map Account to User" action |
| `getEntDetailsforUsers` returns empty after a successful approval | Provisioning task created but not closed (disconnected endpoint quirk) | Manually complete in Admin → Tasks. WSRetry doesn't help — it's only for retrying failed connector calls. |
| `getEntDetailsforUsers` 400 with "username required" | Field name typo (`username` is correct) | Match the API doc exactly |
| `getEntDetailsforUsers` 401 Unauthorized | JWT token expired (1-hour TTL) | Re-run `/ECM/api/login` for a fresh token |
| `getPendingRequests` returns empty | Missing `SAVUSERNAME` header, or approver field on workflow points to wrong user | Always include `SAVUSERNAME: <approver-username>` header; verify workflow approver |
| `fetchRequestApprovalDetails` returns empty `ApprovalRequestDetails` | `userName` doesn't match the assigned approver | Pass the approver's username; for the prod workflow that's `wes-approver` |
| `fetchRequestApprovalDetails` returns 500 / generic HTML error | Required field missing or misspelled in body | `userName` is camelCase. Field must be present and non-null. |
| **Hibernate `NonUniqueObjectException` on createrequest** | Stale session pinned to your auth token from a previous failed request | Get a fresh login token, clear Postman cookies, retry |
| **Validation Logs on the workflow Version tab** | Hidden source of actual runtime errors | Admin → Workflows → open workflow → Version tab → look at Validation Logs column |

---

## Settings to capture in broker/settings.py

After completing all three sections:

```python
# ============================================================================
# Saviynt API endpoints (Amsterdam GA, verified against tenant API docs)
# ============================================================================
SAVIYNT_BASE_URL          = "https://eic-poc-wesharris.saviyntcloud.com"
API_PATH_PREFIX           = "/ECM/api/v5"

# Authentication
PATH_LOGIN                = "/ECM/api/login"           # not under v5

# Object inspection (mostly for verification, broker rarely calls these at runtime)
PATH_GET_SECURITY_SYSTEMS = "/ECM/api/v5/getSecuritySystems"           # GET
PATH_GET_ENDPOINTS        = "/ECM/api/v5/getEndpoints"                  # POST + filterCriteria
PATH_GET_ENTITLEMENT_TYPES= "/ECM/api/v5/getEntitlementTypes"           # GET
PATH_GET_ENTITLEMENTS     = "/ECM/api/v5/getEntitlements"               # POST + entQuery
PATH_GET_USER             = "/ECM/api/v5/getUser"                       # POST + filtercriteria

# Access checks (broker calls this on /preflight)
PATH_GET_ENT_DETAILS_FOR_USERS = "/ECM/api/v5/getEntDetailsforUsers"    # GET with body
PATH_GET_USER_REQUESTABLE_ENTS = "/ECM/api/v5/getUserRequestableEntitlements"  # POST

# Access requests (broker calls these on /preflight when entitlement missing,
# and on /preflight/status for polling)
PATH_CREATE_REQUEST       = "/ECM/api/v5/createrequest"                 # POST, all-lowercase
PATH_FETCH_APPROVAL_DETAILS = "/ECM/api/v5/fetchRequestApprovalDetails" # POST + requestKey + userName
PATH_GET_PENDING_REQUESTS = "/ECM/api/v5/getPendingRequests"            # POST + SAVUSERNAME header
PATH_CANCEL_PENDING_REQUEST = "/ECM/api/v5/cancelPendingRequest"        # POST (cleanup only)

# ============================================================================
# Saviynt object names
# ============================================================================
APP_NAME                  = "Pulumi-Pipeline-AWS"   # security system + endpoint name
ENT_DEPLOY_DEV            = "EC2Deploy-Dev"
ENT_DEPLOY_PROD           = "EC2Deploy-Prod"
ENTITLEMENT_TYPE_DEV      = "EntDev"
ENTITLEMENT_TYPE_PROD     = "EntProd"

# ============================================================================
# Bootstrap identity (the broker SA AND the prod approver — same identity in v1)
# ============================================================================
SAVIYNT_USERNAME          = "igaadmin"
SAVIYNT_PASSWORD          = env("SAVIYNT_PASSWORD")  # never in code
DEMO_REQUESTOR            = "igaadmin"               # passed as `requestor` in createRequest
DEMO_APPROVER             = "igaadmin"               # passed as `userName` in fetchRequestApprovalDetails

# ============================================================================
# Demo users
# ============================================================================
DEMO_REQUESTING_USER      = "wes-dev"                # the beneficiary

# ============================================================================
# Behavior
# ============================================================================
APPROVAL_POLL_INTERVAL_S  = 30
APPROVAL_POLL_TIMEOUT_S   = 1800
PAM_CHECKOUT_TTL_MIN      = 30
```

---

## What's next

IGA configuration is complete and **verified end-to-end against the tenant** (2026-05-08). Both demo paths confirmed working:

- ✅ Dev path: `createrequest` → SS workflow's If-Else False branch → Grant Access → entitlement assigned (after manual task close)
- ✅ Prod path: `createrequest` (`requestor: wes-dev`) → If-Else True branch → Custom Assignment routes to `wes-approver` → PENDING with assignee → UI approval → APPROVED → entitlement assigned (after manual task close)

The broker can now run the full IGA flow against the tenant. Next phases:

1. **Auto-completion of provisioning tasks** — current state: manual click in Admin → Tasks. Plan: broker calls `updateTasks` API to close tasks itself after detecting APPROVED. Optional optimization: try toggling `automatedProvisioning: true` on the SS to see if Saviynt can do it natively.
2. **Phase 5 — PAM configuration** — separate doc, not yet written. Configures the AWS IAM checkout endpoint and the NHI registration endpoint.
3. **Phase 1 — Broker implementation** — wraps the verified API calls (with the corrected payload shapes) behind five HMAC-authenticated FastAPI endpoints.
