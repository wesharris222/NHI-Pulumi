#!/usr/bin/env bash
# =============================================================================
# Direct-Saviynt IGA flow exercise (not via the broker).
#
# Validates the verified Amsterdam GA contracts against the live tenant:
#   1. login -> bearer token
#   2. getEntDetailsforUsers wes-dev + EC2Deploy-Dev   -> non-empty (standing access)
#   3. getEntDetailsforUsers wes-dev + EC2Deploy-Prod  -> empty
#   4. createrequest wes-dev + EC2Deploy-Prod          -> capture requestkey
#   5. fetchRequestApprovalDetails(requestkey, wes-approver) -> PENDING
#   6. (manual UI step: approve as wes-approver)
#   7. fetchRequestApprovalDetails(requestkey, wes-approver) -> APPROVED
#   8. getEntDetailsforUsers wes-dev + EC2Deploy-Prod  -> non-empty
#      (provisioning task auto-closes via automatedProvisioning=true on SS)
#   9. REMOVE createrequest to reset for next demo run
#
# IMPORTANT: requestor MUST equal the beneficiary in this tenant. The
# admin-on-behalf-of pattern (requestor=igaadmin, username=wes-dev) silently
# auto-approves entitlement requests, skipping the workflow's approval block
# entirely. Default below sets requestor=wes-dev.
#
# Reads tenant connection info from the same env vars the broker uses:
#   SavURL / SavAPIUser / SavAPIPass  (legacy names already exported)
#   SAVIYNT_BASE_URL / SAVIYNT_USERNAME / SAVIYNT_PASSWORD  (canonical)
#
# Usage:
#   scripts/test_iga_flow.sh           # full sequence, pauses for UI approve
#   scripts/test_iga_flow.sh check     # just the two getEntDetailsforUsers checks
#   scripts/test_iga_flow.sh request   # check + createrequest + first poll
#   scripts/test_iga_flow.sh poll <requestkey>   # one-shot poll (with retry on transient err)
#   scripts/test_iga_flow.sh wait <requestkey>   # poll until APPROVED/REJECTED/TIMEOUT
#   scripts/test_iga_flow.sh cancel <requestkey> # cancel a pending request
#   scripts/test_iga_flow.sh remove              # REMOVE EC2Deploy-Prod from wes-dev (post-grant reset)
# =============================================================================

set -euo pipefail

BASE_URL="${SAVIYNT_BASE_URL:-${SavURL:-}}"
USER="${SAVIYNT_USERNAME:-${SavAPIUser:-}}"
PASS="${SAVIYNT_PASSWORD:-${SavAPIPass:-}}"

if [[ -z "$BASE_URL" || -z "$USER" || -z "$PASS" ]]; then
    echo "ERROR: tenant URL/user/pass missing — set SavURL/SavAPIUser/SavAPIPass or the SAVIYNT_* equivalents" >&2
    exit 1
fi

BASE="${BASE_URL%/}/ECM/api/v5"

# Tunables — override via env if your demo objects are named differently.
APP="${APP_NAME:-Pulumi-Pipeline-AWS}"
ENT_DEV="${ENT_DEPLOY_DEV:-EC2Deploy-Dev}"
ENT_PROD="${ENT_DEPLOY_PROD:-EC2Deploy-Prod}"
# Per-env Entitlement Types (saviynt-config/02-entitlements.md).
ENT_TYPE_DEV="${ENTITLEMENT_TYPE_DEV:-EntDev}"
ENT_TYPE_PROD="${ENTITLEMENT_TYPE_PROD:-EntProd}"
BENEFICIARY="${DEMO_REQUESTING_USER:-wes-dev}"
# APPROVER = the workflow's manual-approval approver, NOT the SA. The Custom
# Assignment block in WF-PulumiPipeline-AddAccess routes prod requests to
# this user.
APPROVER="${DEMO_APPROVER:-wes-approver}"
# REQUESTOR = beneficiary by default. MUST differ from the workflow's
# approver for manual approval to fire. See header comment.
REQUESTOR="${DEMO_REQUESTOR:-$BENEFICIARY}"
ACCOUNT_NAME="${DEMO_ACCOUNT_NAME:-$BENEFICIARY}"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"

pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${RESET} $*"; }

require_jq() { command -v jq >/dev/null 2>&1 || fail "jq is required (apt install jq)"; }
require_jq

# -----------------------------------------------------------------------------
# Step 1: login
# -----------------------------------------------------------------------------
get_token() {
    local resp
    resp=$(curl -sS -X POST "${BASE_URL%/}/ECM/api/login" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg u "$USER" --arg p "$PASS" '{username:$u, password:$p}')")
    local token
    token=$(echo "$resp" | jq -r '.access_token // .token // empty')
    if [[ -z "$token" ]]; then
        echo "$resp" | jq '.' >&2
        fail "login did not return an access_token"
    fi
    echo "$token"
}

# -----------------------------------------------------------------------------
# getEntDetailsforUsers — GET with JSON body
# Returns: 0 if user holds the entitlement, 1 otherwise
# -----------------------------------------------------------------------------
check_entitlement() {
    local token="$1" username="$2" ent="$3" ent_type="$4"
    local resp
    resp=$(curl -sS -X GET "$BASE/getEntDetailsforUsers" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc \
            --arg u "$username" --arg ep "$APP" --arg et "$ent_type" --arg ev "$ent" \
            '{username:$u, endpoint:$ep, entitlementType:$et, entitlement_value:$ev}')")
    local code count
    code=$(echo "$resp" | jq -r '.errorCode // empty')
    count=$(echo "$resp" | jq -r '.accessDetails | length')
    if [[ "$code" == "0" && "$count" -gt 0 ]]; then
        pass "$username holds $ent (count=$count)"
        return 0
    else
        info "$username does NOT hold $ent (errorCode=$code, count=$count)"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# createrequest — ADD
# Echoes the captured requestkey on stdout
#
# Payload shape verified 2026-05-08 against live tenant:
#   entitlement: ARRAY of {entitlementtype, entitlementvalue, businessjustification}
#   accountname: top-level field, required
#   createaccountifnotexists: "false"
#   requestor: MUST equal beneficiary (username) to avoid auto-approve trap
# -----------------------------------------------------------------------------
submit_request() {
    local token="$1" username="$2" ent="$3" ent_type="$4" justification="$5"
    local resp
    resp=$(curl -sS -X POST "$BASE/createrequest" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc \
            --arg u "$username" --arg ep "$APP" --arg ss "$APP" \
            --arg acct "$ACCOUNT_NAME" \
            --arg ent "$ent" --arg etype "$ent_type" \
            --arg c "$justification" --arg r "$REQUESTOR" \
            '{requesttype:"ADD",
              username:$u,
              endpoint:$ep,
              securitysystem:$ss,
              accountname:$acct,
              comments:$c,
              requestor:$r,
              createaccountifnotexists:"false",
              checksod:"false",
              entitlement:[{
                entitlementtype:$etype,
                entitlementvalue:$ent,
                businessjustification:$c
              }]}')")
    echo "$resp" | jq '.' >&2
    local code key
    code=$(echo "$resp" | jq -r '.errorCode // empty')
    key=$(echo "$resp" | jq -r '.requestkey // .requestid // .RequestId // empty')
    if [[ "$code" != "0" || -z "$key" ]]; then
        fail "createrequest did not return a request key (errorCode=$code)"
    fi
    pass "createrequest returned requestkey=$key  (requestor=$REQUESTOR, beneficiary=$username)"
    echo "$key"
}

# -----------------------------------------------------------------------------
# createrequest — REMOVE  (post-grant reset)
# Used to revoke EC2Deploy-Prod from wes-dev between demo runs. Relies on the
# SS-level Access Remove Workflow being bound to an auto-approval workflow.
# -----------------------------------------------------------------------------
submit_remove() {
    local token="$1" username="$2" ent="$3" ent_type="$4"
    local resp
    resp=$(curl -sS -X POST "$BASE/createrequest" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc \
            --arg u "$username" --arg ep "$APP" --arg ss "$APP" \
            --arg acct "$ACCOUNT_NAME" \
            --arg ent "$ent" --arg etype "$ent_type" \
            --arg r "${DEMO_REQUESTOR:-$USER}" \
            '{requesttype:"REMOVE",
              username:$u,
              endpoint:$ep,
              securitysystem:$ss,
              accountname:$acct,
              comments:"test_iga_flow.sh — REMOVE for demo reset",
              requestor:$r,
              entitlement:[{
                entitlementtype:$etype,
                entitlementvalue:$ent
              }]}')")
    echo "$resp" | jq '.' >&2
    local code key
    code=$(echo "$resp" | jq -r '.errorCode // empty')
    key=$(echo "$resp" | jq -r '.requestkey // .requestid // .RequestId // empty')
    if [[ "$code" != "0" || -z "$key" ]]; then
        fail "REMOVE createrequest failed (errorCode=$code)"
    fi
    pass "REMOVE submitted (requestkey=$key) — SS Access Remove Workflow should auto-approve and provisioning task should auto-close"
    echo "$key"
}

# -----------------------------------------------------------------------------
# fetchRequestApprovalDetails — single call
# Echoes the aggregated status on stdout: PENDING/APPROVED/REJECTED/UNKNOWN/ERROR
# ERROR = Saviynt returned the transient "An unexpected error occured" — caller
#         should retry. UNKNOWN = success response but no statuses found.
# -----------------------------------------------------------------------------
poll_status_once() {
    local token="$1" key="$2"
    local resp
    resp=$(curl -sS -X POST "$BASE/fetchRequestApprovalDetails" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg k "$key" --arg u "$APPROVER" '{requestKey:$k, userName:$u}')")
    echo "$resp" | jq '.' >&2

    # Detect Saviynt's transient "try again later" error so caller can retry.
    local err_msg err_code
    err_msg=$(echo "$resp" | jq -r '.msg // empty' | tr '[:upper:]' '[:lower:]')
    err_code=$(echo "$resp" | jq -r '.errorcode // .errorCode // empty')
    if [[ "$err_code" == "1" && "$err_msg" == *"unexpected error"* ]]; then
        echo "ERROR"
        return
    fi

    # Pull every approvalstatus from modifyTasks/tasksList
    local statuses
    statuses=$(echo "$resp" \
        | jq -r '[
            .ApprovalRequestDetails.AccessRequestDetails[]?
            | (.modifyTasks[]?, .tasksList[]?, .tasks[]?)
            | (.approvalstatus // .approvalStatus // empty)
          ] | join(",")')
    if [[ -z "$statuses" ]]; then echo "UNKNOWN"; return; fi
    local upper
    upper=$(echo "$statuses" | tr '[:lower:]' '[:upper:]')
    if echo "$upper" | grep -qE 'REJECTED|DENIED|DECLINED'; then echo "REJECTED"
    elif echo "$upper" | grep -qvE 'APPROVED|COMPLETE|COMPLETED'; then echo "PENDING"
    else echo "APPROVED"
    fi
}

# -----------------------------------------------------------------------------
# poll_status — retries on the transient ERROR response (Saviynt sometimes
# takes a few seconds to register a new request or fresh approval before
# fetchRequestApprovalDetails returns clean data).
# -----------------------------------------------------------------------------
poll_status() {
    local token="$1" key="$2"
    local attempt=0 max=4 status
    while (( attempt < max )); do
        attempt=$((attempt + 1))
        status=$(poll_status_once "$token" "$key")
        if [[ "$status" != "ERROR" ]]; then
            echo "$status"
            return
        fi
        if (( attempt < max )); then
            info "fetchRequestApprovalDetails transient error (attempt $attempt/$max) — retrying in 3s" >&2
            sleep 3
        fi
    done
    echo "ERROR"
}

# -----------------------------------------------------------------------------
# wait_for_approval — poll until APPROVED or REJECTED or timeout
# Usage: wait_for_approval <token> <key> [interval_seconds] [max_attempts]
# Echoes the terminal status (APPROVED / REJECTED / TIMEOUT).
# -----------------------------------------------------------------------------
wait_for_approval() {
    local token="$1" key="$2" interval="${3:-10}" max_attempts="${4:-60}"
    local attempt=0 status
    while (( attempt < max_attempts )); do
        attempt=$((attempt + 1))
        status=$(poll_status "$token" "$key")
        case "$status" in
            APPROVED|REJECTED)
                echo "$status"
                return
                ;;
            *)
                info "Waiting for approval (attempt $attempt/$max_attempts, status=$status) — sleeping ${interval}s" >&2
                sleep "$interval"
                ;;
        esac
    done
    echo "TIMEOUT"
}

# -----------------------------------------------------------------------------
# cancelPendingRequest (pre-approval cancel only — for already-granted
# entitlements use the remove subcommand)
# -----------------------------------------------------------------------------
cancel_request() {
    local token="$1" key="$2"
    curl -sS -X POST "$BASE/cancelPendingRequest" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg r "${DEMO_REQUESTOR:-$USER}" --arg k "$key" \
            '{requestor:$r, requestkey:$k, comments:"test_iga_flow.sh reset"}')" \
        | jq '.'
}

# =============================================================================
# Subcommand dispatch
# =============================================================================
case "${1:-full}" in
    check)
        info "Login as $USER"
        TOKEN=$(get_token); pass "Got bearer token (len=${#TOKEN})"
        info "Check $BENEFICIARY -> $ENT_DEV  (expect held)"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_DEV" "$ENT_TYPE_DEV" \
            || fail "$BENEFICIARY should already hold $ENT_DEV (standing access)"
        info "Check $BENEFICIARY -> $ENT_PROD (expect NOT held)"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_PROD" "$ENT_TYPE_PROD" \
            && fail "$BENEFICIARY should NOT yet hold $ENT_PROD — run 'remove' to reset"
        pass "checks complete"
        ;;
    request)
        info "Login"
        TOKEN=$(get_token)
        info "Submit request: $BENEFICIARY for $ENT_PROD  (requestor=$REQUESTOR)"
        KEY=$(submit_request "$TOKEN" "$BENEFICIARY" "$ENT_PROD" "$ENT_TYPE_PROD" \
            "test_iga_flow.sh — prod approval test")
        info "Settle delay (Saviynt sometimes needs a few seconds to register the new request)"
        sleep 3
        info "Initial poll  (userName=$APPROVER)"
        STATUS=$(poll_status "$TOKEN" "$KEY")
        pass "initial status: $STATUS  (requestkey=$KEY)"
        echo
        info "To wait for approval:  $0 wait $KEY"
        ;;
    poll)
        [[ -n "${2:-}" ]] || fail "usage: $0 poll <requestkey>"
        TOKEN=$(get_token)
        STATUS=$(poll_status "$TOKEN" "$2")
        pass "status: $STATUS"
        ;;
    wait)
        [[ -n "${2:-}" ]] || fail "usage: $0 wait <requestkey>"
        TOKEN=$(get_token)
        info "Waiting for approval on $2  (polling every 5s, up to 10 minutes)"
        STATUS=$(wait_for_approval "$TOKEN" "$2" 5 120)
        case "$STATUS" in
            APPROVED) pass "status: APPROVED" ;;
            REJECTED) fail "status: REJECTED" ;;
            TIMEOUT)  fail "timeout waiting for approval" ;;
            *)        fail "unexpected terminal status: $STATUS" ;;
        esac
        info "Verify entitlement now visible on user"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_PROD" "$ENT_TYPE_PROD" \
            || info "Entitlement not yet visible — provisioning task may still be processing"
        ;;
    cancel)
        [[ -n "${2:-}" ]] || fail "usage: $0 cancel <requestkey>"
        TOKEN=$(get_token)
        cancel_request "$TOKEN" "$2"
        pass "cancel issued for $2"
        ;;
    remove)
        info "Login"
        TOKEN=$(get_token)
        info "REMOVE $ENT_PROD from $BENEFICIARY"
        submit_remove "$TOKEN" "$BENEFICIARY" "$ENT_PROD" "$ENT_TYPE_PROD" >/dev/null
        info "Verify removed"
        sleep 3
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_PROD" "$ENT_TYPE_PROD" \
            && fail "$BENEFICIARY still holds $ENT_PROD — check provisioning task state"
        pass "removal verified"
        ;;
    full)
        info "Login as $USER"
        TOKEN=$(get_token); pass "Got bearer token"

        info "Pre-check: $BENEFICIARY's current entitlements"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_DEV" "$ENT_TYPE_DEV" \
            || fail "$BENEFICIARY should already hold $ENT_DEV"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_PROD" "$ENT_TYPE_PROD" \
            && fail "$BENEFICIARY should NOT yet hold $ENT_PROD — run '$0 remove' first"

        info "Submit prod request  (requestor=$REQUESTOR — MUST = beneficiary)"
        KEY=$(submit_request "$TOKEN" "$BENEFICIARY" "$ENT_PROD" "$ENT_TYPE_PROD" \
            "test_iga_flow.sh — full flow")
        info "Settle delay before first poll (Saviynt sometimes needs a beat)"
        sleep 3
        info "Poll (expect PENDING)"
        S1=$(poll_status "$TOKEN" "$KEY")
        [[ "$S1" == "PENDING" || "$S1" == "UNKNOWN" ]] \
            || fail "expected PENDING, got $S1 — check whether requestor=approver trap fired"
        pass "status=$S1"

        echo
        info "===> MANUAL STEP: Log into Saviynt UI as $APPROVER and APPROVE request $KEY"
        info "     (if you need to step away, abort with Ctrl+C and resume with:  $0 wait $KEY)"
        read -r -p "Press Enter once approved..." _

        info "Polling for APPROVED every 5s (with retry on transient errors, up to 5 minutes)"
        S2=$(wait_for_approval "$TOKEN" "$KEY" 5 60)
        case "$S2" in
            APPROVED) pass "status=$S2" ;;
            REJECTED) fail "request was rejected" ;;
            TIMEOUT)  fail "timed out waiting for APPROVED — try '$0 wait $KEY' to keep polling" ;;
            *)        fail "unexpected terminal status: $S2" ;;
        esac

        info "Verify entitlement now visible on user"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_PROD" "$ENT_TYPE_PROD" \
            || info "Entitlement not yet visible — provisioning task may still be processing; with automatedProvisioning=true it should auto-close within seconds"

        echo
        info "To reset for next run:  $0 remove"
        pass "full flow complete"
        ;;
    *)
        echo "usage: $0 [full|check|request|poll <key>|wait <key>|cancel <key>|remove]" >&2
        exit 2
        ;;
esac
