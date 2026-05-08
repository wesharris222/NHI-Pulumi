# Scripts

> Status: ⏳ Not yet implemented. See [`../PROGRESS.md`](../PROGRESS.md) Phase 1 + 5.

## What goes here

Helper scripts for local development, testing, and demo operation.

## Files to create

### Phase 1 (alongside broker)

- `test_broker.sh` — curl-based smoke test for each broker endpoint, with HMAC signing
- `gen_hmac_secret.sh` — generate a strong HMAC secret for `.env` and GitHub repo
- `check_saviynt_endpoints.sh` — quick connectivity test to verify each Saviynt API path works against the tenant before plugging it into the broker

### Phase 5 (testing)

- `e2e_test.sh` — full happy-path test from CLI without GitHub Actions (calls broker endpoints in sequence to simulate a pipeline)

### Phase 6 (demo operations)

- `pre_demo_checklist.sh` — verifies tenant state, broker is running, runner is connected, AWS is reachable
- `cleanup_demo.sh` — removes EC2 instances, deletes test NHI accounts from Saviynt PAM
- `reset_entitlement.sh` — removes EC2Deploy-Prod from wes-dev so the demo can be replayed
