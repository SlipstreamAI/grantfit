"""Command line: sync notices, print matches, show the request budget."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

from grantfit.db import PostgresStore
from grantfit.http import BudgetedClient, HttpxTransport
from grantfit.providers.grants_gov import GrantsGovProvider
from grantfit.sync import run_sync

DEMO_DSN = "postgresql://grantfit_demo:grantfit_local_dev@127.0.0.1:5432/grantfit"
WORKER_DSN = "postgresql://grantfit_worker:grantfit_local_dev@127.0.0.1:5432/grantfit"


def worker_dsn() -> str:
    return os.environ.get("GRANTFIT_DATABASE_URL") or os.environ.get("DATABASE_URL") or WORKER_DSN


def demo_dsn() -> str:
    return os.environ.get("GRANTFIT_DEMO_DATABASE_URL") or DEMO_DSN


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="grantfit", description="Match applicant profiles to federal notices.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sync = sub.add_parser("sync", help="Pull Grants.gov notices within the request budget")
    sync.add_argument("--keyword", default="scholarship")
    sync.add_argument("--statuses", default="forecasted|posted")
    sync.add_argument("--rows", type=int, default=25)
    sync.add_argument("--max-pages", type=int, default=1)
    sync.add_argument("--max-requests", type=int, default=10)
    sync.add_argument("--refresh-details", action="store_true")
    sync.add_argument("--all-queries", action="store_true", help="Use grantfit.sync_queries instead of --keyword")
    sync.add_argument("--json", action="store_true")
    sync.add_argument("--verbose", action="store_true")

    drain = sub.add_parser("drain", help="Claim one pg_cron request and sync it")
    drain.add_argument("--keyword", default="scholarship")
    drain.add_argument("--max-requests", type=int, default=10)
    drain.add_argument("--max-pages", type=int, default=1)
    drain.add_argument("--json", action="store_true")
    drain.add_argument("--verbose", action="store_true")

    match = sub.add_parser("match", help="Print ranked matches for a demo profile")
    match.add_argument("--slug", required=True)
    match.add_argument("--limit", type=int, default=5)
    match.add_argument("--near", type=int, default=3)
    match.add_argument("--as-of", default=None)
    match.add_argument("--source", default=None, help="seed, grants_gov, or omit for both")

    sub.add_parser("health", help="Show today's request budget")

    args = parser.parse_args(argv)
    if args.cmd == "match":
        return _match(args)
    if args.cmd == "health":
        return _health()
    if args.cmd == "drain":
        return _drain(args)
    return _sync(args)


def _sync(args: argparse.Namespace) -> int:
    provider = GrantsGovProvider()
    transport = HttpxTransport()
    try:
        with PostgresStore(worker_dsn()) as store:
            queries = store.enabled_queries(provider.name) if args.all_queries else None
            client = BudgetedClient(
                transport,
                store,
                provider=provider.name,
                sleeper=time.sleep,
                max_requests=args.max_requests,
                on_request=(lambda method, url: print(f"{method} {url}", file=sys.stderr)) if args.verbose else None,
            )
            stats = run_sync(
                store,
                client,
                provider,
                keyword=args.keyword,
                statuses=args.statuses,
                rows=args.rows,
                max_pages=args.max_pages,
                refresh_details=args.refresh_details,
                queries=queries,
            )
    finally:
        transport.close()
    return _emit(stats, args.json)


def _drain(args: argparse.Namespace) -> int:
    provider = GrantsGovProvider()
    with PostgresStore(worker_dsn()) as store:
        request_id = store.claim(provider.name)
        if request_id is None:
            print("no pending sync request")
            return 0
        transport = HttpxTransport()
        try:
            client = BudgetedClient(
                transport,
                store,
                provider=provider.name,
                sleeper=time.sleep,
                max_requests=args.max_requests,
                on_request=(lambda method, url: print(f"{method} {url}", file=sys.stderr)) if args.verbose else None,
            )
            stats = run_sync(
                store,
                client,
                provider,
                keyword=args.keyword,
                max_pages=args.max_pages,
            )
        except Exception:
            store.complete(request_id, "failed")
            raise
        else:
            store.complete(request_id, "done" if stats.status != "failed" else "failed")
        finally:
            transport.close()
    return _emit(stats, args.json)


def _emit(stats, as_json: bool) -> int:
    if as_json:
        print(json.dumps(stats.as_dict(), indent=2))
    else:
        print(f"status:       {stats.status}")
        print(f"requests:     {stats.requests_made}")
        print(f"inserted:     {stats.inserted}")
        print(f"updated:      {stats.updated}")
        print(f"unchanged:    {stats.unchanged}")
        print(f"skipped:      {stats.skipped}")
        print(f"deferred:     {stats.deferred}")
        print(f"cache_hits:   {stats.cache_hits}")
        print(f"error:        {stats.error or '-'}")
    return 2 if stats.status == "failed" else 0


def _match(args: argparse.Namespace) -> int:
    with PostgresStore(demo_dsn()) as store:
        profile = store.profile(args.slug)
        if profile is None:
            print(f"No visible profile '{args.slug}'.", file=sys.stderr)
            return 1
        kinds = ", ".join(profile["organization_kinds"])
        state = profile["state_code"] or "any state"
        print(f"{profile['display_name']}  ({kinds}, {state})")
        if args.as_of:
            print(f"as of {args.as_of}")
        rows = store.match(args.slug, args.limit, args.near, args.as_of, args.source)
    current = None
    for row in rows:
        if row["bucket"] != current:
            current = row["bucket"]
            print()
            print("ELIGIBLE" if current == "eligible" else "NEAR MISS")
        reasons = ", ".join(row["blocking_reasons"] or row["reasons"] or [])
        award = _money(row["award_floor"], row["award_ceiling"])
        print(f"  {row['rank']}. {row['score']}  {row['title']}")
        print(f"       {row['agency']} · {row['kind']} · {row['status']} · {award} · closes {row['close_date']}")
        print(
            "       "
            f"topic {row['topic_points']} · keyword {row['keyword_points']} · "
            f"award {row['award_points']} · recency {row['recency_points']} · status {row['status_points']}"
        )
        print(f"       {reasons}")
    if not rows:
        print("\nNo notices to show.")
    return 0


def _health() -> int:
    with PostgresStore(demo_dsn()) as store:
        rows = store.health()
    if not rows:
        print("No providers configured.")
        return 0
    for row in rows:
        print(
            f"{row['provider']}: {row['requests_used']} of {row['daily_request_budget']} used "
            f"({row['remaining']} remaining) status={row['last_run_status'] or 'never'}"
        )
    return 0


def _money(floor, ceiling) -> str:
    if floor is None and ceiling is None:
        return "award n/a"
    if floor is not None and ceiling is not None and floor == ceiling:
        return f"${floor:,.0f}"
    left = "open" if floor is None else f"${floor:,.0f}"
    right = "open" if ceiling is None else f"${ceiling:,.0f}"
    return f"{left}–{right}"


if __name__ == "__main__":
    raise SystemExit(main())
