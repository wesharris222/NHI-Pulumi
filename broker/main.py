"""
FastAPI app — the Saviynt broker.

Run locally:
    uvicorn broker.main:app --host 127.0.0.1 --port 18443

All five endpoints require HMAC auth via the `require_hmac` dependency.
"""

from __future__ import annotations

import logging
import re

from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.responses import JSONResponse

from .auth import require_hmac
from .models import (
    CheckinAwsRequest,
    CheckinAwsResponse,
    CheckoutAwsRequest,
    CheckoutAwsResponse,
    ErrorResponse,
    PreflightRequest,
    PreflightResponse,
    PreflightStatusResponse,
    RegisterNhiRequest,
    RegisterNhiResponse,
)
from .saviynt_client import SaviyntClient, SaviyntError
from .settings import settings

logging.basicConfig(
    level=settings.log_level,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("broker")

app = FastAPI(
    title="Saviynt Pulumi Broker",
    version="0.1.0",
    description="HMAC-authenticated bridge between GitHub Actions and Saviynt EIC.",
)

_saviynt = SaviyntClient(settings)


def _entitlement_for_env(target_env: str) -> str:
    return settings.ent_deploy_dev if target_env == "dev" else settings.ent_deploy_prod


def _safe_account_name(prefix: str, instance_id: str, env: str) -> str:
    suffix = re.sub(r"[^A-Za-z0-9-]+", "-", instance_id).strip("-")
    return f"{prefix}-{env}-{suffix}"


@app.exception_handler(SaviyntError)
async def saviynt_error_handler(_request, exc: SaviyntError) -> JSONResponse:  # type: ignore[no-untyped-def]
    log.error("SaviyntError: %s (status=%s body=%s)", exc, exc.status, exc.body)
    # Surface Saviynt's own message field in the detail when present, so the
    # caller (operator running curl, or GitHub Actions) sees the real reason
    # without having to read the broker log.
    detail = str(exc)
    if isinstance(exc.body, dict):
        sav_msg = exc.body.get("message") or exc.body.get("errorMessage")
        if sav_msg:
            detail = f"{detail} — {str(sav_msg).strip()}"
    return JSONResponse(
        status_code=status.HTTP_502_BAD_GATEWAY,
        content=ErrorResponse(
            error="saviynt_error",
            detail=detail,
        ).model_dump(),
    )


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Unauthenticated liveness probe."""
    return {"status": "ok"}


# ============================================================ /preflight
@app.post(
    "/preflight",
    response_model=PreflightResponse,
    dependencies=[Depends(require_hmac)],
)
def preflight(req: PreflightRequest) -> PreflightResponse:
    entitlement = _entitlement_for_env(req.target_env)
    log.info(
        "preflight: user=%s env=%s entitlement=%s",
        req.requesting_user,
        req.target_env,
        entitlement,
    )

    has_it = _saviynt.user_has_entitlement(req.requesting_user, entitlement)
    if has_it:
        return PreflightResponse(
            status="ok",
            entitlement=entitlement,
            message=f"User {req.requesting_user} already holds {entitlement}",
        )

    request_id = _saviynt.create_access_request(
        req.requesting_user, entitlement, req.justification
    )
    log.info(
        "preflight: created access request %s for user=%s entitlement=%s",
        request_id,
        req.requesting_user,
        entitlement,
    )
    return PreflightResponse(
        status="pending",
        request_id=request_id,
        entitlement=entitlement,
        message=f"Access request {request_id} opened; awaiting approval",
    )


# ================================================ /preflight/status/{id}
@app.get(
    "/preflight/status/{request_id}",
    response_model=PreflightStatusResponse,
    dependencies=[Depends(require_hmac)],
)
def preflight_status(request_id: str) -> PreflightStatusResponse:
    s = _saviynt.fetch_request_status(request_id)
    return PreflightStatusResponse(status=s, request_id=request_id)


# =========================================================== /checkout-aws
@app.post(
    "/checkout-aws",
    response_model=CheckoutAwsResponse,
    dependencies=[Depends(require_hmac)],
)
def checkout_aws(req: CheckoutAwsRequest) -> CheckoutAwsResponse:
    entitlement = _entitlement_for_env(req.target_env)
    if not _saviynt.user_has_entitlement(req.requesting_user, entitlement):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                f"User {req.requesting_user} does not currently hold {entitlement}; "
                f"call /preflight and wait for approval before checkout"
            ),
        )

    account = _saviynt.get_account(
        settings.pam_account_aws_iam, settings.pam_endpoint_aws
    )
    account_key = SaviyntClient.extract_account_key(account)
    log.info(
        "checkout-aws: user=%s env=%s account=%s accountKey=%s",
        req.requesting_user,
        req.target_env,
        settings.pam_account_aws_iam,
        account_key,
    )

    duration = req.duration_minutes or settings.pam_checkout_ttl_min
    checkout = _saviynt.checkout_credential(account_key, duration_minutes=duration)
    creds = SaviyntClient.parse_checkout_credentials(checkout)

    aws_access_key_id = creds["username"]
    aws_secret_access_key = creds["password"]
    if not aws_access_key_id or not aws_secret_access_key:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="PAM checkout did not return AWS access key id + secret",
        )

    return CheckoutAwsResponse(
        aws_access_key_id=aws_access_key_id,
        aws_secret_access_key=aws_secret_access_key,
        account_key=account_key,
        expires_in_minutes=duration,
    )


# =========================================================== /register-nhi
@app.post(
    "/register-nhi",
    response_model=RegisterNhiResponse,
    dependencies=[Depends(require_hmac)],
)
def register_nhi(req: RegisterNhiRequest) -> RegisterNhiResponse:
    application = req.application or settings.app_name
    account_name = _safe_account_name("ec2-nhi", req.instance_id, req.target_env)

    log.info(
        "register-nhi: instance=%s env=%s owner=%s account_name=%s",
        req.instance_id,
        req.target_env,
        req.owner,
        account_name,
    )

    resp = _saviynt.create_nhi_account(
        account_name=account_name,
        endpoint=settings.pam_endpoint_ec2,
        owner=req.owner,
        environment=req.target_env,
        application=application,
        requester=req.requesting_user,
        instance_id=req.instance_id,
        public_ip=req.public_ip,
        username=req.os_username,
        password=req.os_password,
        ssh_private_key=req.ssh_private_key,
    )

    account_key: int | None = None
    for key in ("accountkey", "accountKey", "ACCOUNTKEY"):
        val = resp.get(key) if isinstance(resp, dict) else None
        if val is not None:
            try:
                account_key = int(val)
                break
            except (ValueError, TypeError):
                continue

    return RegisterNhiResponse(
        account_name=account_name,
        account_key=account_key,
        endpoint=settings.pam_endpoint_ec2,
        message=f"NHI {account_name} registered on endpoint {settings.pam_endpoint_ec2}",
    )


# ============================================================ /checkin-aws
@app.post(
    "/checkin-aws",
    response_model=CheckinAwsResponse,
    dependencies=[Depends(require_hmac)],
)
def checkin_aws(req: CheckinAwsRequest) -> CheckinAwsResponse:
    log.info("checkin-aws: accountKey=%s", req.account_key)
    _saviynt.checkin_credential(req.account_key)
    return CheckinAwsResponse(
        status="ok",
        rotation_triggered=True,
        message=f"Credential for accountKey={req.account_key} checked in; Saviynt rotation policy will fire",
    )
