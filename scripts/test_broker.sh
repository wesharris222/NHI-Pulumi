#!/usr/bin/env bash
# =============================================================================
# Phase 1 smoke test for the broker — HMAC-signed requests against the
# running uvicorn process.
#
# Currently exercises the IGA-side endpoints (preflight + status). PAM-side
# endpoints (checkout-aws / register-nhi / checkin-aws) require Phase 5
# tenant config and are NOT covered here — they live in scripts/test_pam.sh
# once that's written.
#
# Subcommands:
#   scripts/test_broker.sh auth         # /healthz + HMAC auth failure modes
#   scripts/test_broker.sh dev          # /preflight target_env=dev (expect ok)
#   scripts/test_broker.sh prod         # /preflight prod + manual approve + status poll
#   scripts/test_broker.sh status <id>  # one-shot /preflight/status poll
#   scripts/test_broker.sh full         # auth + dev + prod, in sequence (default)
#
# Required env:
#   BROKER_HMAC_SECRET    must match broker/.env
#
# Optional env:
#   BROKER_URL            default http://127.0.0.1:18443
#   REQUESTING_USER       default wes-dev (the beneficiary)
# =============================================================================

set -euo pipefail

BROKER_URL="${BROKER_URL:-http://127.0.0.1:18443}"
HMAC_SECRET="${BROKER_HMAC_SECRET:?BROKER_HMAC_SECRET must be set (grep BROKER_HMAC_SECRET broker/.env)}"
REQUESTING_USER="${REQUESTING_USER:-wes-dev}"

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[1;33m"; RESET="\033[0m"
pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*" >&2; exit 1; }
info() { echo -e "${YELLOW}[INFO]${RESET} $*"; }

# -----------------------------------------------------------------------------
# signed_call <method> <path> [body]
# Echoes the full curl response (body + trailing "HTTP <code>" line).
# -----------------------------------------------------------------------------
signed_call() {
    local method="$1" path="$2" body="${3:-}"
    local ts nonce sig
    ts=$(date +%s)
    nonce=$(head -c 16 /dev/urandom | xxd -p)
    local msg="${ts}.${nonce}.${body}"
    sig=$(printf '%s' "$msg" | openssl dgst -sha256 -hmac "$HMAC_SECRET" | sed 's/^.* //')
    curl -sS -w '\nHTTP %{http_code}\n' \
        -X "$method" "${BROKER_URL}${path}" \
        -H 'Content-Type: application/json' \
        -H "X-Broker-Timestamp: ${ts}" \
        -H "X-Broker-Nonce: ${nonce}" \
        -H "X-Broker-Signature: ${sig}" \
        ${body:+-d "$body"}
}

http_code() { echo "$1" | awk '/^HTTP /{c=$2} END{print c}'; }

# extract_str_json <response_body> <field>  -> first occurrence as string
extract_str_json() {
    echo "$1" | sed -n "s/.*\"$2\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
}

# =============================================================================
# auth — /healthz + missing/bad-signature 401 checks
# =============================================================================
run_auth() {
    info "GET /healthz (no auth)"
    local r
    r=$(curl -sS -w '\nHTTP %{http_code}\n' "${BROKER_URL}/healthz") \
        || fail "broker not reachable at $BROKER_URL"
    local c
    c=$(http_code "$r")
    [[ "$c" == "200" ]] || fail "/healthz: $c"
    pass "/healthz 200"

    info "POST /preflight without signature -> expect 401/422"
    r=$(curl -sS -w '\nHTTP %{http_code}\n' -X POST "${BROKER_URL}/preflight" \
        -H 'Content-Type: application/json' -d '{}')
    c=$(http_code "$r")
    [[ "$c" == "401" || "$c" == "422" ]] || fail "unsigned: $c"
    pass "unsigned request rejected ($c)"

    info "POST /preflight with bad signature -> expect 401"
    local ts
    ts=$(date +%s)
    r=$(curl -sS -w '\nHTTP %{http_code}\n' -X POST "${BROKER_URL}/preflight" \
        -H 'Content-Type: application/json' \
        -H "X-Broker-Timestamp: ${ts}" \
        -H "X-Broker-Nonce: bad-$(head -c 8 /dev/urandom | xxd -p)" \
        -H "X-Broker-Signature: deadbeef" \
        -d '{"requesting_user":"x","target_env":"dev"}')
    c=$(http_code "$r")
    [[ "$c" == "401" ]] || fail "bad signature: $c"
    pass "bad signature rejected (401)"
}

# =============================================================================
# dev — /preflight for dev path; expect status: ok because wes-dev pre-holds
# =============================================================================
run_dev() {
    info "POST /preflight target_env=dev   (expect status=ok — standing access)"
    local body
    body="$(printf '{"requesting_user":"%s","target_env":"dev","justification":"broker smoke test (dev path)"}' "$REQUESTING_USER")"
    local r
    r=$(signed_call POST /preflight "$body")
    echo "$r"
    local c status
    c=$(http_code "$r")
    [[ "$c" == "200" ]] || fail "/preflight dev: HTTP $c"
    status=$(extract_str_json "$r" status)
    [[ "$status" == "ok" ]] || fail "expected status=ok, got '$status'"
    pass "/preflight dev: status=ok"
}

# =============================================================================
# prod — /preflight for prod path; expect status: pending + request_id;
#        manual approval pause; poll /preflight/status until approved
# =============================================================================
run_prod() {
    info "POST /preflight target_env=prod   (expect status=pending, request_id)"
    local body
    body="$(printf '{"requesting_user":"%s","target_env":"prod","justification":"broker smoke test (prod path)"}' "$REQUESTING_USER")"
    local r
    r=$(signed_call POST /preflight "$body")
    echo "$r"
    local c status request_id
    c=$(http_code "$r")
    [[ "$c" == "200" ]] || fail "/preflight prod: HTTP $c"
    status=$(extract_str_json "$r" status)
    request_id=$(extract_str_json "$r" request_id)
    if [[ "$status" == "ok" ]]; then
        fail "prod /preflight returned ok — wes-dev already holds EC2Deploy-Prod; run 'scripts/test_iga_flow.sh remove' first"
    fi
    [[ "$status" == "pending" ]] || fail "expected status=pending, got '$status'"
    [[ -n "$request_id" ]] || fail "no request_id in response"
    pass "/preflight prod: status=pending, request_id=$request_id"

    echo
    info "===> MANUAL STEP: Log into Saviynt UI as wes-approver and APPROVE request $request_id"
    info "     (if you step away, resume later with:  $0 status $request_id)"
    read -r -p "Press Enter once approved..." _

    info "Polling /preflight/status/$request_id every 5s, up to 5 minutes"
    local attempt=0 max=60
    while (( attempt < max )); do
        attempt=$((attempt + 1))
        r=$(signed_call GET "/preflight/status/$request_id")
        echo "$r"
        c=$(http_code "$r")
        [[ "$c" == "200" ]] || fail "/preflight/status: HTTP $c"
        status=$(extract_str_json "$r" status)
        case "$status" in
            approved)
                pass "/preflight/status: approved   (attempt $attempt)"
                return
                ;;
            rejected)
                fail "request was rejected"
                ;;
            pending|unknown)
                info "status=$status (attempt $attempt/$max) — sleeping 5s"
                sleep 5
                ;;
            *)
                fail "unexpected status: '$status'"
                ;;
        esac
    done
    fail "timed out waiting for approval — resume polling with: $0 status $request_id"
}

# =============================================================================
# status <id> — one-shot poll on an existing request
# =============================================================================
run_status() {
    local id="$1"
    info "GET /preflight/status/$id"
    local r
    r=$(signed_call GET "/preflight/status/$id")
    echo "$r"
    local c
    c=$(http_code "$r")
    [[ "$c" == "200" ]] || fail "/preflight/status: HTTP $c"
    pass "status: $(extract_str_json "$r" status)"
}

# =============================================================================
# Dispatch
# =============================================================================
case "${1:-full}" in
    auth)
        run_auth
        ;;
    dev)
        run_dev
        ;;
    prod)
        run_prod
        ;;
    status)
        [[ -n "${2:-}" ]] || fail "usage: $0 status <request_id>"
        run_status "$2"
        ;;
    full)
        run_auth
        echo
        run_dev
        echo
        run_prod
        echo
        pass "broker smoke test complete"
        info "Reset state for next run:  scripts/test_iga_flow.sh remove"
        ;;
    *)
        echo "usage: $0 [full|auth|dev|prod|status <request_id>]" >&2
        exit 2
        ;;
esac
