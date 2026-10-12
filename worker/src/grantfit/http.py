"""Budgeted HTTP client: per-run cap, shared gate, retry, conditional cache."""

from __future__ import annotations

import hashlib
import json
import random
from typing import Callable, Protocol

import httpx

from grantfit.cost import RETRYABLE_STATUSES, backoff_ms, parse_retry_after
from grantfit.models import (
    BudgetDecision,
    BudgetExhausted,
    FetchResult,
    HttpResponse,
    HttpStatusError,
    RateLimitStuck,
    RequestSpec,
    TransientError,
)

USER_AGENT = "GrantFitDemo/1.0 (portfolio; local sync)"


class Transport(Protocol):
    def request(self, method: str, url: str, headers: dict[str, str], json_body: dict | None) -> HttpResponse:
        ...


class BudgetGate(Protocol):
    def try_consume(self, provider: str, cost: int = 1) -> BudgetDecision:
        ...


class CacheStore(Protocol):
    def get_cache(self, key: str) -> dict | None:
        ...

    def put_cache(self, key: str, etag: str | None, last_modified: str | None, body_sha256: str) -> None:
        ...

    def touch_cache(self, key: str) -> None:
        ...


class HttpxTransport:
    def __init__(self, timeout: float = 20.0) -> None:
        self._client = httpx.Client(timeout=timeout, follow_redirects=True)

    def request(self, method: str, url: str, headers: dict[str, str], json_body: dict | None) -> HttpResponse:
        try:
            response = self._client.request(method, url, headers=headers, json=json_body)
        except httpx.HTTPError as exc:
            raise TransientError(str(exc)) from exc
        return HttpResponse(
            status=response.status_code,
            headers={key.lower(): value for key, value in response.headers.items()},
            body=response.content,
        )

    def close(self) -> None:
        self._client.close()


class BudgetedClient:
    def __init__(
        self,
        transport: Transport,
        gate: BudgetGate,
        *,
        provider: str,
        sleeper: Callable[[float], None] = lambda _seconds: None,
        rng: random.Random | None = None,
        max_attempts: int = 4,
        max_requests: int | None = None,
        user_agent: str = USER_AGENT,
        on_request: Callable[[str, str], None] | None = None,
    ) -> None:
        self.transport = transport
        self.gate = gate
        self.provider = provider
        self.sleeper = sleeper
        self.rng = rng or random.Random(0)
        self.max_attempts = max_attempts
        self.max_requests = max_requests
        self.user_agent = user_agent
        self.on_request = on_request
        self.requests_made = 0

    def request(self, spec: RequestSpec) -> HttpResponse:
        headers = {
            "Accept": "application/json",
            "User-Agent": self.user_agent,
            **spec.headers,
        }
        if spec.json_body is not None:
            headers.setdefault("Content-Type", "application/json")

        last_error: Exception | None = None
        for attempt in range(self.max_attempts):
            self._acquire()
            self.requests_made += 1
            if self.on_request:
                self.on_request(spec.method, spec.url)
            try:
                response = self.transport.request(spec.method, spec.url, headers, spec.json_body)
            except TransientError as exc:
                last_error = exc
                if attempt == self.max_attempts - 1:
                    raise
                self._sleep_for_retry(attempt, None)
                continue

            if response.status == 304 or 200 <= response.status < 300:
                return response
            if response.status in RETRYABLE_STATUSES and attempt < self.max_attempts - 1:
                self._sleep_for_retry(attempt, response)
                continue
            raise HttpStatusError(response.status, response.body)

        if last_error:
            raise last_error
        raise HttpStatusError(0, b"")

    def _acquire(self) -> None:
        if self.max_requests is not None and self.requests_made >= self.max_requests:
            raise BudgetExhausted("run_cap")
        for _ in range(6):
            decision = self.gate.try_consume(self.provider, 1)
            if decision.allowed:
                return
            if decision.reason == "budget_exhausted":
                raise BudgetExhausted("budget_exhausted")
            if decision.reason == "rate_limited":
                self.sleeper(max(decision.retry_after_ms, 0) / 1000)
                continue
            raise BudgetExhausted(decision.reason or "denied")
        raise RateLimitStuck(self.provider)

    def _sleep_for_retry(self, attempt: int, response: HttpResponse | None) -> None:
        header = response.headers.get("retry-after") if response else None
        retry_after = parse_retry_after(header)
        jitter = 0 if retry_after is not None else self.rng.randrange(0, 50)
        delay = backoff_ms(attempt, retry_after_ms=retry_after, jitter_ms=jitter)
        self.sleeper(delay / 1000)


def cache_key(method: str, url: str, body: dict | None) -> str:
    raw = json.dumps(body, sort_keys=True, separators=(",", ":")) if body is not None else ""
    return hashlib.sha256(f"{method}\n{url}\n{raw}".encode()).hexdigest()


def body_sha256(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def cached_request(client: BudgetedClient, store: CacheStore, spec: RequestSpec) -> FetchResult:
    cached = store.get_cache(spec.cache_key)
    headers = dict(spec.headers)
    if cached and cached.get("etag"):
        headers["If-None-Match"] = cached["etag"]
    if cached and cached.get("last_modified"):
        headers["If-Modified-Since"] = cached["last_modified"]
    response = client.request(RequestSpec(spec.method, spec.url, spec.json_body, spec.cache_key, headers))
    if response.status == 304:
        store.touch_cache(spec.cache_key)
        return FetchResult(True, b"", 304)
    digest = body_sha256(response.body)
    if cached and cached.get("body_sha256") == digest:
        store.put_cache(spec.cache_key, response.headers.get("etag"), response.headers.get("last-modified"), digest)
        return FetchResult(True, response.body, response.status)
    store.put_cache(spec.cache_key, response.headers.get("etag"), response.headers.get("last-modified"), digest)
    return FetchResult(False, response.body, response.status)
