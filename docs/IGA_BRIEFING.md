# IGA Implementation Briefing for Claude Code

> Drop-in briefing for Claude Code sessions working on the broker's IGA flow.
> Reference this file from a session prompt: `Read docs/IGA_BRIEFING.md and proceed.`

## Context

We have authoritative Saviynt EIC Amsterdam GA API documentation that corrects several
endpoint paths and payload shapes from earlier broker scaffolding. This briefing folds
those corrections into actionable instructions for updating the broker code (or
scaffolding placeholders if not yet written) and `broker/settings.py`.

The corrected guides are in:
- `saviynt-config/01-application-onboarding.md`
- `saviynt-config/02-entitlements.md`
- `saviynt-config/03-roles-and-users.md`

Treat those as authoritative.

---

## Settings Updates — `broker/settings.py`

Replace the Saviynt path/object section with this verified set:

```python
SAVIYNT_BASE_URL = "https://eic-poc-wesharris.saviyntcloud.com"

# Authentication (NOT under /v5)
PATH_LOGIN                      = "/ECM/api/login"

# Object inspection (admin/verification calls)
PATH_GET_SECURITY_SYSTEMS       = "/ECM/api/v5/getSecuritySystems"            # GET, query params
PATH_GET_ENDPOINTS              = "/ECM/api/v5/getEndpoints"                  # POST, filterCriteria wrapper
PATH_GET_ENTITLEMENT_TYPES      = "/ECM/api/v5/getEntitlementTypes"           # GET, query params
PATH_GET_ENTITLEMENTS           = "/ECM/api/v5/getEntitlements"               # POST, uses entQuery (SQL-like)
PATH_GET_USER                   = "/ECM/api/v5/getUser"                       # POST, filtercriteria wrapper

# The preflight check (broker /preflight calls this on every request)
PATH_GET_ENT_DETAILS_FOR_USERS  = "/ECM/api/v5/getEntDetailsforUsers"         # GET WITH BODY (Saviynt convention)
PATH_GET_USER_REQUESTABLE_ENTS  = "/ECM/api/v5/getUserRequestableEntitlements" # POST, uses endpointname (not endpoint)

# Access requests (broker submits and polls)
PATH_CREATE_REQUEST             = "/ECM/api/v5/createrequest"                 # POST, all-lowercase
PATH_FETCH_APPROVAL_DETAILS     = "/ECM/api/v5/fetchRequestApprovalDetails"   # POST, requestKey + userName
PATH_GET_PENDING_REQUESTS       = "/ECM/api/v5/getPendingRequests"            # POST, requires SAVUSERNAME header
PATH_CANCEL_PENDING_REQUEST     = "/ECM/api/v5/cancelPendingRequest"          # POST (cleanup)

# Object names
APP_NAME                        = "Pulumi-Pipeline-AWS"
ENT_DEPLOY_DEV                  = "Deploy-EC2-Dev"
ENT_DEPLOY_PROD                 = "Deploy-EC2-Prod"
ENTITLEMENT_TYPE                = "Entitlement"

# Bootstrap identity (broker SA AND prod approver — same identity for v1)
SAVIYNT_USERNAME                = "igaadmin"
SAVIYNT_PASSWORD                = env("SAVIYNT_PASSWORD")
DEMO_REQUESTOR                  = "igaadmin"
DEMO_APPROVER                   = "igaadmin"
DEMO_REQUESTING_USER            = "wes-dev"
```

---

## Key API Contract Corrections

### 1. createRequest payload is FLAT (not nested under accounts[])

```json
{
  "requesttype": "ADD",
  "username": "wes-dev",
  "endpoint": "Pulumi-Pipeline-AWS",
  "securitysystem": "Pulumi-Pipeline-AWS",
  "entitlement": "Deploy-EC2-Prod",
  "comments": "Pipeline run #X — justification",
  "requestor": "igaadmin",
  "checksod": "false"
}
```

Notes:
- `requesttype: "ADD"` — string literal "ADD", NOT "1"
- `username` — beneficiary
- `requestor` — submitter (matters for auto-approve restriction)
- `entitlement` — STRING, not array
- Path: `POST /ECM/api/v5/createrequest` (all-lowercase 'createrequest')

Response will contain a request key — capture as either `requestkey` or `requestid`
(verify field name on first live call). Broker should handle either; prefer
`requestkey` since fetchRequestApprovalDetails uses `requestKey` (camelCase) on input.

### 2. Status polling is fetchRequestApprovalDetails (NOT checkRequestStatus)

- Path: `POST /ECM/api/v5/fetchRequestApprovalDetails`
- Payload: `{"requestKey": "...", "userName": "igaadmin"}`
  - `requestKey` is camelCase with capital K
  - `userName` MUST be the workflow approver — NOT the beneficiary
- Response navigation:
  ```
  response["ApprovalRequestDetails"]["AccessRequestDetails"][0]["modifyTasks"][0]["approvalstatus"]
  ```
  OR same path under `tasksList` instead of `modifyTasks` depending on request type.
- Treat `APPROVED` and `REJECTED` as terminal; everything else as still-pending.

### 3. Preflight uses getEntDetailsforUsers, NOT getUserAccessAttributes or getUser

- Path: `GET /ECM/api/v5/getEntDetailsforUsers` (GET method, JSON body — Saviynt convention)
- Payload:
  ```json
  {
    "username": "wes-dev",
    "endpoint": "Pulumi-Pipeline-AWS",
    "entitlementType": "Entitlement",
    "entitlement_value": "Deploy-EC2-Dev"
  }
  ```
- Response: `response["accessDetails"]` is an array; non-empty + `errorCode "0"` means
  the user holds the entitlement.

Pseudocode for `/preflight`:

```python
details = call_get_ent_details_for_users(...)
if details.get("errorCode") == "0" and len(details.get("accessDetails", [])) > 0:
    return {"status": "approved"}
else:
    # Submit access request
    req_resp = call_create_request(...)
    request_key = req_resp.get("requestkey") or req_resp.get("requestid")
    return {"status": "pending", "request_key": request_key}
```

### 4. getEndpoints uses filterCriteria wrapper (capital C)

```json
{"filterCriteria": {"endpointname": "Pulumi-Pipeline-AWS"}}
```

### 5. getUser uses filtercriteria wrapper (lowercase c)

Yes, inconsistent with getEndpoints — this is per the docs.

```json
{"filtercriteria": {"username": "wes-dev"}}
```

### 6. getEntitlements uses entQuery (SQL-like string)

NOT a direct entitlementvalue field:

```json
{
  "endpoint": "Pulumi-Pipeline-AWS",
  "entitlementtype": "Entitlement",
  "entQuery": "ent.entitlement_value = 'Deploy-EC2-Prod'"
}
```

### 7. getSecuritySystems and getEntitlementTypes are GET endpoints

With query parameters — not POST.

### 8. getUserRequestableEntitlements uses `endpointname` (not `endpoint`)

This inconsistency is per the docs.

### 9. getPendingRequests requires a SAVUSERNAME header

In addition to the bearer token. Without this header it returns empty.

```
Header: SAVUSERNAME: igaadmin
Body: {"max": "10"}
```

---

## saviynt_client.py Updates

Update `broker/saviynt_client.py` methods to match these contracts. In particular:

- `login()` — unchanged (pattern proven in validate_secret.py: POST /ECM/api/login)
- `check_user_has_entitlement(username, entitlement_value)` — wraps
  getEntDetailsforUsers; returns bool
- `submit_access_request(username, entitlement_value, justification, requestor)` —
  wraps createrequest with the flat-field payload; returns request_key
- `poll_request_status(request_key, approver_username)` — wraps
  fetchRequestApprovalDetails; returns `"APPROVED" | "REJECTED" | "PENDING"`
- `get_pending_requests(approver_username)` — wraps getPendingRequests with
  SAVUSERNAME header
- `cancel_pending_request(request_key, requestor, comments)` — wraps
  cancelPendingRequest (used by demo-reset scripts)

All methods should accept the bearer token as a parameter or use a cached/refreshed
token from the client class. On 401 from any call, re-authenticate via login() and
retry once before propagating the error.

---

## Test Harness Updates

Update `scripts/test_broker.sh` (or create if missing) to exercise:

1. login → token
2. getEntDetailsforUsers for wes-dev + Deploy-EC2-Dev → expect non-empty accessDetails
3. getEntDetailsforUsers for wes-dev + Deploy-EC2-Prod → expect empty accessDetails
4. createrequest for wes-dev + Deploy-EC2-Prod → capture requestkey
5. fetchRequestApprovalDetails with that requestkey → expect PENDING
6. (manual UI step: approve as igaadmin)
7. fetchRequestApprovalDetails again → expect APPROVED
8. getEntDetailsforUsers for wes-dev + Deploy-EC2-Prod → expect non-empty accessDetails
9. cancelPendingRequest or remove entitlement to reset demo state

---

## Forward-Looking Note for Future Changes

If the API documentation evolves (later Saviynt releases), the centralized PATH_*
constants in `broker/settings.py` are the single point of update. The
`saviynt_client.py` methods should ONLY reference these constants, never hardcode
paths. Same for object names like `APP_NAME` and entitlement strings — settings is
source of truth.

When adding new Saviynt API integrations in the future:

1. Add the path as a new `PATH_*` constant in `settings.py` with comment indicating
   HTTP method and any quirks (header requirements, GET-with-body, payload wrappers)
2. Add a method to `saviynt_client.py` that uses ONLY the constant
3. Update `saviynt-config/*.md` if the API ties to tenant configuration
4. Document the API contract in a comment block above the saviynt_client method,
   including the exact response shape navigation path

---

## Boundary

Stop and ask before modifying anything outside `broker/` and `scripts/test_broker.sh`.
Don't touch the existing K3s setup, Pulumi placeholders, or GitHub Actions config —
those are separate phases.