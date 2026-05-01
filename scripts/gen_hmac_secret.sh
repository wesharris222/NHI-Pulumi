#!/usr/bin/env bash
# Generate a 64-hex-char (256-bit) HMAC secret. Drop into broker/.env and the
# matching GitHub repo secret BROKER_HMAC_SECRET.
set -euo pipefail
head -c 32 /dev/urandom | xxd -p | tr -d '\n'
echo
