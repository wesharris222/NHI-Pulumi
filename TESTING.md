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
- A host with Python 3.11+ for the broker (**Ubuntu broker host preferred** — see below)
- Bash + `curl` + `openssl` + `xxd` for the smoke test
- Network egress from the broker host to your tenant on 443

### Saviynt configuration

Use Claude Desktop with the prompt in [`docs/claude-desktop-prompts/test-01-saviynt.md`](docs/claude-desktop-prompts/test-01-saviynt.md). It produces version-aware click-by-click steps for creating the SA, assigning permissions, and verifying login from your workstation.

When that's complete you should have:

- A Saviynt service account username + password
- Confirmed via curl that `/ECM/api/login` returns both `access_token` **and** `refresh_token`
- The tenant base URL

### Saviynt credentials — env vars vs `.env`

The broker reads any of these for each value (canonical wins if both are set):

| What | Canonical name | Legacy name (Ubuntu host already has this) |
|---|---|---|
| Tenant URL | `SAVIYNT_BASE_URL` | `SavURL` |
| SA username | `SAVIYNT_USERNAME` | `SavAPIUser` |
| SA password | `SAVIYNT_PASSWORD` | `SavAPIPass` |

The Ubuntu broker host already exports `SavURL` / `SavAPIUser` / `SavAPIPass`,
so on that host you do **not** need to put those three values in `broker/.env`.
The only thing `broker/.env` needs is `BROKER_HMAC_SECRET`.

### Run procedure (Ubuntu broker host)

Do these in order on the Ubuntu broker VM. Each step has a verification you
should not skip — failures get cheaper to diagnose if you catch them at the
step that introduced them.

#### Step 1 — Confirm tenant env vars are present in this shell

```bash
echo "SavURL    : $SavURL"
echo "SavAPIUser: $SavAPIUser"
echo "SavAPIPass: ${SavAPIPass:+(set, length=${#SavAPIPass})}"
```

All three should print non-empty. If any are blank, source whatever file
exports them (`~/.bashrc`, `~/.profile`, a systemd service env file) before
continuing.

#### Step 2 — Pull the repo (SSH)

The Ubuntu broker host already has an SSH key registered with this GitHub
account, so use the SSH remote — no PAT prompts.

First, confirm SSH auth works:

```bash
ssh -T git@github.com
# Expect: "Hi wesharris222! You've successfully authenticated, ..."
```

Clone:

```bash
cd ~        # or wherever you want it
git clone git@github.com:wesharris222/NHI-Pulumi.git
cd NHI-Pulumi
```

If the clone reports `Permission denied (publickey)`, the SSH agent isn't
loading the key in this shell:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519   # or whichever key file is registered with GitHub
ssh -T git@github.com       # retry the auth check
```

If you've already cloned the repo via HTTPS, flip the existing remote to SSH
instead of re-cloning:

```bash
cd NHI-Pulumi
git remote set-url origin git@github.com:wesharris222/NHI-Pulumi.git
git remote -v   # should now show git@github.com:... for both fetch and push
git pull        # grabs the latest broker code without re-prompting
```

#### Step 3 — Python venv + dependencies

```bash
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install -r broker/requirements.txt
```

Verify:

```bash
.venv/bin/python -c "import broker.main; print('imports OK')"
```

You should see `imports OK`. If not, the venv didn't activate or a dep
failed to install — fix before proceeding.

#### Step 4 — Generate HMAC secret and create `.env`

```bash
HMAC=$(bash scripts/gen_hmac_secret.sh)
cp broker/.env.example broker/.env
# Replace the placeholder line with the real value:
sed -i "s|^BROKER_HMAC_SECRET=.*|BROKER_HMAC_SECRET=$HMAC|" broker/.env
echo "$HMAC" > /tmp/hmac.txt   # we'll need this in the test terminal
```

Leave the `SAVIYNT_BASE_URL` / `SAVIYNT_USERNAME` / `SAVIYNT_PASSWORD` lines
in `broker/.env` as-is (placeholders) — the broker will pick up the real
values from `SavURL` / `SavAPIUser` / `SavAPIPass` in your shell environment.

#### Step 5 — Start the broker

In **terminal A**, from the repo root:

```bash
.venv/bin/python -m uvicorn broker.main:app --host 127.0.0.1 --port 8443
```

You should see uvicorn log lines ending with `Application startup complete.`
Leave this terminal running. If the broker exits with a `RuntimeError` about
a missing required env var, recheck Step 1.

#### Step 6 — Auth-only smoke (no Saviynt calls)

In **terminal B**, from the repo root:

```bash
export BROKER_URL=http://127.0.0.1:8443
export BROKER_HMAC_SECRET=$(cat /tmp/hmac.txt)
bash scripts/test_broker.sh --auth-only
```

Expect three `[PASS]` lines:

- `/healthz returned 200`
- `unsigned request rejected (422)`
- `bad signature rejected (401)`

If this fails, the broker isn't reachable or HMAC config is mismatched —
fix before Step 7.

#### Step 7 — Signed `/preflight` to force a real Saviynt login

Still in terminal B:

```bash
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

Capture the response body and the HTTP status. Match it against the table
in **Expected results** below.

#### Step 8 — Stop the broker and clean up

When you're done, in terminal A press `Ctrl+C`, then:

```bash
rm -f /tmp/hmac.txt
```

### Alternate: Windows local dev (optional)

You can run the broker on your Windows workstation for fast iteration. Set
the three Saviynt env vars yourself before launching uvicorn:

```bash
# git-bash, from repo root
export SavURL='https://your-tenant.saviyntcloud.com'
export SavAPIUser='svc-pulumi-broker'
export SavAPIPass='...'
export BROKER_HMAC_SECRET=$(bash scripts/gen_hmac_secret.sh)
.venv/Scripts/python -m uvicorn broker.main:app --host 127.0.0.1 --port 8443
```

Then the same Step 6 + Step 7 from another git-bash terminal.

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
