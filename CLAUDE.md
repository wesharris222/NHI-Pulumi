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
- Entitlements: Deploy-EC2-Dev (auto-approve), Deploy-EC2-Prod (manual)

## Verified API endpoints — Amsterdam GA
The saviynt-config/03-roles-and-users.md file has the full settings.py block.
ALL paths come from broker/settings.py constants — never hardcode in client code.

## Build phase
Currently in Phase 1 — Broker. See PROGRESS.md for the checklist.

## Critical contracts (don't forget)
- createrequest: requesttype="ADD" (not "1"), flat fields, entitlement is a STRING
- fetchRequestApprovalDetails: requestKey (camelCase), userName=approver
- getEntDetailsforUsers: GET with body, returns flat accessDetails[]
- getPendingRequests: requires SAVUSERNAME header

## Reference file
The original validate_secret.py (in conversation history, not in repo) contains
the proven login + LLT + checkout pattern. The saviynt_client.py should reuse
that pattern for the auth flow.