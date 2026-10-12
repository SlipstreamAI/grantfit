from datetime import datetime, timezone

from grantfit.cost import backoff_ms, parse_retry_after


def test_backoff_grows_then_caps():
    assert backoff_ms(0, base_ms=200, jitter_ms=0) == 200
    assert backoff_ms(1, base_ms=200, jitter_ms=0) == 400
    assert backoff_ms(3, base_ms=200, jitter_ms=0) == 1600
    assert backoff_ms(10, base_ms=200, cap_ms=8000, jitter_ms=0) == 8000


def test_retry_after_wins_and_is_capped():
    assert backoff_ms(4, retry_after_ms=1500, jitter_ms=40) == 1500
    assert backoff_ms(0, retry_after_ms=99_999, cap_ms=8000) == 8000
    assert backoff_ms(0, retry_after_ms=-5) == 0


def test_parse_retry_after_seconds_and_http_date():
    assert parse_retry_after("2") == 2000
    assert parse_retry_after(None) is None
    assert parse_retry_after("soon") is None
    now = datetime(2026, 10, 12, 0, 0, tzinfo=timezone.utc)
    assert parse_retry_after("Mon, 12 Oct 2026 00:00:03 GMT", now=now) == 3000
    assert parse_retry_after("Mon, 12 Oct 2026 00:00:00 GMT", now=now) == 0
