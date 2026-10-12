"""Page through a provider, skip unchanged search hits, and upsert details."""

from __future__ import annotations

from grantfit.http import BudgetedClient, cached_request
from grantfit.models import BudgetExhausted, FetchResult, ProviderError, SyncStats
from grantfit.providers.grants_gov import GrantsGovProvider


def run_sync(
    store,
    client: BudgetedClient,
    provider: GrantsGovProvider,
    *,
    keyword: str,
    statuses: str = "forecasted|posted",
    rows: int = 25,
    max_pages: int = 1,
    refresh_details: bool = False,
    stop_when_unchanged: bool = True,
    queries: list[tuple[str, str]] | None = None,
) -> SyncStats:
    stats = SyncStats()
    run_id = None
    try:
        run_id = store.start_run(provider.name)
        jobs = queries if queries is not None else [(keyword, statuses)]
        for job_keyword, job_statuses in jobs:
            _sync_query(
                store,
                client,
                provider,
                stats,
                keyword=job_keyword,
                statuses=job_statuses,
                rows=rows,
                max_pages=max_pages,
                refresh_details=refresh_details,
                stop_when_unchanged=stop_when_unchanged,
            )
            if stats.status == "budget_stopped":
                break
        if stats.status == "running":
            stats.status = "success"
    except ProviderError as exc:
        stats.status = "failed"
        stats.error = str(exc)
    except Exception as exc:  # noqa: BLE001 — recorded on the sync run, then re-raised
        stats.status = "failed"
        stats.error = str(exc)
        raise
    finally:
        stats.requests_made = client.requests_made
        if run_id is not None:
            store.finish_run(
                run_id,
                stats.status if stats.status != "running" else "failed",
                stats.requests_made,
                stats.inserted,
                stats.updated,
                stats.unchanged,
                stats.skipped,
                stats.error,
                {"deferred": stats.deferred, "cache_hits": stats.cache_hits},
            )
    return stats


def _sync_query(store, client, provider, stats: SyncStats, **opts) -> None:
    start = 0
    for _page in range(opts["max_pages"]):
        spec = provider.search_request(
            start=start,
            rows=opts["rows"],
            keyword=opts["keyword"],
            statuses=opts["statuses"],
        )
        try:
            fetched = cached_request(client, store, spec)
        except BudgetExhausted:
            stats.status = "budget_stopped"
            return
        if fetched.not_modified:
            stats.cache_hits += 1
            return
        hits = provider.parse_search(fetched.body)
        if not hits:
            return
        known = {}
        if not opts["refresh_details"]:
            known = store.fingerprints(provider.name, [hit["external_id"] for hit in hits])
        page_unchanged = True
        for hit in hits:
            if not opts["refresh_details"] and known.get(hit["external_id"]) == hit["list_fingerprint"]:
                stats.skipped += 1
                continue
            page_unchanged = False
            try:
                detail = cached_request(client, store, provider.detail_request(hit["external_id"]))
            except BudgetExhausted:
                stats.deferred += 1
                stats.status = "budget_stopped"
                return
            _apply_detail(store, provider, stats, hit, detail)
        if opts["stop_when_unchanged"] and page_unchanged:
            return
        if len(hits) < opts["rows"]:
            return
        start += opts["rows"]


def _apply_detail(store, provider, stats: SyncStats, hit: dict, detail: FetchResult) -> None:
    if detail.not_modified:
        stats.cache_hits += 1
        stats.skipped += 1
        return
    try:
        row = provider.parse_detail(detail.body, hit)
    except ProviderError:
        stats.skipped += 1
        if stats.status == "running":
            stats.status = "partial"
        return
    for _external_id, action in store.upsert([row]):
        if action == "inserted":
            stats.inserted += 1
        elif action == "updated":
            stats.updated += 1
        else:
            stats.unchanged += 1
    if row.get("open_date"):
        store.note_high_water(provider.name, row["open_date"])
