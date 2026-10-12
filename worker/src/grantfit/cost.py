"""Retry timing. Daily budgets and the minimum interval live in Postgres."""

from __future__ import annotations

from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

RETRYABLE_STATUSES = frozenset({429, 500, 502, 503, 504})


def backoff_ms(
    attempt: int,
    *,
    base_ms: int = 200,
    cap_ms: int = 8_000,
    retry_after_ms: int | None = None,
    jitter_ms: int = 0,
) -> int:
    """Milliseconds to wait before retry number `attempt` (0 is the first retry).

    A Retry-After value wins over exponential backoff. Both are capped.
    """
    if attempt < 0:
        raise ValueError("attempt must be >= 0")
    if retry_after_ms is not None:
        return min(max(retry_after_ms, 0), cap_ms)
    exp = min(cap_ms, base_ms * (2**attempt))
    return min(cap_ms, exp + max(jitter_ms, 0))


def parse_retry_after(value: str | None, *, now: datetime | None = None) -> int | None:
    """Return Retry-After as milliseconds, or None when the header is absent or junk."""
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    if text.isdigit():
        return int(text) * 1000
    try:
        when = parsedate_to_datetime(text)
    except (TypeError, ValueError, IndexError, OverflowError):
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    current = now or datetime.now(timezone.utc)
    delta_ms = int((when - current).total_seconds() * 1000)
    return max(delta_ms, 0)
