"""Pydantic schemas for broker request/response bodies."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


Environment = Literal["dev", "prod"]


# ============================================================ /preflight
class PreflightRequest(BaseModel):
    requesting_user: str = Field(..., description="Saviynt username initiating the deploy")
    target_env: Environment
    justification: str = Field(
        default="Pulumi pipeline deploy",
        description="Sent to Saviynt when an access request is created",
    )


class PreflightResponse(BaseModel):
    status: Literal["ok", "pending"]
    request_id: str | None = None
    entitlement: str
    message: str


# =================================================== /preflight/status/{id}
class PreflightStatusResponse(BaseModel):
    status: Literal["pending", "approved", "rejected", "unknown"]
    request_id: str


# =========================================================== /checkout-aws
class CheckoutAwsRequest(BaseModel):
    requesting_user: str
    target_env: Environment
    duration_minutes: int | None = None


class CheckoutAwsResponse(BaseModel):
    aws_access_key_id: str
    aws_secret_access_key: str
    account_key: int = Field(
        ..., description="Saviynt account key; pass back to /checkin-aws"
    )
    expires_in_minutes: int


# =========================================================== /register-nhi
class RegisterNhiRequest(BaseModel):
    instance_id: str
    public_ip: str
    target_env: Environment
    requesting_user: str
    owner: str = Field(..., description="Identity owner attached to the new NHI")
    application: str | None = Field(
        default=None, description="Defaults to broker APP_NAME setting"
    )
    os_username: str
    os_password: str
    ssh_private_key: str | None = None


class RegisterNhiResponse(BaseModel):
    account_name: str
    account_key: int | None = None
    endpoint: str
    message: str


# ============================================================ /checkin-aws
class CheckinAwsRequest(BaseModel):
    account_key: int


class CheckinAwsResponse(BaseModel):
    status: Literal["ok"]
    rotation_triggered: bool
    message: str


# ============================================================ generic error
class ErrorResponse(BaseModel):
    error: str
    detail: str | None = None
