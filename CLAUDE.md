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
- Bootstrap identity: igaadmin (broker SA)
- Manual-approval approver: wes-approver (ROLE_ADMIN, separate from broker SA — required because requestor=approver triggers an auto-approve trap)
- Beneficiary user: wes-dev
- Application: Pulumi-Pipeline-AWS (Security System + Endpoint, same name)
- Entitlement Types: `EntDev` (display `Pipeline Access - Dev`) and `EntProd` (display `Pipeline Access - Prod`). Per-type workflow bindings are decorative in this tenant — workflow resolution happens at the SS level.
- Entitlements: EC2Deploy-Dev (under EntDev) and EC2Deploy-Prod (under EntProd). Dev is pre-assigned to wes-dev as standing access; prod is the demo's manual-approval trigger.
- Workflows: one SS-level Add workflow (`WF-PulumiPipeline-AddAccess`) with If-Else branching on entitlement type — True branch routes prod to wes-approver, False auto-approves everything else. OOB auto-approve workflow on SS-level Remove (no human gate; removals encouraged for least-privilege hygiene).
- SS-level toggle `automatedProvisioning: true` is ON — provisioning tasks auto-close on approval (verified). Broker does NOT need updateTasks logic.

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

## Disconnected endpoint provisioning — RESOLVED
Pulumi-Pipeline-AWS has no downstream connector. With `automatedProvisioning: true` on the Security System (verified 2026-05-11), provisioning tasks auto-close on approval and the entitlement assignment lands immediately. **The broker does NOT need to call `updateTasks` or any task-management API.** `/preflight/status` flow: poll `fetchRequestApprovalDetails` until APPROVED → optionally poll `getEntDetailsforUsers` once to confirm the entitlement is reflected → return approved.

If `automatedProvisioning` is ever toggled off, fallback is manual completion via Admin → Tasks. WSRETRY does NOT help disconnected endpoints — it's for retrying *failed* connector calls, of which there are none here.

## Reference file
The original validate_secret.py (in conversation history, not in repo) contains
the proven login + LLT + checkout pattern. The saviynt_client.py should reuse
that pattern for the auth flow.