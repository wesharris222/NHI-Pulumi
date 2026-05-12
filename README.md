# Saviynt + Pulumi DevOps Demo

> **Demonstrates the modern IGA + PAM value proposition: Saviynt as the governance layer for DevOps pipelines, not just another key store.**

## What This Demo Shows

A developer triggers a pipeline that deploys an AWS EC2 instance. The pipeline is governed end-to-end by Saviynt:

1. **Before deploy:** Saviynt verifies the requesting user has the entitlement to deploy to the target environment. Dev → auto-approved. Prod → access request created, pipeline pauses, approver acts in Saviynt UI, pipeline resumes.
2. **During deploy:** Pulumi gets its AWS credentials by checking out from Saviynt PAM with a 30-minute TTL. No long-lived AWS keys in CI variables.
3. **After deploy:** The new EC2 instance is registered in Saviynt PAM as a non-human identity (NHI) with full ownership metadata, and its SSH key + OS credentials are vaulted. All future access to the instance flows through Saviynt PAM checkout.

**The differentiator vs HashiCorp Vault, AWS Secrets Manager, Azure Key Vault:** Saviynt provides the *identity context* — application ownership, role-based entitlements, SoD checks, certification campaigns, NHI lifecycle — that pure key stores don't.

## Quick Status

See [`PROGRESS.md`](./PROGRESS.md) for current build state and next steps.

## Key Documents

| File | What it covers |
|---|---|
| [`PROGRESS.md`](./PROGRESS.md) | Build phases, checklist, open questions |
| [`ARCHITECTURE.md`](./ARCHITECTURE.md) | Detailed flows, sequence diagrams, component responsibilities |
| [`TALK_TRACK.md`](./TALK_TRACK.md) | What to say during the demo, including the two-standing-secrets discussion |
| [`broker/`](./broker/) | FastAPI service that brokers between GitHub Actions and Saviynt |
| [`pulumi/`](./pulumi/) | Pulumi Python program that deploys EC2 |
| [`github-actions/`](./github-actions/) | CI/CD workflow definition |
| [`saviynt-config/`](./saviynt-config/) | Step-by-step Saviynt tenant configuration |
| [`scripts/`](./scripts/) | Local test harnesses and helper scripts |
| [`docs/`](./docs/) | Additional reference material |

## Stack

- **Saviynt EIC** — IGA + PAM (existing tenant)
- **GitHub** (free tier) — repo + Actions
- **Pulumi Cloud** (free individual tier) — IaC orchestration
- **AWS** (free tier) — t2.micro EC2 in us-east-2
- **Ubuntu VM** — runs the FastAPI broker and a self-hosted GitHub Actions runner
- **Python 3.11+** — broker, Pulumi program, tests
- **FastAPI + uvicorn** — broker framework

## Build Status

🟡 **Scaffolding complete. Implementation begins at Phase 1 — Broker.**

Hand this entire directory to Claude Code with the prompt:

> "Read PROGRESS.md, then continue from the first unchecked Phase 1 item."

## Bootstrap Secret Inventory

The honest accounting (everything else is dynamic):

1. **Saviynt service account password** — held by the broker
2. **HMAC shared secret** — between GitHub Actions and broker

That's it. See [`TALK_TRACK.md`](./TALK_TRACK.md) for how to frame this during the demo.
