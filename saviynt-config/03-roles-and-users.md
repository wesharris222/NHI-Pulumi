# 03 — Users + Direct Entitlement Assignment

> **Goal:** Create `wes-dev`, then directly assign `EC2Deploy-Dev` so the dev-environment pipeline run finds the entitlement on `/preflight` immediately and skips the request flow entirely.

> **Why direct assignment vs. submitting a request:** The demo's narrative is "wes-dev is an established developer who already has dev access." If we set up `wes-dev` by submitting an access request — even an auto-approved one — there's a transient window where they don't yet hold the entitlement and the broker's first `/preflight` call would create a request instead of returning approved. Direct admin assignment is the clean baseline.

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

## C.2 (Optional) Create wes-approver

For demo v1, **`igaadmin` is the approver** and you can skip this section. Create `wes-approver` later if you want to demonstrate proper duty separation in a follow-on demo.

If you create them now: same steps as C.1 with `wes-approver` as username, then assign the OOB **End User** SAV role so they can log in and see request queues.

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

### Click-by-click — Path A (UI, preferred)

1. Edit the `wes-dev` user.
2. Find the **Entitlements** tab (in some Amsterdam UIs: **Access** or **User Access**).
3. **Actions** → **Add Entitlement** (or **Assign Entitlement**).
4. In the picker:
   - **Endpoint**: `Pulumi-Pipeline-AWS`
   - **Entitlement Type**: `Entitlement`
   - **Entitlement Value**: select `EC2Deploy-Dev`
5. Save.

> If your tenant has direct UI assignment disabled, use Path B.

### Click-by-click — Path B (admin-mediated request, no human approver)

Submit an access request **as `igaadmin`** for `wes-dev` for `EC2Deploy-Dev`. The auto-approve workflow handles it instantly.

```bash
curl -s -X POST "$BASE/createrequest" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requesttype": "ADD",
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "securitysystem": "Pulumi-Pipeline-AWS",
    "entitlement": "EC2Deploy-Dev",
    "comments": "Baseline assignment for demo - Wes Dev needs dev environment access",
    "requestor": "igaadmin",
    "checksod": "false"
  }' | jq '.'
```

The auto-approve workflow fires and the entitlement is granted within seconds. Verify via C.5.

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
    "entitlementType": "Entitlement",
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
      "entitlementType": "Entitlement",
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
    entitlementType=ENTITLEMENT_TYPE,
    entitlement_value=ent_value,
)
if response.get("errorCode") == "0" and len(response.get("accessDetails", [])) > 0:
    return {"status": "approved"}
else:
    # User does not hold entitlement → submit createRequest
    request_key = call_create_request(...)
    return {"status": "pending", "request_key": request_key}
```

### Sanity check: getUserRequestableEntitlements

This shows what `wes-dev` could *request*. With `allowAssignedEntitlement: "true"`, it also shows what they currently hold:

```bash
curl -s -X POST "$BASE/getUserRequestableEntitlements" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "wes-dev",
    "endpointname": "Pulumi-Pipeline-AWS",
    "entitlementtype": "Entitlement",
    "allowAssignedEntitlement": "true"
  }' | jq '.'
```

> Note: this endpoint uses `endpointname` (not `endpoint`) — the param name differs from `getEntDetailsforUsers`.

You should see both entitlements listed.

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
    "entitlementType": "Entitlement",
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
    "entitlementType": "Entitlement",
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
    "entitlementType": "Entitlement",
    "entitlement_value": "EC2Deploy-Prod"
  }' | jq '.accessDetails | length'
```

Step 2 — broker submits createRequest:

```bash
REQ_RESPONSE=$(curl -s -X POST "$BASE/createrequest" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "requesttype": "ADD",
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "securitysystem": "Pulumi-Pipeline-AWS",
    "entitlement": "EC2Deploy-Prod",
    "comments": "Pipeline run #demo — prod deploy",
    "requestor": "igaadmin",
    "checksod": "false"
  }')
echo "$REQ_RESPONSE" | jq '.'

# Capture request key (field name varies — adjust based on actual response)
REQ_KEY=$(echo "$REQ_RESPONSE" | jq -r '.requestkey // .requestid // empty')
echo "Request key: $REQ_KEY"
```

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

Step 4 — broker polls status (still pending):

```bash
curl -s -X POST "$BASE/fetchRequestApprovalDetails" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"requestKey\": \"$REQ_KEY\",
    \"userName\": \"igaadmin\"
  }" | jq '.ApprovalRequestDetails.AccessRequestDetails[0].modifyTasks[0].approvalstatus // .ApprovalRequestDetails.AccessRequestDetails[0].tasksList[0].approvalstatus'
```

**Expected:** `"PENDING"` or similar pre-approved state.

Step 5 — log into Saviynt UI as `igaadmin`, find the request, click Approve.

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
    "entitlementType": "Entitlement",
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

## Common Gotchas — Section C

| Symptom | Cause | Fix |
|---|---|---|
| Cannot create user: "Manager is required" | Tenant requires manager | Set Manager to `igaadmin` |
| Cannot create user: "Department/Location required" | Tenant has required custom user attributes | Set placeholder values |
| User created but `getUser` returns nothing | User in inactive state | Edit user, set Status to Active |
| Direct entitlement assignment from UI greyed out | Tenant globally disabled direct admin assignment | Use Path B (admin-submitted request with auto-approve) |
| `getEntDetailsforUsers` returns empty after assignment | Provisioning task created but not yet executed | Run **WSRetry** job from Job Control Panel; OR enable Instant Provisioning at security system level |
| `getEntDetailsforUsers` 400 with "username required" | Field name typo (`username` is correct) | Match the API doc exactly |
| `getPendingRequests` returns empty | Missing `SAVUSERNAME` header, or approver field on workflow points to wrong user | Always include `SAVUSERNAME: igaadmin` header; verify workflow approver |
| `fetchRequestApprovalDetails` returns empty `ApprovalRequestDetails` | `userName` doesn't match the assigned approver | Always pass `userName: "igaadmin"` (the workflow approver) |
| Approval clicked but `getEntDetailsforUsers` still empty | Provisioning task pending | Run WSRetry job, or wait for next scheduled provisioning run |

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
ENTITLEMENT_TYPE          = "Entitlement"

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

IGA configuration is complete. The broker can now run the full IGA flow against your tenant. The next phase configures PAM endpoints for AWS IAM checkout and EC2 NHI registration — separate prompt for Tests 3-6.
