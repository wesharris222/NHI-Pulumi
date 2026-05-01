# Saviynt Tenant Configuration

> Status: ⏳ Not yet implemented. See [`../PROGRESS.md`](../PROGRESS.md) Phase 4.

## What goes here

Step-by-step guides for configuring your Saviynt tenant to support this demo. These are reference docs you'll follow once before the demo.

## Files to create (Phase 4)

- `00-OVERVIEW.md` — what objects you're creating and how they relate
- `01-application-onboarding.md` — Pulumi-Pipeline-AWS application object with custom properties for NHI metadata
- `02-entitlements.md` — Deploy-EC2-Dev (auto-approve workflow) and Deploy-EC2-Prod (manual approve workflow)
- `03-roles-and-users.md` — wes-dev (Developer role assigned), wes-approver (with approval rights on Deploy-EC2-Prod)
- `04-pam-endpoint.md` — endpoint configuration for AWS IAM credentials and EC2 instance accounts
- `05-service-account.md` — broker SA setup with rotation policy, IP restriction, certification cadence
- `06-test-checklist.md` — pre-demo validation: can wes-dev see Deploy-EC2-Dev? Does wes-approver get prod request notifications?

## Object inventory

By the end of Phase 4, your tenant will have:

| Object type | Names |
|---|---|
| Application | `Pulumi-Pipeline-AWS` |
| Entitlements | `Deploy-EC2-Dev`, `Deploy-EC2-Prod` |
| Roles | `Developer` (gets Deploy-EC2-Dev) |
| Users | `wes-dev`, `wes-approver`, `pulumi-broker-svc` (the SA) |
| PAM Endpoints | `AWS-IAM-Endpoint`, `EC2-Instances-Endpoint` |
| PAM Accounts | `pulumi-deployer` (AWS IAM), plus N EC2 NHI accounts created by demo runs |
| Workflows | Auto-approve workflow for Deploy-EC2-Dev, manual approve workflow for Deploy-EC2-Prod |
| SoD policy | Optional but recommended — flag if same user has Deploy-EC2-Dev and Deploy-EC2-Prod simultaneously |

## Custom property mapping (proposed)

For NHI registration via `/register-nhi`, we need to decide which Saviynt customproperty fields hold which metadata. Proposed:

| customproperty | Holds |
|---|---|
| `customproperty1` | Owner (requesting user) |
| `customproperty2` | Environment (dev/prod) |
| `customproperty3` | Pulumi stack name |
| `customproperty4` | EC2 instance ID |
| `customproperty5` | EC2 public IP |
| `customproperty6` | Created by (pipeline run URL) |
| `customproperty7` | Created at (ISO timestamp) |

These are configurable in `broker/settings.py`. Adjust to match your tenant's existing custom property usage if some slots are taken.
