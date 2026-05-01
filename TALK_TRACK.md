# Demo Talk Track

> The script and supporting framing. Adapt to your audience — this is the technical/security-architect version.

## Setup (60 seconds)

> "What I'm going to show you today is Saviynt governing a real DevOps pipeline. Most secrets management demos focus on credential storage — Saviynt's value is bigger than that. It's the identity context that key vaults don't have: who owns the application, who's allowed to deploy where, who approves elevated access, and what happens to credentials over their lifecycle. I'm going to deploy an AWS EC2 instance from a GitHub Actions pipeline, twice. Same user, two different target environments. You'll see why Saviynt is different from a vault."

## Run 1 — Dev Deployment (60-90 seconds)

> "Here's our developer, wes-dev. They're triggering the pipeline targeting our dev environment. Watch what happens."

**Trigger workflow_dispatch with `target_env=dev`.**

> "First step the pipeline does — before any AWS call, before any Pulumi command — it asks Saviynt: does wes-dev have the entitlement to deploy to dev? Saviynt says yes, because we've assigned that entitlement to anyone with the Developer role. Pipeline proceeds.
>
> Second step: the pipeline needs AWS credentials. Notice we don't have those baked into GitHub secrets, we don't have them in a Pulumi config file, we don't have them in any .env. The pipeline checks them out from Saviynt PAM with a 30-minute TTL. Saviynt records who, when, why."

**Pulumi runs, EC2 deploys.**

> "Now Pulumi has done its job — EC2 instance is up. Pipeline's last step: register this new instance as a non-human identity in Saviynt. The SSH key, the OS user password — none of those go into a CI artifact, none go into Slack, none go into a wiki. They get vaulted in Saviynt PAM, and the new account is tagged with the owner — wes-dev — the application, and the environment.
>
> When the pipeline ends, the AWS credentials get checked back in and rotated. So even the brief 30-minute window where they were valid is closed."

**Show in Saviynt UI:** the new PAM account, the metadata, the audit log entry.

> "From this point forward, anyone who needs SSH access to that EC2 instance has to go through Saviynt PAM. Same governance, same audit, same identity context."

## Run 2 — Prod Deployment (90-120 seconds)

> "Same user. Same pipeline. Different target."

**Trigger workflow_dispatch with `target_env=prod`.**

> "Watch what happens this time."

**Pipeline pauses on preflight.**

> "Pipeline asked Saviynt the same question — does wes-dev have the entitlement to deploy to prod? Saviynt says no. Developer role doesn't grant prod deploy. So instead of failing, the broker created an access request in Saviynt and the pipeline is now polling for approval."

**Switch to Saviynt UI.**

> "Here's the request from the approver's perspective. Notice what they see: who's requesting, what they're requesting, what application it's for, what justification — and Saviynt has already run an SoD check. If wes-dev had been trying to do something that violated separation of duties, this approval wouldn't even be possible.
>
> The approver clicks approve. They can grant it permanently — or, more realistically — with a TTL. Let's say four hours. After four hours, Saviynt automatically removes the entitlement."

**Approve in Saviynt.**

**Switch back to pipeline.**

> "Within the next 30-second polling interval, the pipeline picks up the approval and resumes. From here it's identical to the dev run — AWS creds checked out, Pulumi deploys, EC2 registered as an NHI in Saviynt, AWS creds checked back in.
>
> The interesting thing isn't that the pipeline ran. The interesting thing is that the *exact same pipeline code* — same workflow file, same Pulumi program — produced two completely different governance outcomes based on what Saviynt knew about the user, the application, and the request."

## The Differentiator (60 seconds)

> "Here's what I want you to take away. There are dozens of secrets management tools. They all do credential storage. They all do rotation. Many do dynamic credentials.
>
> What Saviynt does that they don't: Saviynt knows that this EC2 instance is owned by wes-dev. Saviynt knows that wes-dev's role just changed last week and that ownership might need to transfer. Saviynt knows that the application this instance serves is governed by an SoD policy. Saviynt knows that quarterly, an owner has to certify this NHI still exists for a valid reason. Saviynt knows that wes-dev's prod deploy entitlement expires in four hours and the credential they used will be revoked.
>
> A vault knows the credential is valid. Saviynt knows whether anyone *should be using it.* That's the difference between secrets storage and identity governance."

## The Two-Standing-Secrets Discussion

> "Sharp-eyed folks in the room are asking — okay, but the broker has to authenticate to Saviynt somehow. There must be a credential. Where is it?
>
> You're right, and I want to be upfront about this because every secrets architecture has this problem. Vault has its root token. AWS has its account root credentials. Azure has whatever identity authenticates to Key Vault. The 'first secret' problem is irreducible.
>
> This system has exactly two standing secrets. The first is a Saviynt service account credential held by the broker. Saviynt itself rotates that credential on a schedule we define — seven days in our reference config — restricts it to a specific source IP, a specific set of API endpoints, and requires it to be certified every 90 days. The broker self-heals on rotation through a pull pattern.
>
> The second is the HMAC secret between GitHub Actions and the broker. That's stored in GitHub repository secrets, which is the right tool for the job — it's a pipeline-channel auth secret, encrypted, RBAC-controlled, audit-logged in GitHub. We can have Saviynt rotate even that one nightly through the GitHub API if we want.
>
> So the comparison isn't 'Saviynt has zero static secrets vs your current state.' It's 'Saviynt collapses your hundreds of static pipeline secrets, terraform state files, dotenv files on developer laptops, and post-it notes down to two governed bootstrap credentials.' That's a meaningful change in your breach blast radius and your audit posture, and it's an honest claim."

## When the Customer Asks "Why Not Just Use Vault?"

> "Vault is a great vault. If your problem is 'I need a secure place to put secrets and rotate them,' Vault solves it. We're not in competition with Vault for that.
>
> What Vault doesn't have is the identity warehouse. Vault doesn't know that wes-dev was promoted to Senior last week. Vault doesn't know that the Customer Portal application is owned by your retail division. Vault doesn't run an SoD check before approving a credential request. Vault doesn't initiate a quarterly certification campaign for non-human identities.
>
> What we typically see in mature shops is Saviynt and Vault both deployed — Saviynt as the identity governance and request layer, Vault as a downstream credential store that Saviynt orchestrates. Saviynt-PAM removes the need for that, but if a customer has heavy Vault investment, Saviynt sits cleanly in front of it and adds the governance Vault was never designed to provide."

## When the Customer Asks "What Does This Cost in Saviynt Terms?"

> "What you saw is built on Saviynt EIC core capabilities — IGA for users/roles/entitlements/access requests, PAM for the credential vault and checkout, and the standard REST API for everything we automated. There's no additional Saviynt SKU required for this pattern. The customization is all on the broker side, which is a few hundred lines of Python and could be replaced by Lambda, Azure Functions, or any HTTP service in production."

## When the Customer Asks "How Does This Scale?"

> "Three dimensions to consider.
>
> First, more pipelines: the broker is stateless from a session perspective — every request gets a fresh Saviynt session token if needed. You can horizontally scale broker instances behind a load balancer. The HMAC secret can be unique per pipeline source, so a compromise of one pipeline's secret doesn't authorize others.
>
> Second, more applications: each application onboarded to Saviynt gets its own entitlement set. The broker doesn't need code changes — settings.py drives entitlement names. New app, new entitlements in Saviynt, point a workflow at it.
>
> Third, more clouds: the broker pattern works for any cloud. AWS today, Azure tomorrow — the IAM principal lives in Saviynt PAM as a different account, the broker fetches it the same way."

## Closing

> "What you saw is roughly two days of integration work for an SE who knows both Saviynt and Pulumi. The pattern is reusable across pipelines, across clouds, across application teams. The governance posture you get is materially better than 'rotate AWS keys quarterly and hope nobody copies them out of the CI variable into a developer's laptop.'
>
> Most importantly, the audit story changes. Today, when someone asks 'who deployed to prod last quarter and why,' you correlate CI logs, IAM logs, ticket systems, and whatever else. With this pattern, Saviynt's audit log answers that question in one place, with full identity context, and the answer holds up in a SOC 2 review."

---

## Demo Failure Modes — What to Say if Something Goes Wrong

| Failure | What to say |
|---|---|
| Broker can't reach Saviynt mid-demo | "This is actually a good failure to see — the pipeline fails clean rather than continuing without governance. In production, your monitoring alerts on broker→Saviynt connectivity." |
| Approval request doesn't appear in Saviynt UI for the approver | "Saviynt's notification routing depends on workflow configuration — in our demo tenant, notifications can lag. The request *is* there; let me show you it directly." (Show via API or admin view.) |
| Pulumi up fails (AWS region issue, AMI not found) | "The pipeline correctly invokes the cleanup job — let me show you the AWS creds getting checked back into Saviynt even on failure. That's the value: you don't have leaked credentials when deploys fail." |
| EC2 takes too long to come up | "While we wait — this is a real EC2 instance, not a mock. Let me walk through what's already happened in Saviynt..." (Use the time to show audit logs.) |
