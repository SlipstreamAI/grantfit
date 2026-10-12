"""Postgres adapter. Each call uses the connection the caller manages.

Autocommit is right for a live sync: a consumed budget must be visible to the
other worker before the HTTP call returns. Tests can pass a transactional
connection and roll it back.
"""

from __future__ import annotations

import json
from typing import Any

import psycopg
from psycopg.rows import dict_row

from grantfit.models import BudgetDecision


class PostgresStore:
    def __init__(self, dsn: str | None = None, conn: Any = None) -> None:
        if conn is None and not dsn:
            raise ValueError("PostgresStore needs a DSN or a connection")
        self._dsn = dsn
        self._conn = conn
        self._owns = conn is None

    def __enter__(self) -> PostgresStore:
        if self._conn is None:
            self._conn = psycopg.connect(self._dsn, autocommit=True)
        return self

    def __exit__(self, *exc: object) -> None:
        if self._owns and self._conn is not None:
            self._conn.close()
            self._conn = None

    @property
    def conn(self):
        if self._conn is None:
            raise RuntimeError("store is not connected")
        return self._conn

    def try_consume(self, provider: str, cost: int = 1) -> BudgetDecision:
        row = self.conn.execute(
            "SELECT allowed, remaining, retry_after_ms, reason FROM grantfit.try_consume_request(%s, %s)",
            (provider, cost),
        ).fetchone()
        return BudgetDecision(bool(row[0]), int(row[1]), int(row[2]), row[3])

    def start_run(self, provider: str) -> str:
        row = self.conn.execute("SELECT grantfit.start_sync_run(%s)", (provider,)).fetchone()
        return str(row[0])

    def finish_run(self, run_id, status, requests, inserted, updated, unchanged, skipped, error, detail) -> None:
        self.conn.execute(
            """
            SELECT grantfit.finish_sync_run(%s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb)
            """,
            (run_id, status, requests, inserted, updated, unchanged, skipped, error, json.dumps(detail or {})),
        )

    def fingerprints(self, source: str, external_ids: list[str]) -> dict[str, str | None]:
        rows = self.conn.execute(
            "SELECT external_id, list_fingerprint FROM grantfit.list_fingerprints(%s, %s)",
            (source, external_ids),
        ).fetchall()
        return {row[0]: row[1] for row in rows}

    def upsert(self, rows: list[dict]) -> list[tuple[str, str]]:
        found = self.conn.execute(
            "SELECT external_id, action FROM grantfit.upsert_opportunities(%s::jsonb)",
            (json.dumps(rows),),
        ).fetchall()
        return [(row[0], row[1]) for row in found]

    def get_cache(self, key: str) -> dict | None:
        row = self.conn.execute(
            "SELECT etag, last_modified, body_sha256 FROM grantfit.get_http_cache(%s)",
            (key,),
        ).fetchone()
        if row is None:
            return None
        return {"etag": row[0], "last_modified": row[1], "body_sha256": row[2]}

    def put_cache(self, key: str, etag: str | None, last_modified: str | None, body_sha256: str) -> None:
        self.conn.execute(
            "SELECT grantfit.put_http_cache(%s, %s, %s, %s)",
            (key, etag, last_modified, body_sha256),
        )

    def touch_cache(self, key: str) -> None:
        self.conn.execute("SELECT grantfit.touch_http_cache(%s)", (key,))

    def note_high_water(self, provider: str, day: str) -> None:
        self.conn.execute("SELECT grantfit.note_high_water(%s, %s)", (provider, day))

    def enabled_queries(self, provider: str) -> list[tuple[str, str]]:
        rows = self.conn.execute(
            "SELECT keyword, statuses FROM grantfit.enabled_queries(%s)",
            (provider,),
        ).fetchall()
        return [(row[0], row[1]) for row in rows]

    def claim(self, provider: str) -> str | None:
        row = self.conn.execute("SELECT grantfit.claim_sync_request(%s)", (provider,)).fetchone()
        return None if row[0] is None else str(row[0])

    def complete(self, request_id: str | None, status: str) -> None:
        self.conn.execute("SELECT grantfit.complete_sync_request(%s, %s)", (request_id, status))

    def match(self, slug: str, eligible_limit: int, near_limit: int, as_of: str | None, source: str | None):
        query = """
            SELECT bucket, rank, external_id, title, agency, kind, status, score,
                   topic_points, keyword_points, award_points, recency_points, status_points,
                   reasons, blocking_reasons, close_date, award_floor, award_ceiling
            FROM grantfit.match_profile(%s, %s, %s, COALESCE(%s::date, CURRENT_DATE), %s)
        """
        with self.conn.cursor(row_factory=dict_row) as cur:
            cur.execute(query, (slug, eligible_limit, near_limit, as_of, source))
            return cur.fetchall()

    def profile(self, slug: str):
        with self.conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                """
                SELECT slug, display_name, organization_kinds::text[] AS organization_kinds,
                       state_code, topics, interests
                FROM grantfit.profiles
                WHERE slug = %s
                """,
                (slug,),
            )
            return cur.fetchone()

    def health(self):
        with self.conn.cursor(row_factory=dict_row) as cur:
            cur.execute("SELECT * FROM grantfit.sync_health()")
            return cur.fetchall()
