# Claude Desktop prompt — Phase 4 Saviynt IGA objects

> ⚠️ **Historical** — this prompt was used to generate the original
> `saviynt-config/01–03` markdown. The actual structure landed differently
> after live-tenant testing on Amsterdam GA: there are now **two Entitlement
> Types** (`EntDev`, `EntProd`) under one endpoint, with workflows bound at
> the type level (Amsterdam has no per-entitlement Workflow field).
> `saviynt-config/02-entitlements.md` is the authoritative source; this
> prompt is preserved for context only.

> Paste everything below the line into Claude Desktop. Self-contained — Claude
> Desktop has no context on this repo, so the prompt explains the goal.
>
> Output goes into `saviynt-config/01-application-onboarding.md`,
> `saviynt-config/02-entitlements.md`, `saviynt-config/03-roles-and-users.md`.

---

I'm building a Saviynt + Pulumi DevOps demo. A FastAPI broker authenticates to my Saviynt EIC tenant and exposes endpoints to a GitHub Actions pipeline. The broker is built and tested end-to-end against the API; I now need to stand up the IGA objects in the tenant so the broker's `/preflight` endpoint returns the right outcomes for the demo.

**Tenant**: `https://eic-poc-wesharris.saviyntcloud.com` — Saviynt EIC, Amsterdam GA release. I have admin access via `igaadmin`.

**Demo flow I need to support**:

1. Developer `wes-dev` triggers a pipeline targeting `dev`. Broker calls Saviynt: "does `wes-dev` hold the entitlement `EC2Deploy-Dev`?" → yes → pipeline proceeds.
2. Developer `wes-dev` triggers the same pipeline targeting `prod`. Broker calls Saviynt: "does `wes-dev` hold `EC2Deploy-Prod`?" → no → broker submits an access request via `/ECM/api/v5/createrequest` → pipeline pauses, polls for status.
3. Approver `wes-approver` sees the request in the Saviynt UI and clicks Approve.
4. Pipeline polling sees the approved status, resumes, deploys.

**What I need created in the tenant**, with specific click-by-click steps for Amsterdam GA:

## 1. Security System + Endpoint: `Pulumi-Pipeline-AWS`

A standalone Security System named `Pulumi-Pipeline-AWS` with an endpoint of the same name. This represents the "application" the demo is governing access to. No live downstream connector — it's purely a policy container for the entitlements. Use a "Disconnected" / generic connection type or whatever Saviynt uses for an application object that doesn't have an automated provisioning target.

Steps I need:
- Create the Security System
- Create the matching Endpoint under that system
- Set the endpoint to allow request-based access (not just direct provisioning)
- Confirm that `POST /ECM/api/v5/createrequest` with `endpoint:"Pulumi-Pipeline-AWS"` and `securitysystem:"Pulumi-Pipeline-AWS"` will resolve

## 2. Two entitlements

Both attached to the `Pulumi-Pipeline-AWS` endpoint:

| Entitlement value | Type | Approval | Description |
|---|---|---|---|
| `EC2Deploy-Dev` | `Entitlement` | Auto-approve | Permission to run the pipeline against the dev environment |
| `EC2Deploy-Prod` | `Entitlement` | Manual approve via `wes-approver` | Permission to run the pipeline against prod |

Steps I need:
- Create the entitlement type if `Entitlement` doesn't exist on this endpoint (or tell me what type to use instead and I'll override `ENTITLEMENT_TYPE` in the broker config)
- Create both entitlement objects
- Mark both as `requestable=1`

## 3. Approval workflows

- A workflow that **auto-approves** any request for `EC2Deploy-Dev` (no human intervention; useful so a fresh user gets dev access without delay during the demo)
- A workflow that **routes to `wes-approver`** for any request for `EC2Deploy-Prod`, with notification, with the request showing requestor + business justification + SoD check result

Steps I need:
- How to create each workflow object
- How to attach each one to the matching entitlement
- How to verify a test request lands at the approver's queue

## 4. Two demo users

| Username | Role | What they hold |
|---|---|---|
| `wes-dev` | Developer (a normal end user, no admin) | Assigned `EC2Deploy-Dev` directly so `/preflight dev` returns `ok` immediately. Does NOT hold `EC2Deploy-Prod`. |
| `wes-approver` | Approver | Member of whatever Saviynt construct routes the prod approval to them. Does not need to hold the entitlement themselves. |

Steps I need:
- Create both users with email + temporary password
- Assign `EC2Deploy-Dev` to `wes-dev` directly (not via request — direct admin assignment, since this is the demo's "already-onboarded developer" baseline)
- Make `wes-approver` the designated approver in the EC2Deploy-Prod workflow

## 5. Verification

After each major step, give me an API verification I can run from the broker host (curl with a Bearer token) so I can confirm the object exists and is correctly shaped. For example:

- After Security System + Endpoint: `POST /ECM/api/v5/getEndpoints` filtered by name returns the endpoint
- After Entitlements: `POST /ECM/api/v5/getEntitlements` filtered by entitlement_value returns each one
- After user assignment: `POST /ECM/api/v5/getUser` for `wes-dev` with `responsefields:["username","entitlements"]` shows `EC2Deploy-Dev` in the entitlements list

If the API call shape differs by Amsterdam release, give me the right one.

## 6. Common gotchas

Flag anything that frequently bites people on Phase 4 specifically, including but not limited to:
- Required custom properties on the security system / endpoint that block creation
- Whether the entitlement needs to be added to a "request form" before it becomes requestable
- Whether the workflow needs to be activated/published before it takes effect
- Order-of-operations issues (e.g. must create the workflow before the entitlement, or vice versa)
- The difference between "directly assigning" an entitlement to a user (admin path) vs. "requesting it on their behalf" — I want the direct-assignment path for the baseline `wes-dev` setup
- Anything that prevents `getUser` from including the assigned entitlement in its response even when you ask via `responsefields`

## 7. NOT in scope for this prompt

Don't include PAM-side configuration (the AWS IAM checkout endpoint and the EC2 NHI registration endpoint) — those are a separate later prompt for Tests 3-6. Just the IGA side: application onboarding, entitlements, request workflows, users.

## 8. Output format

Organize the response so I can drop each section into a markdown file in my repo:

- Section A: Security System + Endpoint creation → `saviynt-config/01-application-onboarding.md`
- Section B: Entitlements + workflows → `saviynt-config/02-entitlements.md`
- Section C: Users + direct assignment → `saviynt-config/03-roles-and-users.md`

Each section should have the click-by-click steps, the verification API call, and the gotchas relevant to that section.

When you're done, I'll execute the steps in order, verify each one via the broker, and come back with anything that didn't work as documented.
