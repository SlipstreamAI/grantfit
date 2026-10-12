from grantfit.http import BudgetedClient, body_sha256, cached_request
from grantfit.models import BudgetExhausted, HttpStatusError

from fakes import MemoryGate, MemoryStore, ScriptedTransport, boom, http


def _client(transport, gate=None, **kwargs):
    return BudgetedClient(
        transport,
        gate or MemoryGate(),
        provider="grants_gov",
        sleeper=kwargs.pop("sleeper", lambda _s: None),
        **kwargs,
    )


def test_retries_429_using_retry_after_then_succeeds():
    slept = []
    transport = ScriptedTransport([
        http(429, b"slow", {"Retry-After": "1"}),
        http(200, b'{"ok":true}'),
    ])
    client = _client(transport, sleeper=slept.append)
    response = client.request(_spec())
    assert response.status == 200
    assert slept == [1.0]
    assert client.requests_made == 2
    assert len(transport.calls) == 2


def test_retries_transient_then_500_then_succeeds():
    transport = ScriptedTransport([
        boom(),
        http(503, b"unavailable"),
        http(200, b"ok"),
    ])
    slept = []
    client = _client(transport, sleeper=slept.append)
    response = client.request(_spec())
    assert response.body == b"ok"
    assert len(slept) == 2
    assert client.requests_made == 3


def test_does_not_retry_client_errors():
    transport = ScriptedTransport([http(400, b"bad"), http(200, b"should-not-run")])
    client = _client(transport)
    try:
        client.request(_spec())
    except HttpStatusError as exc:
        assert exc.status == 400
    else:
        raise AssertionError("expected HTTP 400")
    assert len(transport.calls) == 1


def test_run_cap_does_not_call_the_network():
    transport = ScriptedTransport([http(200, b"ok")])
    client = _client(transport, max_requests=0)
    try:
        client.request(_spec())
    except BudgetExhausted as exc:
        assert exc.reason == "run_cap"
    else:
        raise AssertionError("expected the run cap")
    assert transport.calls == []


def test_daily_budget_stops_before_the_request():
    transport = ScriptedTransport([http(200, b"ok")])
    client = _client(transport, MemoryGate(budget=0))
    try:
        client.request(_spec())
    except BudgetExhausted as exc:
        assert exc.reason == "budget_exhausted"
    else:
        raise AssertionError("expected the daily budget")
    assert transport.calls == []


def test_rate_limit_sleeps_without_counting_an_http_call():
    slept = []
    transport = ScriptedTransport([http(200, b"ok")])
    client = _client(transport, MemoryGate(rate_limit_once=True), sleeper=slept.append)
    response = client.request(_spec())
    assert response.status == 200
    assert slept == [0.025]
    assert client.requests_made == 1


def test_conditional_304_does_not_replace_the_body_hash():
    store = MemoryStore()
    store.cache["abc"] = {"etag": '"v1"', "last_modified": None, "body_sha256": "old"}
    transport = ScriptedTransport([http(304, b"", {"etag": '"v1"'})])
    client = _client(transport)
    result = cached_request(client, store, _spec("abc"))
    assert result.not_modified is True
    assert result.body == b""
    assert store.hits["abc"] == 1
    assert transport.calls[0]["headers"]["If-None-Match"] == '"v1"'
    assert store.cache["abc"]["body_sha256"] == "old"


def test_identical_body_is_not_modified_when_the_origin_ignores_etags():
    store = MemoryStore()
    body = b'{"same":true}'
    store.cache["abc"] = {"etag": None, "last_modified": None, "body_sha256": body_sha256(body)}
    transport = ScriptedTransport([http(200, body)])
    result = cached_request(_client(transport), store, _spec("abc"))
    assert result.not_modified is True
    assert result.body == body


def _spec(key: str = "abc"):
    from grantfit.models import RequestSpec

    return RequestSpec("POST", "https://api.grants.gov/example", {"rows": 1}, key)
