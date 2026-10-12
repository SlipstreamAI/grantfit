"""In-memory stand-ins for HTTP and Postgres."""

from __future__ import annotations

from grantfit.models import BudgetDecision, HttpResponse, TransientError


class ScriptedTransport:
    def __init__(self, responses: list[HttpResponse | Exception]) -> None:
        self._responses = list(responses)
        self.calls: list[dict] = []

    def request(self, method, url, headers, json_body) -> HttpResponse:
        self.calls.append({"method": method, "url": url, "headers": dict(headers), "json": json_body})
        item = self._responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


class MemoryGate:
    def __init__(self, budget: int = 100, rate_limit_once: bool = False) -> None:
        self.budget = budget
        self.used = 0
        self.rate_limit_once = rate_limit_once
        self.calls = 0

    def try_consume(self, provider: str, cost: int = 1) -> BudgetDecision:
        self.calls += 1
        if self.rate_limit_once:
            self.rate_limit_once = False
            return BudgetDecision(False, self.budget - self.used, 25, "rate_limited")
        if self.used + cost > self.budget:
            return BudgetDecision(False, max(self.budget - self.used, 0), 0, "budget_exhausted")
        self.used += cost
        return BudgetDecision(True, self.budget - self.used, 0, "ok")


class MemoryStore:
    def __init__(self) -> None:
        self.rows: dict[str, dict] = {}
        self.known: dict[str, str | None] = {}
        self.cache: dict[str, dict] = {}
        self.hits: dict[str, int] = {}
        self.finished = None
        self.high_water = None
        self.runs: list[str] = []

    def start_run(self, provider: str) -> str:
        self.runs.append(provider)
        return "run-1"

    def finish_run(self, run_id, status, requests, inserted, updated, unchanged, skipped, error, detail) -> None:
        self.finished = {
            "run_id": run_id,
            "status": status,
            "requests": requests,
            "inserted": inserted,
            "updated": updated,
            "unchanged": unchanged,
            "skipped": skipped,
            "error": error,
            "detail": detail,
        }

    def fingerprints(self, source: str, external_ids: list[str]) -> dict[str, str | None]:
        return {item: self.known[item] for item in external_ids if item in self.known}

    def upsert(self, rows: list[dict]) -> list[tuple[str, str]]:
        out = []
        for row in rows:
            external_id = row["external_id"]
            action = "inserted" if external_id not in self.rows else "updated"
            self.rows[external_id] = row
            self.known[external_id] = row.get("list_fingerprint")
            out.append((external_id, action))
        return out

    def get_cache(self, key: str) -> dict | None:
        return self.cache.get(key)

    def put_cache(self, key: str, etag: str | None, last_modified: str | None, body_sha256: str) -> None:
        self.cache[key] = {"etag": etag, "last_modified": last_modified, "body_sha256": body_sha256}

    def touch_cache(self, key: str) -> None:
        self.hits[key] = self.hits.get(key, 0) + 1

    def note_high_water(self, provider: str, day: str) -> None:
        self.high_water = day


def http(status: int, body: bytes = b"", headers: dict | None = None) -> HttpResponse:
    return HttpResponse(status, {k.lower(): v for k, v in (headers or {}).items()}, body)


def boom() -> TransientError:
    return TransientError("connection reset")
