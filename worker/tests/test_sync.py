import json
from pathlib import Path

from grantfit.providers.grants_gov import GrantsGovProvider
from grantfit.sync import run_sync

from fakes import MemoryGate, MemoryStore, ScriptedTransport, http

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "grants_gov"


def _search_one() -> bytes:
    payload = json.loads((FIXTURES / "search_scholarship.json").read_text())
    payload["data"]["oppHits"] = payload["data"]["oppHits"][:1]
    return json.dumps(payload).encode()


def _detail() -> bytes:
    return (FIXTURES / "opportunity_361238.json").read_bytes()


def _run(responses, store=None, gate=None, **opts):
    store = store or MemoryStore()
    gate = gate or MemoryGate()
    from grantfit.http import BudgetedClient

    client = BudgetedClient(ScriptedTransport(responses), gate, provider="grants_gov", sleeper=lambda _s: None)
    stats = run_sync(
        store,
        client,
        GrantsGovProvider(),
        keyword="scholarship",
        rows=opts.get("rows", 25),
        max_pages=1,
        refresh_details=opts.get("refresh_details", False),
    )
    return stats, store, client


def test_sync_fetches_a_detail_and_upserts_it():
    stats, store, client = _run([http(200, _search_one()), http(200, _detail())])
    assert stats.status == "success"
    assert stats.inserted == 1
    assert stats.requests_made == 2
    row = store.rows["361238"]
    assert row["kind"] == "grant"
    assert row["eligible_applicants"] == ["nonprofit", "university"]
    assert store.high_water == "2026-02-04"
    assert store.finished["status"] == "success"
    assert client.requests_made == 2


def test_known_fingerprint_skips_the_detail_request():
    store = MemoryStore()
    first, store, _client = _run([http(200, _search_one()), http(200, _detail())], store)
    assert first.inserted == 1
    store.cache.clear()
    stats, store, client = _run([http(200, _search_one())], store)
    assert stats.skipped == 1
    assert stats.inserted == 0
    assert client.requests_made == 1


def test_budget_stops_before_the_detail_and_does_not_upsert():
    stats, store, _client = _run(
        [http(200, _search_one()), http(200, _detail())],
        gate=MemoryGate(budget=1),
    )
    assert stats.status == "budget_stopped"
    assert stats.deferred == 1
    assert store.rows == {}
    assert store.finished["status"] == "budget_stopped"


def test_304_search_does_not_upsert():
    store = MemoryStore()
    body = _search_one()
    from grantfit.http import body_sha256, cache_key
    from grantfit.providers.grants_gov import SEARCH_URL

    key = cache_key("POST", SEARCH_URL, {
        "rows": 25,
        "keyword": "scholarship",
        "oppStatuses": "forecasted|posted",
        "startRecordNum": 0,
    })
    store.cache[key] = {"etag": '"page"', "last_modified": None, "body_sha256": body_sha256(body)}
    stats, store, client = _run([http(304, b"", {"etag": '"page"'})], store)
    assert stats.cache_hits == 1
    assert stats.inserted == 0
    assert client.requests_made == 1
    assert store.rows == {}
