# Claude Desktop prompt — Test 1 Saviynt configuration

> Paste everything below the line into Claude Desktop. It is self-contained:
> Claude Desktop has no context on this repo, so the prompt explains what
> you're building and what you need.

---

I'm building a FastAPI broker that authenticates to my Saviynt EIC tenant and exposes pipeline-friendly endpoints to GitHub Actions. This is part of a demo showing Saviynt governing a Pulumi-driven AWS EC2 deployment.

The broker will eventually call these Saviynt REST APIs. Today I only need it to authenticate; the rest are listed so you can recommend the right permission scope:

- `POST /ECM/api/login` — authenticate, get `access_token` + `refresh_token`
- `POST /ECM/api/v5/getAccounts` — look up PAM accounts
- `POST /ECM/oauth/access_token_withissuer` — generate an LLT for PAM checkout
- `POST /ECMv6/api/pam/account/checkout` — retrieve a vaulted credential
- `POST /ECMv6/api/pam/account/checkin` — return a credential and trigger rotation
- `POST /ECM/api/v5/createRequest` — open access requests for elevated entitlements
- `GET /ECMv6/api/v5/fetchRequestStatus` — poll approval status
- `POST /ECM/api/v5/createAccount` — register new non-human-identity (NHI) accounts in PAM
- An entitlement-check endpoint (path TBD — will confirm against my tenant)

For Test 1 I only need to verify the broker can log in. Help me with the following with **specific click-by-click steps** for a current Saviynt EIC tenant. Where the UI varies between EIC versions, call that out and give me the steps for the most recent version.

1. **Create (or identify if it already exists) a dedicated service account user** in Saviynt EIC named something like `svc-pulumi-broker`. Machine-use only, never logged into interactively.

2. **Recommend a role / admin profile** to assign it so it can:
   - Authenticate to `/ECM/api/login` and receive both an `access_token` AND a `refresh_token` (the refresh_token is critical because PAM checkout in a later test depends on it)
   - Eventually call all the API endpoints listed above

   I want least-privilege, but Test 1 is just login. We'll narrow scope further in later tests, so it's fine if the recommendation is broad now and we tighten later.

3. **How to capture the tenant base URL** in the form `https://<tenant>.saviyntcloud.com` that goes into the broker config.

4. **How to verify the SA can authenticate** by hitting `/ECM/api/login` with curl from my workstation. I want:
   - The exact curl command (with placeholder values)
   - The expected JSON response shape
   - What specifically to confirm in that response — most importantly that BOTH `access_token` and `refresh_token` are present, because if only `access_token` comes back the broker won't be able to do PAM checkout in Test 3.

5. **Source-IP allowlisting**: if the SA's API access requires it, walk me through how to add my workstation IP and the broker host IP to the allowlist for this account.

6. **Common gotchas** — flag anything that frequently bites people on Test 1, including but not limited to:
   - TLS cert / self-signed cert issues
   - SA password complexity rules that conflict with `.env` files
   - MFA enforcement that needs disabling for service accounts
   - Permission propagation delay after assigning a role
   - Whether the SA needs to be marked as "external" / "API only" / "system account"
   - Anything that prevents `refresh_token` from being issued (some configurations only return `access_token`)

Please don't include anything beyond what's needed for the SA to log in and return a usable token pair. Later tests will layer on PAM endpoints, applications, entitlements, and approval workflows — keep this round narrowly scoped.
