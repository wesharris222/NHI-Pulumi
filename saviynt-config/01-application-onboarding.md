# 01 — Security System + Endpoint: Pulumi-Pipeline-AWS

> **Goal:** Stand up the Saviynt object that represents the "application being governed" in this demo. No live downstream connector — this is a pure governance container so entitlements have somewhere to attach and access requests have a target.

## Tenant
`https://eic-poc-wesharris.saviyntcloud.com` — Saviynt EIC Amsterdam GA.

## Prerequisites
- Admin login (`igaadmin`)
- A bearer token from `POST /ECM/api/login` for verification calls (already validated against this tenant in `validate_secret.py`)

## API path prefix

All Amsterdam GA REST APIs sit under `/ECM/api/v5/`. The full base for verification calls is:
```
https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5
```

---

## A.1 Create the Security System

A **Security System** is the top-level container; an **Endpoint** lives under it. For a "no-downstream-connector" pattern, you create both with no connection attached.

### Click-by-click

1. Log in as `igaadmin`.
2. Click the **Applications** icon (top right of home page) → **Admin**.
   - **VERIFY (Amsterdam UI)**: In Amsterdam GA, the menu may be **Admin Console** directly. If you don't see "Applications → Admin," look for **ADMIN** in the top nav. The destination is the same.
3. In the left pane, expand **Identity Repository** → **Security Systems**.
4. Click the **Actions** dropdown → **Create Security System**.
5. Fill in the **mandatory** fields:
   - **System Name**: `Pulumi-Pipeline-AWS`
   - **Display Name**: `Pulumi Pipeline AWS Demo`
   - **Hostname**: `n/a` (some releases require a value here — put `localhost` if it rejects empty)
   - **Port**: leave blank or `0`
   - **Access Add Workflow**: leave blank for now (we'll override per-entitlement)
   - **Access Remove Workflow**: leave blank
   - **Connection**: **DO NOT SELECT** any connection. This is the key to a "disconnected/governance-only" setup. If your tenant *requires* a Connection field selection, choose **NONE** or create a placeholder REST connection with no real endpoint URL.
6. **Provisioning**:
   - **Automated Provisioning**: **OFF**
   - **Use Open Connection**: **OFF**
   - **Reconcile to External**: **OFF**
7. Click **Save**.

### Gotcha: required custom properties on Security System

Some tenants have configuration that makes one or more Security System custom properties mandatory at create time. **VERIFY** by attempting save — if you get a validation error citing `customproperty<N>`, just put a placeholder like `demo` in that field and save. None of these affect the demo behavior.

---

## A.2 Create the Endpoint

The endpoint is what the API actually targets in `createRequest` and `getEntDetailsforUsers`.

### Click-by-click

1. From **Admin** → **Identity Repository** → **Endpoints**.
2. **Actions** → **Create Endpoint**.
3. Fill in:
   - **Endpoint Name**: `Pulumi-Pipeline-AWS` (must match the Security System name for clarity in the demo)
   - **Display Name**: `Pulumi Pipeline AWS Demo`
   - **Security System**: select `Pulumi-Pipeline-AWS` (the one you just created)
   - **Description**: `Demo: governance-only endpoint for Pulumi pipeline access entitlements`
   - **Owner Type**: User
   - **Owner**: `igaadmin`
   - **Resource Owner Type**: User
   - **Resource Owner**: `igaadmin`
   - **Account Name Validator Regex**: leave blank
   - **Account Custom Property Label**: leave blank
4. **Account Configuration** section:
   - **Allow Removal of Owner**: leave default
   - **Disable New Account Request If Account Exists**: **OFF**
   - **Allow Multiple Accounts**: **ON** — important so the demo can create multiple NHI accounts later
   - **Service Account**: leave blank
5. **Requestable Configuration**:
   - **Requestable**: **ON** ⚠️ critical — without this, entitlements under this endpoint can't be requested
6. **Provisioning**:
   - **Out of Band Action**: leave default
   - **Connection** subsection: leave entirely blank
7. Click **Save**.

### Gotcha: "Requestable" toggle

In Amsterdam GA's New Experience, the **Requestable** flag may live in a sub-panel called **Request Configuration** rather than directly on the endpoint. **VERIFY** after save by editing the endpoint and confirming the flag is **ON** somewhere on the form.

### Gotcha: "Connection" required

If save fails with "Connection is required":
- Create a stub REST connection named `Disconnected-Stub` with `https://localhost` and no auth, then attach it. This connection will never be used.
- Or have a Saviynt admin disable the global setting `ENDPOINT_CONNECTION_MANDATORY` if present.

---

## A.3 Verification

```bash
# Get a fresh bearer token (igaadmin)
TOKEN=$(curl -s -X POST "https://eic-poc-wesharris.saviyntcloud.com/ECM/api/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"igaadmin","password":"YOUR_ADMIN_PASSWORD"}' \
  | jq -r '.access_token')

BASE="https://eic-poc-wesharris.saviyntcloud.com/ECM/api/v5"
```

### Verify Security System exists

`getSecuritySystems` is a **GET** endpoint with query parameters (per Amsterdam docs).

```bash
curl -s -G "$BASE/getSecuritySystems" \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode "systemname=Pulumi-Pipeline-AWS" \
  --data-urlencode "max=4" \
  | jq '.'
```

**Expected:** response includes a record with `systemname: "Pulumi-Pipeline-AWS"` and active status.

### Verify Endpoint exists

`getEndpoints` is **POST**, and filtering uses `filterCriteria` (capital C).

```bash
curl -s -X POST "$BASE/getEndpoints" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "filterCriteria": {
      "endpointname": "Pulumi-Pipeline-AWS"
    }
  }' | jq '.'
```

**Expected:** at least one endpoint record with `endpointname: "Pulumi-Pipeline-AWS"` and `securitysystem: "Pulumi-Pipeline-AWS"`. Inspect the full record to identify which field name your tenant uses for "requestable" — common variants: `requestable`, `accessQuery`, `requestableEntitlement`. Capture this for later if needed.

### Capture the broker setting

Once verified, set in `broker/settings.py`:

```python
APP_NAME = "Pulumi-Pipeline-AWS"   # both security system and endpoint name
```

---

## Common Gotchas — Section A

| Symptom | Cause | Fix |
|---|---|---|
| "Save" button greyed out | Missing required custom property | Edit form, set placeholder values for any red-asterisk field |
| Endpoint save fails with "Connection is required" | Tenant config enforces connection | Create stub REST connection or disable global setting |
| `getEndpoints` returns empty list immediately after UI save | Indexing lag, or `status` is 0 | Wait 30 seconds and retry; check status field via UI |
| Endpoint exists but `requestable` is false in API response | Missed Requestable toggle in UI | Edit endpoint, find Requestable Configuration section, toggle on |
| API returns endpoints from other security systems too | Filter ignored on some Amsterdam endpoints | Add `securitysystem` field alongside `endpointname` in `filterCriteria` |
| "Owner is required" error on save | Endpoint owner field empty | Set Owner Type=User, select `igaadmin` |

---

## What's next

Move to **02-entitlements.md** to create the two entitlement objects and their approval workflows.
