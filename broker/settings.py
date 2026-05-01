"""
Broker configuration. Every Saviynt URL, endpoint path, and object name is
overridable via environment variables so a tenant change never requires a
code change.

Loaded once at import-time. The FastAPI app reads `settings` directly.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

try:
    from dotenv import load_dotenv

    load_dotenv(Path(__file__).resolve().parent / ".env")
except ImportError:
    pass


def _env(name: str, default: str | None = None, *, required: bool = False) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        raise RuntimeError(
            f"Required environment variable {name} is not set. "
            f"Copy broker/.env.example to broker/.env and fill it in."
        )
    return val or ""


def _env_first(names: list[str], default: str | None = None, *, required: bool = False) -> str:
    """Return the first non-empty value among `names`, else `default`.

    Lets the broker accept legacy env-var names already exported on the
    Ubuntu host (SavURL / SavAPIUser / SavAPIPass) without forcing a
    rename. The canonical name (first in the list) wins when both are set.
    """
    for name in names:
        val = os.environ.get(name)
        if val:
            return val
    if default is not None:
        return default
    if required:
        raise RuntimeError(
            f"Required environment variable not set. Looked for: {', '.join(names)}. "
            f"Set one of these or fill in broker/.env."
        )
    return ""


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return int(raw)


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class Settings:
    # ----- Saviynt connection ------------------------------------------------
    saviynt_base_url: str
    saviynt_username: str
    saviynt_password: str
    saviynt_verify_tls: bool

    # ----- Saviynt API endpoint paths (configurable) -------------------------
    # Verified against Amsterdam GA in saviynt-config/01-03.
    path_login: str
    path_get_accounts: str
    path_get_ent_details_for_users: str
    path_llt: str
    path_checkout: str
    path_checkin: str
    path_create_request: str
    path_fetch_approval_details: str
    path_get_pending_requests: str
    path_cancel_pending_request: str
    path_create_account: str
    path_update_account: str

    # ----- Saviynt object names this demo expects ----------------------------
    app_name: str
    security_system: str
    entitlement_type: str
    ent_deploy_dev: str
    ent_deploy_prod: str
    pam_endpoint_aws: str
    pam_endpoint_ec2: str
    pam_account_aws_iam: str

    # ----- Demo identity wiring ---------------------------------------------
    # The user that submits createrequest on behalf of the requesting user, and
    # the user used as `userName` for fetchRequestApprovalDetails (i.e., the
    # workflow approver). For demo v1 both default to the SA itself.
    demo_requestor: str
    demo_approver: str

    # ----- NHI custom-property mapping (Saviynt customproperty fields) -------
    cp_owner: str
    cp_environment: str
    cp_application: str
    cp_requester: str
    cp_instance_id: str
    cp_public_ip: str

    # ----- Behavior knobs ----------------------------------------------------
    pam_checkout_ttl_min: int
    pam_max_poll_attempts: int
    pam_poll_interval_secs: int
    approval_poll_timeout: int
    approval_poll_interval: int
    saviynt_request_timeout: int

    # ----- Broker auth (HMAC) ------------------------------------------------
    hmac_secret: str
    hmac_max_skew_seconds: int

    # ----- Server ------------------------------------------------------------
    listen_host: str
    listen_port: int
    log_level: str


def load_settings() -> Settings:
    return Settings(
        # Saviynt connection -------------------------------------------------
        # Each accepts a canonical name OR the legacy name already exported on
        # the Ubuntu host. Canonical wins if both are set.
        saviynt_base_url=_env_first(["SAVIYNT_BASE_URL", "SavURL"], required=True).rstrip("/"),
        saviynt_username=_env_first(["SAVIYNT_USERNAME", "SavAPIUser"], required=True),
        saviynt_password=_env_first(["SAVIYNT_PASSWORD", "SavAPIPass"], required=True),
        saviynt_verify_tls=_env_bool("SAVIYNT_VERIFY_TLS", True),

        # API paths — Amsterdam GA defaults verified against the live tenant
        # via saviynt-config/01-03. Override per-tenant via env when needed.
        path_login=_env("PATH_LOGIN", "/ECM/api/login"),
        path_get_accounts=_env("PATH_GET_ACCOUNTS", "/ECM/api/v5/getAccounts"),
        path_get_ent_details_for_users=_env(
            "PATH_GET_ENT_DETAILS_FOR_USERS", "/ECM/api/v5/getEntDetailsforUsers"
        ),
        path_llt=_env("PATH_LLT", "/ECM/oauth/access_token_withissuer"),
        path_checkout=_env("PATH_CHECKOUT", "/ECMv6/api/pam/account/checkout"),
        path_checkin=_env("PATH_CHECKIN", "/ECMv6/api/pam/account/checkin"),
        path_create_request=_env("PATH_CREATE_REQUEST", "/ECM/api/v5/createrequest"),
        path_fetch_approval_details=_env(
            "PATH_FETCH_APPROVAL_DETAILS", "/ECM/api/v5/fetchRequestApprovalDetails"
        ),
        path_get_pending_requests=_env(
            "PATH_GET_PENDING_REQUESTS", "/ECM/api/v5/getPendingRequests"
        ),
        path_cancel_pending_request=_env(
            "PATH_CANCEL_PENDING_REQUEST", "/ECM/api/v5/cancelPendingRequest"
        ),
        path_create_account=_env("PATH_CREATE_ACCOUNT", "/ECM/api/v5/createAccount"),
        path_update_account=_env("PATH_UPDATE_ACCOUNT", "/ECM/api/v5/updateAccount"),

        # Saviynt object names ----------------------------------------------
        app_name=_env("APP_NAME", "Pulumi-Pipeline-AWS"),
        security_system=_env("SECURITY_SYSTEM", _env("APP_NAME", "Pulumi-Pipeline-AWS")),
        entitlement_type=_env("ENTITLEMENT_TYPE", "Entitlement"),
        ent_deploy_dev=_env("ENT_DEPLOY_DEV", "Deploy-EC2-Dev"),
        ent_deploy_prod=_env("ENT_DEPLOY_PROD", "Deploy-EC2-Prod"),
        pam_endpoint_aws=_env("PAM_ENDPOINT_AWS", "AWS-IAM-Endpoint"),
        pam_endpoint_ec2=_env("PAM_ENDPOINT_EC2", "EC2-Instances-Endpoint"),
        pam_account_aws_iam=_env("PAM_ACCOUNT_AWS_IAM", "pulumi-deployer"),

        # Demo identity wiring ----------------------------------------------
        # Default both to whatever the SA logs in as. Override DEMO_REQUESTOR
        # to log requests under a different broker-side identity, or
        # DEMO_APPROVER to point fetchRequestApprovalDetails at the user
        # who owns the prod approval workflow when it differs from the SA.
        demo_requestor=_env_first(
            ["DEMO_REQUESTOR", "SAVIYNT_USERNAME", "SavAPIUser"], required=True
        ),
        demo_approver=_env_first(
            ["DEMO_APPROVER", "SAVIYNT_USERNAME", "SavAPIUser"], required=True
        ),

        # NHI custom-property mapping ---------------------------------------
        cp_owner=_env("CP_OWNER", "customproperty1"),
        cp_environment=_env("CP_ENVIRONMENT", "customproperty2"),
        cp_application=_env("CP_APPLICATION", "customproperty3"),
        cp_requester=_env("CP_REQUESTER", "customproperty4"),
        cp_instance_id=_env("CP_INSTANCE_ID", "customproperty5"),
        cp_public_ip=_env("CP_PUBLIC_IP", "customproperty6"),

        # Behavior ----------------------------------------------------------
        pam_checkout_ttl_min=_env_int("PAM_CHECKOUT_TTL_MIN", 30),
        pam_max_poll_attempts=_env_int("PAM_MAX_POLL_ATTEMPTS", 30),
        pam_poll_interval_secs=_env_int("PAM_POLL_INTERVAL_SECS", 5),
        approval_poll_timeout=_env_int("APPROVAL_POLL_TIMEOUT", 1800),
        approval_poll_interval=_env_int("APPROVAL_POLL_INTERVAL", 30),
        saviynt_request_timeout=_env_int("SAVIYNT_REQUEST_TIMEOUT", 30),

        # Broker auth -------------------------------------------------------
        hmac_secret=_env("BROKER_HMAC_SECRET", required=True),
        hmac_max_skew_seconds=_env_int("BROKER_HMAC_MAX_SKEW_SECONDS", 300),

        # Server ------------------------------------------------------------
        listen_host=_env("BROKER_LISTEN_HOST", "127.0.0.1"),
        listen_port=_env_int("BROKER_LISTEN_PORT", 18443),
        log_level=_env("BROKER_LOG_LEVEL", "INFO"),
    )


settings = load_settings()
