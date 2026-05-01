"""
Saviynt EIC API client.

Wraps the Saviynt REST flows the broker needs. Amsterdam GA contracts are
verified in saviynt-config/01-application-onboarding.md,
saviynt-config/02-entitlements.md, and saviynt-config/03-roles-and-users.md.

Flows:
  - login (returns access_token + refresh_token)
  - get_account -> accountkey resolution (PAM checkout setup)
  - generate_llt -> long-lasting token for PAM checkout
  - checkout -> retrieves a PAM-vaulted credential (poll on TASK_NOT_FOUND)
  - checkin -> returns credential, triggers rotation
  - user_has_entitlement -> getEntDetailsforUsers (GET with JSON body);
      true iff errorCode=="0" and accessDetails non-empty
  - create_access_request -> createrequest (POST); entitlement is a string,
      requestor is the broker SA, beneficiary is `username`
  - fetch_request_status -> fetchRequestApprovalDetails (POST);
      returns pending|approved|rejected|unknown
  - create_nhi_account -> registers a new NHI in Saviynt PAM

Auth state (access_token + refresh_token) is cached on the instance and
refreshed on 401.
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Any

import requests

from .settings import Settings

log = logging.getLogger(__name__)


class SaviyntError(Exception):
    """Raised when Saviynt returns an error or the client cannot proceed."""

    def __init__(self, message: str, *, status: int | None = None, body: Any = None):
        super().__init__(message)
        self.status = status
        self.body = body


class SaviyntClient:
    def __init__(self, settings: Settings):
        self._settings = settings
        self._session = requests.Session()
        self._session.verify = settings.saviynt_verify_tls
        self._access_token: str | None = None
        self._refresh_token: str | None = None
        self._lock = threading.Lock()

    # ------------------------------------------------------------------ utils
    def _url(self, path: str) -> str:
        return f"{self._settings.saviynt_base_url}{path}"

    def _bearer(self, token: str | None = None) -> dict[str, str]:
        return {"Authorization": f"Bearer {token or self._access_token}"}

    def _post_json(
        self,
        path: str,
        payload: dict[str, Any],
        *,
        token: str | None = None,
        retry_on_401: bool = True,
        extra_headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        return self._request(
            "POST",
            path,
            json_body=payload,
            token=token,
            retry_on_401=retry_on_401,
            extra_headers=extra_headers,
        )

    def _post_form(
        self, path: str, form: dict[str, Any], *, token: str | None = None
    ) -> dict[str, Any]:
        return self._request("POST", path, form_body=form, token=token, retry_on_401=False)

    def _get_json(
        self,
        path: str,
        params: dict[str, Any] | None = None,
        *,
        token: str | None = None,
        retry_on_401: bool = True,
    ) -> dict[str, Any]:
        return self._request("GET", path, params=params, token=token, retry_on_401=retry_on_401)

    def _request(
        self,
        method: str,
        path: str,
        *,
        json_body: dict[str, Any] | None = None,
        form_body: dict[str, Any] | None = None,
        params: dict[str, Any] | None = None,
        token: str | None = None,
        retry_on_401: bool = True,
        extra_headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        url = self._url(path)
        effective_token = token if token is not None else self._access_token
        headers: dict[str, str] = {}
        if effective_token:
            headers["Authorization"] = f"Bearer {effective_token}"
        if extra_headers:
            headers.update(extra_headers)

        try:
            resp = self._session.request(
                method,
                url,
                json=json_body,
                data=form_body,
                params=params,
                headers=headers,
                timeout=self._settings.saviynt_request_timeout,
            )
        except requests.RequestException as e:
            raise SaviyntError(
                f"Saviynt {method} {path} unreachable: {e}",
            ) from e

        if resp.status_code == 401 and retry_on_401 and token is None:
            log.info("Saviynt returned 401; refreshing session and retrying once")
            self._access_token = None
            self._refresh_token = None
            self.login()
            return self._request(
                method,
                path,
                json_body=json_body,
                form_body=form_body,
                params=params,
                retry_on_401=False,
            )

        try:
            data = resp.json()
        except ValueError:
            data = {"raw": resp.text}

        if not resp.ok:
            raise SaviyntError(
                f"Saviynt {method} {path} -> HTTP {resp.status_code}",
                status=resp.status_code,
                body=data,
            )

        return data

    # ------------------------------------------------------------------ auth
    def login(self) -> str:
        """Authenticate and cache access + refresh tokens. Returns access token."""
        with self._lock:
            payload = {
                "username": self._settings.saviynt_username,
                "password": self._settings.saviynt_password,
            }
            try:
                resp = self._session.post(
                    self._url(self._settings.path_login),
                    json=payload,
                    timeout=self._settings.saviynt_request_timeout,
                )
            except requests.RequestException as e:
                raise SaviyntError(f"Saviynt login unreachable: {e}") from e
            try:
                data = resp.json()
            except ValueError:
                data = {"raw": resp.text}
            if not resp.ok:
                raise SaviyntError(
                    f"Saviynt login failed: HTTP {resp.status_code}",
                    status=resp.status_code,
                    body=data,
                )

            access = data.get("access_token") or data.get("token")
            refresh = data.get("refresh_token")
            if not refresh:
                result = data.get("result")
                if isinstance(result, dict):
                    refresh = result.get("refresh_token")

            if not access:
                raise SaviyntError("Saviynt login response did not contain access_token", body=data)

            self._access_token = access
            self._refresh_token = refresh
            log.info("Saviynt login OK (refresh_token present=%s)", bool(refresh))
            return access

    def _ensure_logged_in(self) -> None:
        if not self._access_token:
            self.login()

    # ------------------------------------------------------------------ accounts
    def get_account(self, account_name: str, endpoint: str) -> dict[str, Any]:
        """Look up a single account by exact name on a PAM endpoint."""
        self._ensure_logged_in()
        payload = {
            "endpoint": endpoint,
            "advsearchcriteria": {"name": account_name},
            "max": 1,
            "offset": 0,
        }
        resp = self._post_json(self._settings.path_get_accounts, payload)
        accounts = self._extract_accounts(resp)
        if not accounts:
            raise SaviyntError(
                f"No account '{account_name}' found on endpoint '{endpoint}'",
                body=resp,
            )
        # If multiple, prefer exact name match
        for acct in accounts:
            if acct.get("name") == account_name:
                return acct
        return accounts[0]

    @staticmethod
    def _extract_accounts(resp: dict[str, Any]) -> list[dict[str, Any]]:
        if isinstance(resp, list):
            return resp
        for key in ("Accountdetails", "accountdetails", "accounts", "value"):
            val = resp.get(key)
            if isinstance(val, list):
                return val
            if isinstance(val, dict):
                return [val]
        return []

    @staticmethod
    def extract_account_key(acct: dict[str, Any]) -> int:
        for key in ("accountkey", "accountKey", "ACCOUNTKEY", "userAccountId"):
            val = acct.get(key)
            if val is None:
                continue
            try:
                return int(val)
            except (ValueError, TypeError):
                continue
        raise SaviyntError(
            f"Could not resolve accountkey from account record. "
            f"Available keys: {sorted(acct.keys())}"
        )

    # ------------------------------------------------------------------ entitlement
    def user_has_entitlement(self, username: str, entitlement_name: str) -> bool:
        """
        True iff the user currently holds the entitlement on the configured
        endpoint.

        Calls getEntDetailsforUsers (Amsterdam GA). The endpoint is HTTP GET
        but accepts a JSON body — Saviynt convention. The response is a
        flat `accessDetails[]` list; one or more matching records means the
        user holds the entitlement.

        Verified contract: saviynt-config/03-roles-and-users.md §C.5.
        """
        self._ensure_logged_in()
        s = self._settings
        payload = {
            "username": username,
            "endpoint": s.app_name,
            "entitlementType": s.entitlement_type,
            "entitlement_value": entitlement_name,
        }
        resp = self._request(
            "GET",
            s.path_get_ent_details_for_users,
            json_body=payload,
        )
        if str(resp.get("errorCode", "")).strip() != "0":
            return False
        details = resp.get("accessDetails") or []
        return bool(details)

    # ------------------------------------------------------------------ access requests
    def create_access_request(
        self,
        username: str,
        entitlement_name: str,
        justification: str,
        *,
        requestor: str | None = None,
    ) -> str:
        """
        Open an entitlement-add request via /ECM/api/v5/createrequest
        (Saviynt EIC Amsterdam GA).

        Verified payload shape (saviynt-config/02-entitlements.md §B.5):
          requesttype:    "ADD"
          username:       beneficiary (who's getting the entitlement)
          endpoint:       application/endpoint name (= APP_NAME)
          securitysystem: top-level security system (often == endpoint name)
          entitlement:    plain string, NOT an array of objects
          comments:       justification text
          requestor:      submitter (the broker SA, e.g. igaadmin)
          checksod:       "false" for v1; flip when an SoD ruleset is in place

        Response: {msg, requestkey, errorCode}. We return requestkey — that
        same value is what fetchRequestApprovalDetails wants as `requestKey`.
        """
        self._ensure_logged_in()
        s = self._settings
        payload = {
            "requesttype": "ADD",
            "username": username,
            "endpoint": s.app_name,
            "securitysystem": s.security_system,
            "entitlement": entitlement_name,
            "comments": justification,
            "requestor": requestor or s.demo_requestor,
            "checksod": "false",
        }
        resp = self._post_json(s.path_create_request, payload)

        error_code = str(resp.get("errorCode", "")).strip()
        if error_code and error_code != "0":
            raise SaviyntError(
                f"createrequest returned errorCode={error_code}", body=resp
            )

        request_id = (
            resp.get("requestkey")
            or resp.get("requestid")
            or resp.get("RequestId")
            or resp.get("requestId")
        )
        if not request_id:
            raise SaviyntError("createrequest did not return a request key", body=resp)
        return str(request_id)

    def fetch_request_status(
        self, request_id: str, *, approver_username: str | None = None
    ) -> str:
        """
        Poll a request's overall approval status. Returns one of:
        pending, approved, rejected, unknown.

        Calls fetchRequestApprovalDetails (Amsterdam GA, POST). The response
        is nested:
          ApprovalRequestDetails.AccessRequestDetails[].modifyTasks[].approvalstatus
          ApprovalRequestDetails.AccessRequestDetails[].tasksList[].approvalstatus

        Aggregation rule:
          - any task REJECTED/DENIED  -> rejected
          - all tasks APPROVED/COMPLETE -> approved
          - otherwise (PENDING / "Task Created" / "Approval In Progress" / etc.)
            -> pending

        Verified contract: saviynt-config/02-entitlements.md §B.5
        ("Verify request status").
        """
        self._ensure_logged_in()
        s = self._settings
        payload = {
            "requestKey": str(request_id),
            "userName": approver_username or s.demo_approver,
        }
        resp = self._post_json(s.path_fetch_approval_details, payload)
        statuses = self._extract_approval_statuses(resp)
        if not statuses:
            return "unknown"

        upper = [val.upper() for val in statuses]
        if any(u in ("REJECTED", "DENIED", "DECLINED") for u in upper):
            return "rejected"
        if all(u in ("APPROVED", "COMPLETED", "COMPLETE") for u in upper):
            return "approved"
        return "pending"

    def get_pending_requests(
        self, approver_username: str | None = None, *, max_results: int = 50
    ) -> dict[str, Any]:
        """
        List pending requests in the approver's queue.

        Verified contract (saviynt-config/03-roles-and-users.md §C.7 + IGA
        briefing): the SAVUSERNAME header is REQUIRED — without it the call
        returns empty silently.
        """
        self._ensure_logged_in()
        s = self._settings
        approver = approver_username or s.demo_approver
        return self._post_json(
            s.path_get_pending_requests,
            {"max": str(max_results)},
            extra_headers={"SAVUSERNAME": approver},
        )

    def cancel_pending_request(
        self,
        request_key: str,
        *,
        comments: str = "Cancelled by broker (demo reset)",
        requestor: str | None = None,
    ) -> dict[str, Any]:
        """
        Cancel a still-pending request. Used by the demo-reset path between
        runs. Has no effect on already-granted entitlements.
        """
        self._ensure_logged_in()
        s = self._settings
        payload = {
            "requestor": requestor or s.demo_requestor,
            "requestkey": str(request_key),
            "comments": comments,
        }
        return self._post_json(s.path_cancel_pending_request, payload)

    @staticmethod
    def _extract_approval_statuses(resp: Any) -> list[str]:
        """Pull approvalstatus values from Amsterdam's nested response shape."""
        out: list[str] = []
        if not isinstance(resp, dict):
            return out
        ard = resp.get("ApprovalRequestDetails") or resp.get("approvalRequestDetails")
        if not isinstance(ard, dict):
            return out
        ar = ard.get("AccessRequestDetails") or ard.get("accessRequestDetails") or []
        if isinstance(ar, dict):
            ar = [ar]
        if not isinstance(ar, list):
            return out
        for entry in ar:
            if not isinstance(entry, dict):
                continue
            for tasks_key in ("modifyTasks", "tasksList", "tasks"):
                tasks = entry.get(tasks_key)
                if not isinstance(tasks, list):
                    continue
                for task in tasks:
                    if not isinstance(task, dict):
                        continue
                    status = task.get("approvalstatus") or task.get("approvalStatus")
                    if status:
                        out.append(str(status))
        return out

    # ------------------------------------------------------------------ PAM checkout/in
    def generate_llt(self, account_key: int) -> str:
        """Generate the Long-Lasting Token used for PAM checkout."""
        self._ensure_logged_in()
        if not self._refresh_token:
            # Force a login that includes refresh_token
            self.login()
            if not self._refresh_token:
                raise SaviyntError(
                    "Saviynt did not return a refresh_token; cannot generate LLT. "
                    "Confirm the broker SA permits refresh-token issuance."
                )

        form = {
            "grant_type": "refresh_token",
            "refresh_token": self._refresh_token,
            "accountId": str(account_key),
        }
        resp = self._post_form(self._settings.path_llt, form)
        llt = resp.get("access_token")
        if not llt:
            result = resp.get("result")
            if isinstance(result, dict):
                llt = result.get("access_token")
        if not llt:
            raise SaviyntError("LLT response did not contain access_token", body=resp)
        return llt

    def checkout_credential(
        self, account_key: int, *, duration_minutes: int | None = None
    ) -> dict[str, Any]:
        """
        Checkout a credential from PAM. Polls TASK_NOT_FOUND_OR_NOT_COMPLETED
        until the credential is ready or attempts are exhausted.

        Returns the raw checkout response (caller pulls username/password/etc.).
        """
        s = self._settings
        duration = duration_minutes or s.pam_checkout_ttl_min
        llt = self.generate_llt(account_key)
        url = self._url(s.path_checkout)
        headers = {
            "Authorization": f"Bearer {llt}",
            "Content-Type": "application/json",
        }
        payload = {"accountId": int(account_key), "duration": duration}

        last_body: Any = None
        for attempt in range(1, s.pam_max_poll_attempts + 1):
            try:
                resp = self._session.post(
                    url, json=payload, headers=headers, timeout=s.saviynt_request_timeout
                )
            except requests.RequestException as e:
                raise SaviyntError(f"PAM checkout unreachable: {e}") from e
            try:
                data = resp.json()
            except ValueError:
                data = {"raw": resp.text}
            last_body = data

            if resp.ok:
                log.info("PAM checkout OK on attempt %d for accountKey=%s", attempt, account_key)
                return data

            detail_blob = ""
            if isinstance(data, dict):
                detail_blob = " ".join(
                    str(v) for v in (data.get("error"), data.get("detail"), data.get("message"))
                    if v
                )
            if "TASK_NOT_FOUND_OR_NOT_COMPLETED" in detail_blob:
                log.info(
                    "PAM checkout polling (%d/%d): task not ready",
                    attempt,
                    s.pam_max_poll_attempts,
                )
                time.sleep(s.pam_poll_interval_secs)
                continue

            raise SaviyntError(
                f"PAM checkout failed: HTTP {resp.status_code}",
                status=resp.status_code,
                body=data,
            )

        raise SaviyntError(
            "PAM checkout did not complete within polling window",
            body=last_body,
        )

    def checkin_credential(self, account_key: int) -> dict[str, Any]:
        """Check the credential back in. Saviynt rotation policy fires from here."""
        self._ensure_logged_in()
        llt = self.generate_llt(account_key)
        return self._post_json(
            self._settings.path_checkin,
            {"accountId": int(account_key)},
            token=llt,
            retry_on_401=False,
        )

    @staticmethod
    def parse_checkout_credentials(checkout_resp: dict[str, Any]) -> dict[str, str | None]:
        """Pull username + password out of a checkout response, handling Saviynt's variants."""
        def _str_or_value(v: Any) -> str | None:
            if v is None:
                return None
            if isinstance(v, str):
                return v
            if isinstance(v, dict):
                return v.get("value")
            return str(v)

        password = _str_or_value(checkout_resp.get("password"))
        if password is None:
            password = _str_or_value(checkout_resp.get("credential"))

        username = _str_or_value(checkout_resp.get("userName"))
        if username is None:
            username = checkout_resp.get("accountName")

        return {"username": username, "password": password}

    # ------------------------------------------------------------------ NHI registration
    def create_nhi_account(
        self,
        *,
        account_name: str,
        endpoint: str,
        owner: str,
        environment: str,
        application: str,
        requester: str,
        instance_id: str,
        public_ip: str,
        username: str,
        password: str,
        ssh_private_key: str | None = None,
    ) -> dict[str, Any]:
        """
        Register a new NHI account in Saviynt PAM with full ownership metadata.

        Returns the raw createAccount response (the broker route extracts the
        account key from it).
        """
        self._ensure_logged_in()
        s = self._settings

        # Stash the SSH private key in the description so the demo has somewhere
        # human-readable to find it. The vaulted secret is the OS password (and
        # the key, on tenants that support multi-secret accounts).
        description_lines = [
            f"NHI registered by Pulumi pipeline run.",
            f"Owner: {owner}",
            f"Environment: {environment}",
            f"Application: {application}",
            f"Requester: {requester}",
            f"EC2 instance_id: {instance_id}",
            f"EC2 public_ip: {public_ip}",
        ]
        payload: dict[str, Any] = {
            "endpoint": endpoint,
            "name": account_name,
            "displayName": account_name,
            "accountType": "NHI",
            "description": "\n".join(description_lines),
            "userName": username,
            "password": password,
            s.cp_owner: owner,
            s.cp_environment: environment,
            s.cp_application: application,
            s.cp_requester: requester,
            s.cp_instance_id: instance_id,
            s.cp_public_ip: public_ip,
        }
        if ssh_private_key:
            # Some Saviynt deployments accept additional credential payloads.
            payload["sshPrivateKey"] = ssh_private_key

        return self._post_json(s.path_create_account, payload)
