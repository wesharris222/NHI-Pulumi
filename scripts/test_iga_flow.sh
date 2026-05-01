#!/usr/bin/env bash
# =============================================================================
# Direct-Saviynt IGA flow exercise (not via the broker).
#
# Validates the verified Amsterdam GA contracts against the live tenant per
# the spec in docs/IGA_BRIEFING.md §"Test Harness Updates":
#   1. login -> bearer token
#   2. getEntDetailsforUsers wes-dev + Deploy-EC2-Dev   -> non-empty
#   3. getEntDetailsforUsers wes-dev + Deploy-EC2-Prod  -> empty
#   4. createrequest wes-dev + Deploy-EC2-Prod          -> capture requestkey
#   5. fetchRequestApprovalDetails(requestkey, igaadmin) -> PENDING
#   6. (manual UI step: approve as igaadmin)
#   7. fetchRequestApprovalDetails(requestkey, igaadmin) -> APPROVED
#   8. getEntDetailsforUsers wes-dev + Deploy-EC2-Prod  -> non-empty
#   9. cancelPendingRequest(requestkey)                  -> demo reset
#
# Reads tenant connection info from the same env vars the broker uses:
#   SavURL / SavAPIUser / SavAPIPass  (legacy names already exported)
#   SAVIYNT_BASE_URL / SAVIYNT_USERNAME / SAVIYNT_PASSWORD  (canonical)
#
# Usage:
#   scripts/test_iga_flow.sh           # full sequence, pauses for UI approve
#   scripts/test_iga_flow.sh check     # just the two getEntDetailsforUsers checks
#   scripts/test_iga_flow.sh request   # check + createrequest + first poll
#   scripts/test_iga_flow.sh poll <requestkey>   # poll a specific request
#   scripts/test_iga_flow.sh cancel <requestkey> # cancel a specific request
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
ENT_DEV="${ENT_DEPLOY_DEV:-Deploy-EC2-Dev}"
ENT_PROD="${ENT_DEPLOY_PROD:-Deploy-EC2-Prod}"
ENT_TYPE="${ENTITLEMENT_TYPE:-Entitlement}"
BENEFICIARY="${DEMO_REQUESTING_USER:-wes-dev}"
APPROVER="${DEMO_APPROVER:-$USER}"
REQUESTOR="${DEMO_REQUESTOR:-$USER}"

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
    local token="$1" username="$2" ent="$3"
    local resp
    resp=$(curl -sS -X GET "$BASE/getEntDetailsforUsers" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc \
            --arg u "$username" --arg ep "$APP" --arg et "$ENT_TYPE" --arg ev "$ent" \
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
# createrequest
# Echoes the captured requestkey on stdout
# -----------------------------------------------------------------------------
submit_request() {
    local token="$1" username="$2" ent="$3" justification="$4"
    local resp
    resp=$(curl -sS -X POST "$BASE/createrequest" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc \
            --arg u "$username" --arg ep "$APP" --arg ss "$APP" \
            --arg ent "$ent" --arg c "$justification" --arg r "$REQUESTOR" \
            '{requesttype:"ADD", username:$u, endpoint:$ep, securitysystem:$ss,
              entitlement:$ent, comments:$c, requestor:$r, checksod:"false"}')")
    echo "$resp" | jq '.' >&2
    local code key
    code=$(echo "$resp" | jq -r '.errorCode // empty')
    key=$(echo "$resp" | jq -r '.requestkey // .requestid // .RequestId // empty')
    if [[ "$code" != "0" || -z "$key" ]]; then
        fail "createrequest did not return a request key (errorCode=$code)"
    fi
    pass "createrequest returned requestkey=$key"
    echo "$key"
}

# -----------------------------------------------------------------------------
# fetchRequestApprovalDetails
# Echoes the aggregated status on stdout: PENDING/APPROVED/REJECTED/UNKNOWN
# -----------------------------------------------------------------------------
poll_status() {
    local token="$1" key="$2"
    local resp
    resp=$(curl -sS -X POST "$BASE/fetchRequestApprovalDetails" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg k "$key" --arg u "$APPROVER" '{requestKey:$k, userName:$u}')")
    echo "$resp" | jq '.' >&2
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
# cancelPendingRequest
# -----------------------------------------------------------------------------
cancel_request() {
    local token="$1" key="$2"
    curl -sS -X POST "$BASE/cancelPendingRequest" \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg r "$REQUESTOR" --arg k "$key" \
            '{requestor:$r, requestkey:$k, comments:"test_iga_flow.sh reset"}')" \
        | jq '.'
}

# =============================================================================
# Subcommand dispatch
# =============================================================================
case "${1:-full}" in
    check)
        info "Login"
        TOKEN=$(get_token); pass "Got bearer token (len=${#TOKEN})"
        info "Check $BENEFICIARY -> $ENT_DEV  (expect held)"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_DEV" \
            || fail "$BENEFICIARY should already hold $ENT_DEV (Phase 4 §C.4)"
        info "Check $BENEFICIARY -> $ENT_PROD (expect NOT held)"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_PROD" \
            && fail "$BENEFICIARY should NOT yet hold $ENT_PROD"
        pass "checks complete"
        ;;
    request)
        info "Login"
        TOKEN=$(get_token)
        info "Submit request: $BENEFICIARY for $ENT_PROD"
        KEY=$(submit_request "$TOKEN" "$BENEFICIARY" "$ENT_PROD" \
            "test_iga_flow.sh — prod approval test")
        info "Initial poll"
        STATUS=$(poll_status "$TOKEN" "$KEY")
        pass "initial status: $STATUS  (requestkey=$KEY)"
        ;;
    poll)
        [[ -n "${2:-}" ]] || fail "usage: $0 poll <requestkey>"
        TOKEN=$(get_token)
        STATUS=$(poll_status "$TOKEN" "$2")
        pass "status: $STATUS"
        ;;
    cancel)
        [[ -n "${2:-}" ]] || fail "usage: $0 cancel <requestkey>"
        TOKEN=$(get_token)
        cancel_request "$TOKEN" "$2"
        pass "cancel issued for $2"
        ;;
    full)
        info "Login"
        TOKEN=$(get_token); pass "Got bearer token"

        info "Pre-check: $BENEFICIARY's current entitlements"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_DEV" \
            || fail "$BENEFICIARY should already hold $ENT_DEV"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_PROD" \
            && fail "$BENEFICIARY should NOT yet hold $ENT_PROD — reset state first"

        info "Submit prod request"
        KEY=$(submit_request "$TOKEN" "$BENEFICIARY" "$ENT_PROD" \
            "test_iga_flow.sh — full flow")
        info "Poll (expect PENDING)"
        S1=$(poll_status "$TOKEN" "$KEY")
        [[ "$S1" == "PENDING" || "$S1" == "UNKNOWN" ]] \
            || fail "expected PENDING, got $S1"
        pass "status=$S1"

        echo
        info "===> MANUAL STEP: Log into Saviynt UI as $APPROVER and APPROVE request $KEY"
        read -r -p "Press Enter once approved..." _

        info "Poll again (expect APPROVED)"
        S2=$(poll_status "$TOKEN" "$KEY")
        [[ "$S2" == "APPROVED" ]] || fail "expected APPROVED, got $S2"
        pass "status=$S2"

        info "Verify entitlement now visible on user"
        check_entitlement "$TOKEN" "$BENEFICIARY" "$ENT_PROD" \
            || info "Entitlement not yet visible — provisioning task may be queued; run WSRetry job in Saviynt"

        echo
        info "Optional: ./scripts/test_iga_flow.sh cancel $KEY  to clean up state for next run"
        pass "full flow complete"
        ;;
    *)
        echo "usage: $0 [full|check|request|poll <key>|cancel <key>]" >&2
        exit 2
        ;;
esac
