# Testing Plan

> Living doc. Each test gates the next. Update the status table and the
> **Notes / corrections** section as you go — the corrections you record here
> drive the values you'll override in `broker/.env`.

## Status

| # | Test | Goal | Status |
|---|------|------|--------|
| 1 | Broker auth + Saviynt login | Broker boots, HMAC works, SA can log in | Not started |
| 2 | Entitlement check (dev path) | `/preflight dev` returns `ok` for an entitled user | Pending Test 1 |
| 3 | AWS PAM checkout | `/checkout-aws` returns valid AWS creds | Pending Test 2 |
| 4 | NHI registration | `/register-nhi` creates an EC2 NHI account | Pending Test 3 |
| 5 | Approval flow (prod path) | `/preflight prod` opens a request; approval resumes | Pending Test 4 |
| 6 | AWS PAM checkin | `/checkin-aws` returns the credential and triggers rotation | Pending Test 5 |

After all six pass, Phase 1 is complete and Phase 2 (Pulumi program) can begin.

---

## Test 1: Broker auth + Saviynt login

### Goal

Confirm three things:

1. The broker boots and `/healthz` responds.
2. HMAC validation accepts properly signed requests and rejects unsigned/bad-signature requests. (No Saviynt traffic.)
3. The broker can authenticate to your Saviynt tenant as a service account, one round-trip end-to-end.

This is the smallest useful test. It validates the wiring without depending on
any Saviynt object configuration beyond a service account user.

### What you need

- Saviynt EIC tenant access with admin rights (to create or identify the SA)
- Saviynt base URL in the form `https://<tenant>.saviyntcloud.com`
- A host with Python 3.11+ for the broker
- Bash + `curl` + `openssl` + `xxd` for the smoke test (git-bash on Windows is fine)
- Network egress from the broker host to your tenant on 443

### Saviynt configuration

Use Claude Desktop with the prompt in [`docs/claude-desktop-prompts/test-01-saviynt.md`](docs/claude-desktop-prompts/test-01-saviynt.md). It produces version-aware click-by-click steps for creating the SA, assigning permissions, and verifying login from your workstation.

When that's complete you should have:

- A Saviynt service account username + password
- Confirmed via curl that `/ECM/api/login` returns both `access_token` **and** `refresh_token`
- The exact `SAVIYNT_BASE_URL` you'll put in `broker/.env`

### Broker configuration

From the repo root:

```bash
python -m venv .venv
.venv/Scripts/python -m pip install -r broker/requirements.txt   # Windows
# or: .venv/bin/python -m pip install -r broker/requirements.txt # macOS/Linux

cp broker/.env.example broker/.env
bash scripts/gen_hmac_secret.sh   # copy the hex output into BROKER_HMAC_SECRET in .env
```

Edit `broker/.env` and set at minimum:

- `SAVIYNT_BASE_URL` — **skip this if `SavURL` is already exported on the Ubuntu host**
- `SAVIYNT_USERNAME` — **skip this if `SavAPIUser` is already exported**
- `SAVIYNT_PASSWORD` — **skip this if `SavAPIPass` is already exported**
- `BROKER_HMAC_SECRET` (always required)

The broker reads either name; canonical wins if both are set.

Leave every Saviynt API path at its default — Test 1 only exercises `/ECM/api/login`, which is already confirmed against your validator script.

Start the broker (from the repo root, not from `broker/`):

```bash
.venv/Scripts/python -m uvicorn broker.main:app --host 127.0.0.1 --port 8443
```

Leave it running.

### Run

In a second terminal:

```bash
export BROKER_URL=http://127.0.0.1:8443
export BROKER_HMAC_SECRET=<same value as in broker/.env>

# 1. Auth-only smoke (no Saviynt calls — proves broker + HMAC are wired up)
bash scripts/test_broker.sh --auth-only

# 2. One signed /preflight to force a real Saviynt login
TS=$(date +%s)
NONCE=$(head -c 16 /dev/urandom | xxd -p)
BODY='{"requesting_user":"someone","target_env":"dev","justification":"smoke"}'
SIG=$(printf '%s' "${TS}.${NONCE}.${BODY}" \
  | openssl dgst -sha256 -hmac "$BROKER_HMAC_SECRET" \
  | sed 's/^.* //')

curl -sS -w '\nHTTP %{http_code}\n' -X POST "$BROKER_URL/preflight" \
  -H 'Content-Type: application/json' \
  -H "X-Broker-Timestamp: $TS" \
  -H "X-Broker-Nonce: $NONCE" \
  -H "X-Broker-Signature: $SIG" \
  -d "$BODY"
```

### Expected results

The auth-only run prints three `[PASS]` lines and exits 0.

The signed `/preflight` call returns one of:

| Response | Meaning | Action |
|---|---|---|
| `200` with `status: pending` or `ok` | Saviynt login worked **and** the entitlement-check path worked | Test 1 fully green; you've also de-risked Test 2 |
| `502` `saviynt_error` mentioning a path **other than** `/ECM/api/login` (e.g. `/checkUserAccess`) | Login worked; entitlement-check path needs override | Test 1 passes; record the failing path in **Notes** below for Test 2 |
| `502` `saviynt_error` with `/ECM/api/login` and HTTP 401 / "invalid credentials" | SA credentials wrong | Re-check `.env`, re-run |
| `502` `saviynt_error` with `unreachable` | DNS / firewall / TLS issue before reaching Saviynt | Verify URL, network egress, TLS trust |
| `500` (uncaught) | Bug in the broker — capture log and report | — |

### What to record

Once green, fill in:

- Tenant base URL: `__________________________`
- SA username: `__________________________`
- Login response: `[ ] access_token present  [ ] refresh_token present`
- Did `/preflight` return 200 or 502 with a different-path error: `__________________________`
- If different-path error, which path failed: `__________________________`

### Notes / corrections

_(append observations as you go — gotchas, version differences, paths that need overriding)_

- _none yet_

---

## Test 2-6

To be filled in once Test 1 passes. Each test will follow the same structure:
goal, prereqs, Saviynt config (via Claude Desktop prompt in `docs/claude-desktop-prompts/`), broker config, run, expected results, recordings.
