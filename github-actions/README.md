# GitHub Actions Workflow

> Status: ⏳ Not yet implemented. See [`../PROGRESS.md`](../PROGRESS.md) Phase 3.

## What goes here

The CI/CD workflow that orchestrates broker calls and Pulumi runs. Runs on a self-hosted GitHub Actions runner installed on the same Ubuntu VM as the broker.

## Files to create (Phase 3)

- `deploy-ec2.yml` — main workflow file (will be copied to `.github/workflows/` in the actual repo)
- `helper-scripts/sign-request.sh` — HMAC signing helper if needed inline
- `SETUP.md` — runner installation + repo secret configuration steps

## Workflow inputs (workflow_dispatch)

- `target_env` — `dev` or `prod` (required)
- `requesting_user` — Saviynt username to act on behalf of (defaults to GitHub actor)

## Repository secrets required

| Secret | Purpose |
|---|---|
| `BROKER_URL` | e.g., `http://localhost:18443` if self-hosted runner is on same VM as broker |
| `BROKER_HMAC_SECRET` | Shared HMAC key with the broker |
| `PULUMI_ACCESS_TOKEN` | For Pulumi Cloud state |

## Workflow jobs

1. **`preflight`** — POST `/preflight`, poll `/preflight/status/{id}` if pending
2. **`checkout-aws`** — POST `/checkout-aws`, mask AKID/secret in output, pass to next job
3. **`pulumi-deploy`** — `pulumi stack select dev|prod && pulumi up`
4. **`register-nhi`** — extract Pulumi outputs, POST `/register-nhi`
5. **`cleanup`** — `if: always()` — POST `/checkin-aws`

## Self-hosted runner

The runner runs on the same Ubuntu VM as the broker. Broker is bound to `127.0.0.1:18443`, so the runner can reach it as `localhost` without exposing it to the internet. See `SETUP.md` (created in Phase 3) for installation.
