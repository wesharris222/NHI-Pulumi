#!/usr/bin/env bash
# =============================================================================
# Send a single signed /preflight request to the broker.
#
# Useful for ad-hoc testing without driving the full smoke suite. Reuses the
# same HMAC scheme as scripts/test_broker.sh.
#
# Usage:
#   BROKER_URL=http://127.0.0.1:18443 \
#   BROKER_HMAC_SECRET=$(cat /tmp/hmac.txt) \
#   scripts/preflight.sh [user] [env]
#
# Defaults:
#   user = someone
#   env  = dev
#
# Override the justification with PREFLIGHT_JUSTIFICATION=...
# =============================================================================

set -euo pipefail

BROKER_URL="${BROKER_URL:-http://127.0.0.1:18443}"
HMAC_SECRET="${BROKER_HMAC_SECRET:?BROKER_HMAC_SECRET must be set}"
REQ_USER="${1:-someone}"
TARGET_ENV="${2:-dev}"
JUSTIFICATION="${PREFLIGHT_JUSTIFICATION:-smoke test}"

TS=$(date +%s)
NONCE=$(head -c 16 /dev/urandom | xxd -p)
BODY=$(printf '{"requesting_user":"%s","target_env":"%s","justification":"%s"}' \
  "$REQ_USER" "$TARGET_ENV" "$JUSTIFICATION")
SIG=$(printf '%s' "${TS}.${NONCE}.${BODY}" \
  | openssl dgst -sha256 -hmac "$HMAC_SECRET" \
  | sed 's/^.* //')

echo ">> POST ${BROKER_URL}/preflight"
echo ">> user=${REQ_USER}  env=${TARGET_ENV}"
echo ">> body: ${BODY}"
echo

curl -sS -w '\n\nHTTP %{http_code}\n' -X POST "${BROKER_URL}/preflight" \
  -H 'Content-Type: application/json' \
  -H "X-Broker-Timestamp: ${TS}" \
  -H "X-Broker-Nonce: ${NONCE}" \
  -H "X-Broker-Signature: ${SIG}" \
  -d "${BODY}"
