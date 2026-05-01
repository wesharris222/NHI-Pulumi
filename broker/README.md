# Broker — FastAPI Service

Saviynt-facing service. The only component that holds Saviynt SA credentials.
Every inbound request is HMAC-authenticated; every outbound Saviynt call uses
the cached SA session and re-authenticates on 401.

## Files

| File | Purpose |
|---|---|
| `settings.py` | Env-driven configuration. All Saviynt URLs/paths/object names live here. |
| `.env.example` | Template for `.env` (ignored by git). |
| `saviynt_client.py` | Saviynt API wrapper. Patterned on `../ValidatebySPN-clean.py`. |
| `auth.py` | HMAC-SHA256 dependency with timestamp skew + nonce replay protection. |
| `models.py` | Pydantic schemas for request/response bodies. |
| `main.py` | FastAPI app. |
| `requirements.txt` | Pinned Python deps. |

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET`  | `/healthz` | Unauthenticated liveness probe |
| `POST` | `/preflight` | Check entitlement; if missing, open access request |
| `GET`  | `/preflight/status/{request_id}` | Poll approval status |
| `POST` | `/checkout-aws` | Check out AWS IAM creds from Saviynt PAM |
| `POST` | `/register-nhi` | Vault EC2 SSH key + OS creds as a new NHI |
| `POST` | `/checkin-aws` | Return AWS creds, trigger rotation |

## HMAC request format

Every protected endpoint requires three headers:

```
X-Broker-Timestamp:  <unix epoch seconds>
X-Broker-Nonce:      <unique string per request>
X-Broker-Signature:  hex(hmac_sha256(BROKER_HMAC_SECRET, "<ts>.<nonce>.<raw_body>"))
```

Default replay window is 300s; nonces are remembered for 600s.

## Local run

```bash
cd broker/
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# Edit .env: SAVIYNT_BASE_URL, SAVIYNT_USERNAME, SAVIYNT_PASSWORD,
#            BROKER_HMAC_SECRET (use ../scripts/gen_hmac_secret.sh)

# From the repo root, so the broker.* package imports resolve:
cd ..
uvicorn broker.main:app --host 127.0.0.1 --port 8443 --reload
```

## Smoke test

In another terminal:

```bash
export BROKER_URL=http://127.0.0.1:8443
export BROKER_HMAC_SECRET=<same value as in broker/.env>
export REQUESTING_USER=wes-dev
export TARGET_ENV=dev
./scripts/test_broker.sh

# To verify only HMAC auth without touching Saviynt:
./scripts/test_broker.sh --auth-only
```

## Saviynt API path overrides

Defaults in `settings.py` match a stock EIC tenant. Confirmed working from
`ValidatebySPN-clean.py`:

- `POST /ECM/api/login`
- `POST /ECM/api/v5/getAccounts`
- `POST /ECM/oauth/access_token_withissuer`
- `POST /ECMv6/api/pam/account/checkout`

Educated guesses (override in `.env` if your tenant differs):

- `POST /ECM/api/v5/checkUserAccess`
- `POST /ECM/api/v5/createRequest`
- `GET  /ECMv6/api/v5/fetchRequestStatus`
- `POST /ECM/api/v5/createAccount`
- `POST /ECM/api/v5/updateAccount`
- `POST /ECMv6/api/pam/account/checkin`

Phase 5 tracks confirming each of these against the live tenant.
