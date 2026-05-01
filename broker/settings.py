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
    path_login: str
    path_get_accounts: str
    path_get_user: str
    path_check_entitlement: str
    path_llt: str
    path_checkout: str
    path_checkin: str
    path_create_request: str
    path_request_status: str
    path_create_account: str
    path_update_account: str

    # ----- Saviynt object names this demo expects ----------------------------
    app_name: str
    ent_deploy_dev: str
    ent_deploy_prod: str
    pam_endpoint_aws: str
    pam_endpoint_ec2: str
    pam_account_aws_iam: str

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
        saviynt_base_url=_env("SAVIYNT_BASE_URL", required=True).rstrip("/"),
        saviynt_username=_env("SAVIYNT_USERNAME", required=True),
        saviynt_password=_env("SAVIYNT_PASSWORD", required=True),
        saviynt_verify_tls=_env_bool("SAVIYNT_VERIFY_TLS", True),

        # API paths (defaults from validate_secret.py + ARCHITECTURE.md) -----
        path_login=_env("PATH_LOGIN", "/ECM/api/login"),
        path_get_accounts=_env("PATH_GET_ACCOUNTS", "/ECM/api/v5/getAccounts"),
        path_get_user=_env("PATH_GET_USER", "/ECM/api/v5/getUser"),
        path_check_entitlement=_env("PATH_CHECK_ENTITLEMENT", "/ECM/api/v5/checkUserAccess"),
        path_llt=_env("PATH_LLT", "/ECM/oauth/access_token_withissuer"),
        path_checkout=_env("PATH_CHECKOUT", "/ECMv6/api/pam/account/checkout"),
        path_checkin=_env("PATH_CHECKIN", "/ECMv6/api/pam/account/checkin"),
        path_create_request=_env("PATH_CREATE_REQUEST", "/ECM/api/v5/createRequest"),
        path_request_status=_env("PATH_REQUEST_STATUS", "/ECMv6/api/v5/fetchRequestStatus"),
        path_create_account=_env("PATH_CREATE_ACCOUNT", "/ECM/api/v5/createAccount"),
        path_update_account=_env("PATH_UPDATE_ACCOUNT", "/ECM/api/v5/updateAccount"),

        # Saviynt object names ----------------------------------------------
        app_name=_env("APP_NAME", "Pulumi-Pipeline-AWS"),
        ent_deploy_dev=_env("ENT_DEPLOY_DEV", "Deploy-EC2-Dev"),
        ent_deploy_prod=_env("ENT_DEPLOY_PROD", "Deploy-EC2-Prod"),
        pam_endpoint_aws=_env("PAM_ENDPOINT_AWS", "AWS-IAM-Endpoint"),
        pam_endpoint_ec2=_env("PAM_ENDPOINT_EC2", "EC2-Instances-Endpoint"),
        pam_account_aws_iam=_env("PAM_ACCOUNT_AWS_IAM", "pulumi-deployer"),

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
        listen_port=_env_int("BROKER_LISTEN_PORT", 8443),
        log_level=_env("BROKER_LOG_LEVEL", "INFO"),
    )


settings = load_settings()
