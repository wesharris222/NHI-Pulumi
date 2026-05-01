# Pulumi Program — EC2 Deploy

> Status: ⏳ Not yet implemented. See [`../PROGRESS.md`](../PROGRESS.md) Phase 2.

## What goes here

A Pulumi Python program that deploys a t2.micro Ubuntu EC2 instance in us-east-1 with a generated SSH keypair and a randomly-passworded OS user. Outputs are consumed by the GitHub Actions workflow and forwarded to the broker for Saviynt PAM vaulting.

## Files to create (Phase 2)

- `Pulumi.yaml` — project metadata
- `Pulumi.dev.yaml` — dev stack config
- `Pulumi.prod.yaml` — prod stack config
- `__main__.py` — main program
- `requirements.txt`

## Stack outputs (consumed by GitHub Actions)

| Output | Type | Marked secret? |
|---|---|---|
| `instance_id` | string | no |
| `public_ip` | string | no |
| `public_dns` | string | no |
| `ssh_username` | string | no |
| `ssh_private_key` | string (PEM) | yes |
| `os_username` | string | no |
| `os_password` | string | yes |

## Design notes

- SSH key generated via `cryptography.hazmat` library, public half registered with EC2 via `aws.ec2.KeyPair`
- OS user created via cloud-init `user-data` with random password
- Free-tier compliant: t2.micro, Ubuntu 22.04 LTS in us-east-1
- Security group: SSH (22) from anywhere — DEMO SIMPLIFICATION, call out in talk track
- AWS credentials read from `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars (set by the GitHub workflow after broker checkout)

## Local run (once implemented, for testing only)

```bash
cd pulumi/
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# AWS creds must be in env (in production, from broker checkout)
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1

pulumi stack init dev    # or prod
pulumi up
pulumi stack output --json
pulumi destroy   # don't forget!
```
