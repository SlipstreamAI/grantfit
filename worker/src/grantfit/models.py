"""Shared records for the sync worker."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class BudgetDecision:
    allowed: bool
    remaining: int
    retry_after_ms: int
    reason: str


@dataclass
class HttpResponse:
    status: int
    headers: dict[str, str]
    body: bytes


@dataclass(frozen=True)
class RequestSpec:
    method: str
    url: str
    json_body: dict | None
    cache_key: str
    headers: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class FetchResult:
    not_modified: bool
    body: bytes
    status: int


@dataclass
class SyncStats:
    status: str = "running"
    requests_made: int = 0
    inserted: int = 0
    updated: int = 0
    unchanged: int = 0
    skipped: int = 0
    deferred: int = 0
    cache_hits: int = 0
    error: str | None = None

    def as_dict(self) -> dict:
        return {
            "status": self.status,
            "requests_made": self.requests_made,
            "inserted": self.inserted,
            "updated": self.updated,
            "unchanged": self.unchanged,
            "skipped": self.skipped,
            "deferred": self.deferred,
            "cache_hits": self.cache_hits,
            "error": self.error,
        }


class BudgetExhausted(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class HttpStatusError(Exception):
    def __init__(self, status: int, body: bytes) -> None:
        super().__init__(f"HTTP {status}")
        self.status = status
        self.body = body


class TransientError(Exception):
    """Network failure worth retrying."""


class ProviderError(Exception):
    """The origin returned a payload the provider will not retry."""


class RateLimitStuck(Exception):
    """The shared interval never cleared."""
