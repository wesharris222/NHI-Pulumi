#!/usr/bin/env bash
# =============================================================================
# Phase 1 smoke test for the broker.
#
# Hits every endpoint in sequence with HMAC-signed requests. By default it
# expects a real Saviynt tenant behind the broker — a successful run validates
# tenant connectivity AND broker correctness in one pass.
#
# Usage:
#   BROKER_URL=http://127.0.0.1:8443 \
#   BROKER_HMAC_SECRET=$(cat ../broker/.env | grep BROKER_HMAC_SECRET | cut -d= -f2) \
#   REQUESTING_USER=wes-dev \
#   ./scripts/test_broker.sh
#
# Skip the live tenant calls and only verify auth + healthz with --auth-only.
# =============================================================================

set -euo pipefail

BROKER_URL="${BROKER_URL:-http://127.0.0.1:8443}"
HMAC_SECRET="${BROKER_HMAC_SECRET:?BROKER_HMAC_SECRET must be set}"
REQUESTING_USER="${REQUESTING_USER:-wes-dev}"
TARGET_ENV="${TARGET_ENV:-dev}"

# Optional: pass --auth-only to skip endpoints that touch Saviynt
AUTH_ONLY=0
if [[ "${1:-}" == "--auth-only" ]]; then
    AUTH_ONLY=1
fi

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"

pass() { echo -e "${GREEN}[PASS]${RESET} $1"; }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; exit 1; }
info() { echo -e "${YELLOW}[INFO]${RESET} $1"; }

# -----------------------------------------------------------------------------
# Build a signed request and call curl. Echoes the response body to stdout
# and the http status to stderr (one line: "HTTP <code>").
# -----------------------------------------------------------------------------
signed_call() {
    local method="$1"
    local path="$2"
    local body="${3:-}"

    local ts nonce sig
    ts=$(date +%s)
    nonce=$(head -c 16 /dev/urandom | xxd -p)

    # message = "{ts}.{nonce}.{body}"
    local msg="${ts}.${nonce}.${body}"
    sig=$(printf '%s' "$msg" \
        | openssl dgst -sha256 -hmac "$HMAC_SECRET" \
        | sed 's/^.* //')

    local url="${BROKER_URL}${path}"
    local response
    response=$(curl -sS -w '\nHTTP %{http_code}\n' \
        -X "$method" "$url" \
        -H 'Content-Type: application/json' \
        -H "X-Broker-Timestamp: ${ts}" \
        -H "X-Broker-Nonce: ${nonce}" \
        -H "X-Broker-Signature: ${sig}" \
        ${body:+-d "$body"})

    echo "$response"
}

http_code() {
    # Last "HTTP <code>" line in the captured curl output
    echo "$1" | awk '/^HTTP /{code=$2} END{print code}'
}

# =============================================================================
# 1. Healthz (unauthenticated)
# =============================================================================
info "1. GET /healthz (no auth)"
hz=$(curl -sS -w '\nHTTP %{http_code}\n' "${BROKER_URL}/healthz") || fail "broker not reachable"
hz_code=$(http_code "$hz")
[[ "$hz_code" == "200" ]] || fail "/healthz returned $hz_code: $hz"
pass "/healthz returned 200"

# =============================================================================
# 2. Auth: missing signature -> 401
# =============================================================================
info "2. POST /preflight without signature -> expect 401"
no_sig=$(curl -sS -w '\nHTTP %{http_code}\n' -X POST "${BROKER_URL}/preflight" \
    -H 'Content-Type: application/json' -d '{}')
no_sig_code=$(http_code "$no_sig")
[[ "$no_sig_code" == "401" || "$no_sig_code" == "422" ]] \
    || fail "expected 401/422 without signature; got $no_sig_code"
pass "unsigned request rejected ($no_sig_code)"

# =============================================================================
# 3. Auth: bad signature -> 401
# =============================================================================
info "3. POST /preflight with wrong signature -> expect 401"
ts=$(date +%s)
nonce="bad-$(head -c 8 /dev/urandom | xxd -p)"
bad=$(curl -sS -w '\nHTTP %{http_code}\n' -X POST "${BROKER_URL}/preflight" \
    -H 'Content-Type: application/json' \
    -H "X-Broker-Timestamp: ${ts}" \
    -H "X-Broker-Nonce: ${nonce}" \
    -H "X-Broker-Signature: deadbeef" \
    -d '{"requesting_user":"x","target_env":"dev"}')
bad_code=$(http_code "$bad")
[[ "$bad_code" == "401" ]] || fail "expected 401 with bad signature; got $bad_code"
pass "bad signature rejected (401)"

if [[ "$AUTH_ONLY" == "1" ]]; then
    pass "auth-only mode complete"
    exit 0
fi

# =============================================================================
# 4. /preflight (live)
# =============================================================================
info "4. POST /preflight (live tenant call)"
preflight_body="$(printf '{"requesting_user":"%s","target_env":"%s","justification":"smoke test"}' \
    "$REQUESTING_USER" "$TARGET_ENV")"
pf=$(signed_call POST /preflight "$preflight_body")
pf_code=$(http_code "$pf")
echo "$pf"
[[ "$pf_code" == "200" ]] || fail "/preflight returned $pf_code"
pass "/preflight returned 200"

# Capture request_id if pending
PREFLIGHT_REQ_ID=$(echo "$pf" \
    | sed -n 's/.*"request_id":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
PREFLIGHT_STATUS=$(echo "$pf" \
    | sed -n 's/.*"status":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)

# =============================================================================
# 5. /preflight/status/{id} (only if pending)
# =============================================================================
if [[ "$PREFLIGHT_STATUS" == "pending" && -n "$PREFLIGHT_REQ_ID" ]]; then
    info "5. GET /preflight/status/${PREFLIGHT_REQ_ID}"
    ps=$(signed_call GET "/preflight/status/${PREFLIGHT_REQ_ID}")
    ps_code=$(http_code "$ps")
    echo "$ps"
    [[ "$ps_code" == "200" ]] || fail "preflight status returned $ps_code"
    pass "/preflight/status returned 200 (poll once)"
else
    info "5. preflight returned status=${PREFLIGHT_STATUS}; skipping poll"
fi

# =============================================================================
# 6. /checkout-aws (only if user already entitled — preflight ok)
# =============================================================================
if [[ "$PREFLIGHT_STATUS" == "ok" ]]; then
    info "6. POST /checkout-aws"
    co_body="$(printf '{"requesting_user":"%s","target_env":"%s"}' \
        "$REQUESTING_USER" "$TARGET_ENV")"
    co=$(signed_call POST /checkout-aws "$co_body")
    co_code=$(http_code "$co")
    co_redacted=$(echo "$co" | sed 's/\("aws_secret_access_key":"\)[^"]*/\1***REDACTED***/')
    echo "$co_redacted"
    [[ "$co_code" == "200" ]] || fail "/checkout-aws returned $co_code"
    pass "/checkout-aws returned 200"

    ACCOUNT_KEY=$(echo "$co" \
        | sed -n 's/.*"account_key":[[:space:]]*\([0-9]*\).*/\1/p' | head -n1)

    # ===========================================================
    # 7. /register-nhi (synthetic instance, won't exist in AWS)
    # ===========================================================
    info "7. POST /register-nhi (synthetic test instance)"
    nhi_body=$(cat <<EOF
{
  "instance_id": "i-test0000000000000",
  "public_ip": "203.0.113.1",
  "target_env": "${TARGET_ENV}",
  "requesting_user": "${REQUESTING_USER}",
  "owner": "${REQUESTING_USER}",
  "os_username": "ubuntu",
  "os_password": "test-password-do-not-use"
}
EOF
)
    nhi=$(signed_call POST /register-nhi "$nhi_body")
    nhi_code=$(http_code "$nhi")
    echo "$nhi"
    if [[ "$nhi_code" == "200" ]]; then
        pass "/register-nhi returned 200"
    else
        info "/register-nhi returned ${nhi_code} — expected if PAM endpoint or createAccount path needs tenant tuning (see PROGRESS.md Phase 5)"
    fi

    # ===========================================================
    # 8. /checkin-aws
    # ===========================================================
    if [[ -n "$ACCOUNT_KEY" ]]; then
        info "8. POST /checkin-aws account_key=${ACCOUNT_KEY}"
        ci_body="$(printf '{"account_key":%s}' "$ACCOUNT_KEY")"
        ci=$(signed_call POST /checkin-aws "$ci_body")
        ci_code=$(http_code "$ci")
        echo "$ci"
        [[ "$ci_code" == "200" ]] || fail "/checkin-aws returned $ci_code"
        pass "/checkin-aws returned 200"
    fi
else
    info "6-8. skipping checkout/nhi/checkin because preflight is ${PREFLIGHT_STATUS}"
fi

echo
pass "smoke test complete"
