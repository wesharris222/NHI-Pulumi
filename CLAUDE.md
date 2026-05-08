# Project Memory — Saviynt + Pulumi Demo

## Always read these first
1. PROGRESS.md — current build state and next steps
2. README.md — high-level overview
3. ARCHITECTURE.md — component flows and design
4. TALK_TRACK.md — demo narrative and the two-standing-secrets framing
5. saviynt-config/ — verified Amsterdam GA API configuration

## Key facts about this project
- Tenant: https://eic-poc-wesharris.saviyntcloud.com
- Saviynt EIC Amsterdam GA release
- Bootstrap identity: igaadmin (broker SA AND prod approver in v1)
- Beneficiary user: wes-dev
- Application: Pulumi-Pipeline-AWS (Security System + Endpoint, same name)
- Entitlement Types: `EntDev` (display `Pipeline Access - Dev`, Add Workflow `WF-EC2Deploy-Dev-AutoApprove`) and `EntProd` (display `Pipeline Access - Prod`, Add Workflow `WF-EC2Deploy-Prod-ManualApprove`). Amsterdam binds workflows at the type level, not the entitlement level.
- Entitlements: EC2Deploy-Dev (under EntDev, auto-approve), EC2Deploy-Prod (under EntProd, manual)

## Verified API endpoints — Amsterdam GA
The saviynt-config/03-roles-and-users.md file has the full settings.py block.
ALL paths come from broker/settings.py constants — never hardcode in client code.

## Build phase
Currently in Phase 1 — Broker. See PROGRESS.md for the checklist.

## Critical contracts (don't forget)
- **createrequest**: `requesttype: "ADD"` (string, not `"1"`); `entitlement` is an **ARRAY OF OBJECTS** with `entitlementtype` + `entitlementvalue` keys, NOT a flat string; `accountname` required at top level; `requestor` and `username` (beneficiary) are separate fields
- **`requestor` MUST equal `username` (beneficiary)** for manual approval to fire — admin-on-behalf-of (`requestor: igaadmin`, `username: wes-dev`) silently auto-approves entitlement requests, skipping the workflow's approval block entirely. The broker passes `requestor: <pipeline-user>`, not the SA name.
- **fetchRequestApprovalDetails**: `requestKey` (camelCase), `userName` (camelCase) = the workflow's assigned approver, not the requestor
- **getEntDetailsforUsers**: GET with body, params `endpoint` (not `endpointname`), `entitlementType` (camelCase), `entitlement_value` (snake_case); returns flat `accessDetails[]`
- **getPendingRequests**: requires `SAVUSERNAME` header set to the approver
- **getUserRequestableEntitlements does NOT exist** in this tenant's API — use `getEntitlements` (catalog state) + `getAccounts` (user-account mapping) + `getEntDetailsforUsers` (held entitlements) for diagnostics

## Workflow architecture (verified empirically — Amsterdam GA, this tenant)
- **One workflow at the Security System level** (`accessAddWorkflow` field on SS), NOT per-entitlement-type bindings. The Entitlement Type's `workflow` field with `enableEntitlementToRoleSync` wrapper is for role-sync, not Add Access requests.
- **Differentiate by entitlement type using If-Else *inside* the SS workflow**: `entitlement.entitlementtypekey.entitlementname.equals('EntProd') eq true`
- **Workflow Type = Parallel** is mandatory for `entitlement.*` references in If-Else (Serial workflows can't see the entitlement object).
- **Workflow lifecycle is two-step**: every edit creates a Composing version, must Send For Approval → Accept in Admin → Workflow → Workflow Approval before Active. Old version goes Inactive on each edit.
- **Approval block must wire all three outputs** (Approved, Rejected, Escalation) and have `Notification Email Template` populated, or the runtime null-pointers and auto-discontinues the request.
- **Approver user needs a SAV Role** (ROLE_END_USER or ROLE_ADMIN). User existence alone isn't enough.
- **`Requestable` flag lives only at the Endpoint level** in this tenant. No toggle on Entitlement Type or Entitlement record (despite older Saviynt docs suggesting otherwise).
- **Beneficiary user must have a stub account on the endpoint** before they can see entitlements in the Saviynt request catalog UI. Account must be mapped (non-empty `userKey`/`username` after creation).

## Disconnected endpoint provisioning
Pulumi-Pipeline-AWS has no downstream connector. After approval, provisioning tasks remain Open and don't link the entitlement to the user. Three solutions:
1. **Broker calls `updateTasks` to close the task** after seeing APPROVED (recommended).
2. Toggle SS `automatedProvisioning: true` (try this — may auto-close on approval).
3. Manually complete the task in Admin → Tasks (not viable for the demo).

WSRETRY does NOT help disconnected endpoints — it's for retrying *failed* connector calls, of which there are none here.

## Reference file
The original validate_secret.py (in conversation history, not in repo) contains
the proven login + LLT + checkout pattern. The saviynt_client.py should reuse
that pattern for the auth flow.