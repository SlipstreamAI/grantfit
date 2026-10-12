"""Runs the SQL functions through the worker adapter. Skipped without a database URL."""

import os

import pytest

psycopg = pytest.importorskip("psycopg")

DSN = os.environ.get("GRANTFIT_DATABASE_URL")
pytestmark = pytest.mark.skipif(not DSN, reason="GRANTFIT_DATABASE_URL is not set")


def test_upsert_budget_and_match_round_trip():
    from grantfit.db import PostgresStore

    with psycopg.connect(DSN, autocommit=False) as conn:
        store = PostgresStore(conn=conn)
        row = {
            "source": "grants_gov",
            "external_id": "contract-1",
            "title": "Contract notice",
            "summary": "A clinic grant",
            "agency": "HRSA",
            "agency_code": "HRSA",
            "kind": "grant",
            "status": "open",
            "open_date": "2026-10-12",
            "close_date": "2035-01-01",
            "award_floor": 0,
            "award_ceiling": 100,
            "eligible_applicants": ["nonprofit"],
            "eligibility_basis": "structured",
            "topics": ["health"],
            "keywords": ["clinic"],
            "geo_scope": "national",
            "states": [],
            "tags": [],
            "raw": {"token": "drop-me", "id": 1},
        }
        assert store.upsert([row]) == [("contract-1", "inserted")]
        assert store.upsert([row]) == [("contract-1", "unchanged")]
        changed = dict(row, title="Contract notice revised")
        assert store.upsert([changed]) == [("contract-1", "updated")]
        stored = conn.execute(
            "SELECT raw ? 'token' FROM grantfit.opportunities WHERE external_id = 'contract-1'"
        ).fetchone()
        assert stored[0] is False

        conn.execute(
            """
            UPDATE grantfit.provider_budgets
            SET requests_used = 0, min_interval_ms = 0,
                last_request_at = now() - interval '1 day', window_started_at = now()
            WHERE provider = 'grants_gov'
            """
        )
        decision = store.try_consume("grants_gov", 1)
        assert decision.allowed is True
        assert decision.reason == "ok"

        conn.execute(
            """
            INSERT INTO grantfit.profiles (
              slug, display_name, organization_name, organization_kinds,
              topics, keywords, min_award, max_award, interests, is_demo
            ) VALUES (
              'contract-clinic', 'Contract Clinic', 'Contract Clinic',
              ARRAY['nonprofit']::grantfit.organization_kind[],
              ARRAY['health'], ARRAY['clinic'], 0, 100, ARRAY['grant'], true
            )
            """
        )
        matches = store.match("contract-clinic", 5, 0, "2026-10-12", "grants_gov")
        assert matches[0]["external_id"] == "contract-1"
        assert matches[0]["bucket"] == "eligible"
        assert float(matches[0]["score"]) == 100
        conn.rollback()
