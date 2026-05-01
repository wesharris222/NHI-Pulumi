"""
HMAC request authentication.

Every inbound request must carry:
  X-Broker-Timestamp:  unix epoch seconds (string)
  X-Broker-Nonce:      caller-supplied unique value (replay-protection token)
  X-Broker-Signature:  hex(hmac_sha256(secret, "{timestamp}.{nonce}.{body}"))

The signature is computed over the *raw* request body so server-side JSON
re-serialization can't break it.

Replay window: ±BROKER_HMAC_MAX_SKEW_SECONDS (default 300s).
Nonce reuse: rejected within the replay window via an in-memory cache.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import threading
import time

from fastapi import Header, HTTPException, Request, status

from .settings import settings

log = logging.getLogger(__name__)


class _NonceCache:
    """Tiny LRU-ish cache of recent nonces. In-memory; per-process is fine
    for a single-instance broker. For HA, swap for Redis."""

    def __init__(self, ttl_seconds: int):
        self._ttl = ttl_seconds
        self._seen: dict[str, float] = {}
        self._lock = threading.Lock()

    def check_and_remember(self, nonce: str) -> bool:
        now = time.time()
        with self._lock:
            self._evict(now)
            if nonce in self._seen:
                return False
            self._seen[nonce] = now
            return True

    def _evict(self, now: float) -> None:
        cutoff = now - self._ttl
        stale = [k for k, ts in self._seen.items() if ts < cutoff]
        for k in stale:
            self._seen.pop(k, None)


_nonce_cache = _NonceCache(ttl_seconds=settings.hmac_max_skew_seconds * 2)


def _expected_signature(timestamp: str, nonce: str, body: bytes) -> str:
    msg = b".".join([timestamp.encode("utf-8"), nonce.encode("utf-8"), body])
    return hmac.new(
        settings.hmac_secret.encode("utf-8"),
        msg,
        hashlib.sha256,
    ).hexdigest()


async def require_hmac(
    request: Request,
    x_broker_timestamp: str = Header(..., alias="X-Broker-Timestamp"),
    x_broker_nonce: str = Header(..., alias="X-Broker-Nonce"),
    x_broker_signature: str = Header(..., alias="X-Broker-Signature"),
) -> None:
    """FastAPI dependency. Raises 401 on any auth failure."""
    # Timestamp window check
    try:
        ts = int(x_broker_timestamp)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid X-Broker-Timestamp",
        )
    skew = abs(time.time() - ts)
    if skew > settings.hmac_max_skew_seconds:
        log.warning(
            "HMAC timestamp skew too large: %ds (max %ds) from %s",
            int(skew),
            settings.hmac_max_skew_seconds,
            request.client.host if request.client else "unknown",
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Request timestamp outside allowed skew",
        )

    # Body-bound signature
    body = await request.body()
    expected = _expected_signature(x_broker_timestamp, x_broker_nonce, body)
    if not hmac.compare_digest(expected, x_broker_signature):
        log.warning(
            "HMAC signature mismatch from %s for %s %s",
            request.client.host if request.client else "unknown",
            request.method,
            request.url.path,
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid signature",
        )

    # Replay protection
    if not _nonce_cache.check_and_remember(x_broker_nonce):
        log.warning("HMAC nonce reuse detected from %s",
                    request.client.host if request.client else "unknown")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Nonce already used",
        )
