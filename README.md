# GrantFit

[![CI](https://github.com/SlipstreamAI/grantfit/actions/workflows/ci.yml/badge.svg)](https://github.com/SlipstreamAI/grantfit/actions/workflows/ci.yml)
![pgTAP](https://img.shields.io/badge/pgTAP-86%20passed-1f6b4a)
![pytest](https://img.shields.io/badge/pytest-22%20passed-1f6b4a)
![Deno](https://img.shields.io/badge/Deno-9%20passed-1f6b4a)

Match an applicant to grants and scholarships in Postgres, then keep the Grants.gov sync inside a request budget.

GrantFit pulls public notices from the keyless [Grants.gov](https://www.grants.gov/) API, normalizes them, and upserts them idempotently. Eligibility is a set of hard rules in SQL: open window, applicant type, state, award size, and opportunity kind. A 100-point score explains the fit even when a notice is only a near miss. The Next.js demo and the CLI read that result. They do not rescore it.

![GrantFit ranking Harborlight Community Clinic against sample notices](docs/demo.png)

*Harborlight Community Clinic, a rural California nonprofit. Rural Health Network Outreach scores 95. The closed prior cycle scores 77 and stays a near miss.*

Sample notices ship with the seed, so the demo runs with the network off. Live notices use `source = grants_gov`.

## Architecture

```mermaid
flowchart LR
  subgraph ingest [Ingest]
    API["Grants.gov search2 and fetchOpportunity"]
    Worker["Python worker"]
    Edge["Edge Function sync-opportunities"]
  end
  subgraph database [Postgres]
    Notices["grantfit.opportunities"]
    Budget["budgets, cache, sync runs"]
    Match["grantfit.match_profile"]
    Queue["sync_requests"]
  end
  API --> Worker
  API --> Edge
  Worker --> Notices
  Worker --> Budget
  Edge --> Notices
  Edge --> Budget
  Cron["pg_cron, daily"] --> Queue
  Actions["GitHub Actions, daily"] --> Worker
  Queue --> Worker
  Profiles["grantfit.profiles"] --> Match
  Notices --> Match
  Match --> Demo["Next.js demo and grantfit match"]
```

`pg_cron` only inserts a queue row. It does not open a socket from the database. The worker claims that row. GitHub Actions is the other scheduler and runs the worker directly. Either one is enough.

## What was verified here

Postgres 16.15, pgTAP, Python 3.12, and Deno. Docker is not available in this environment, so `supabase start` was not run. The SQL files under `supabase/migrations` are what `supabase db reset` applies, and those files were applied to plain Postgres.

```text
pg_prove --ext .sql -d grantfit_test supabase/tests
Files=4, Tests=86, Result: PASS

pytest worker/tests
22 passed

deno test --allow-read supabase/functions
9 passed, 0 failed
```

A live sync against Grants.gov on 12 October 2026:

```text
POST https://api.grants.gov/v1/api/search2
POST https://api.grants.gov/v1/api/fetchOpportunity   # four detail calls
status: success   requests: 5   inserted: 4

# the same command again, without --refresh-details
status: success   requests: 1   skipped: 4   cache_hits: 0
```

The second run still searched, because Grants.gov did not send an ETag. It did not re-fetch the four details: each list row's fingerprint matched the row already stored. A later `--refresh-details` updated two agency names and left two rows unchanged.

```text
python -m grantfit health
grants_gov: 11 of 200 used (189 remaining) status=success
```

## Run it locally

Requirements: Postgres 16 or newer, [pgTAP](https://pgtap.org/) (`postgresql-16-pgtap` and the `pgtap` package, which provides `pg_prove`), Python 3.11+, and Node 20+ for the web demo. The Supabase CLI is optional and needs Docker.

```bash
git clone https://github.com/SlipstreamAI/grantfit.git
cd grantfit
scripts/bootstrap_local.sh
python -m venv .venv
.venv/bin/pip install -e "./worker[dev]"
.venv/bin/python -m grantfit match --slug harborlight --source seed --as-of 2026-10-12
.venv/bin/python -m grantfit sync --keyword scholarship --rows 25 --max-requests 10
cd web && npm install && npm run dev
```

The demo listens on [http://127.0.0.1:43123](http://127.0.0.1:43123). It connects as `grantfit_demo`. Copy `.env.example` if you want a different database URL. The default in the web app is the local demo role, so the page works without an env file.

Reset the demo database with `scripts/bootstrap_local.sh --reset`. SQL tests use a separate database:

```bash
scripts/test_sql.sh
GRANTFIT_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/grantfit_test \
  pytest worker/tests -q
deno test --allow-read supabase/functions
```

`scripts/test_sql.sh` drops and recreates `grantfit_test`, applies every migration, and runs pgTAP. CI does the same on plain Postgres. It does not need the Supabase CLI.

With Docker:

```bash
supabase start
supabase db reset
```

`supabase/config.toml` exposes the `grantfit` schema, loads `supabase/seed.sql`, and serves `sync-opportunities` with `verify_jwt = false`. Callers send `x-grantfit-sync-secret`. Set `GRANTFIT_SYNC_SECRET`, `SUPABASE_URL`, and `SUPABASE_SERVICE_ROLE_KEY` as function secrets.

## How matching works

`grantfit.evaluate_one(profile_id, opportunity_id, as_of)` returns a score even when the pair is ineligible. `grantfit.match_profile(slug, eligible_limit, near_miss_limit, as_of, source)` ranks the eligible rows, then the near misses. `public.match_profile` is the PostgREST wrapper and runs as the caller, so row level security still applies.

Hard rules, any one of which blocks eligibility:

| Check | Blocks when |
| --- | --- |
| Window | Status is closed, or `close_date` is before `as_of` |
| Applicant | The notice lists types and none of them is on the profile. An empty type list also blocks. `unrestricted` passes. |
| Geography | The notice is limited to states and the profile's state is not one of them. A profile with no state passes. |
| Award | The notice ceiling is below the profile minimum, or the floor is above the profile maximum. Missing amounts do not block. |
| Kind | The profile named interests, and the notice is not one of them. A grant tagged `scholarship_program` counts as a scholarship for an individual who asked for scholarships. |

Score, 100 points:

| Part | Points | Rule |
| --- | --- | --- |
| Topic | 40 | Sørensen–Dice overlap of the two topic arrays. 10 if either side has no topics. |
| Keyword | 25 | Share of the profile's keywords that also appear on the notice. 8 if the profile has none. |
| Award | 15 | How much of the notice range sits inside the profile range. 8 if either side is missing a bound. 0 when the hard rule blocks. |
| Recency | 10 | 10 if posted within 30 days, then 7, 4, and 2 as the notice ages. 4 if the open date is missing. |
| Status | 10 | 10 open, 6 forecasted, 3 unknown, 0 closed. |

A closed notice can still score well on topic and then show up as a near miss with the reason `closed`. That is deliberate: the score explains the fit, and the blocking list explains why it is not eligible.

Maya Chen is an individual student in Texas who wants scholarships between $1,000 and $20,000. On the sample set she scores 100 on the undergraduate environmental scholarship and is blocked from the campus research grant (wrong applicant, wrong award size, wrong kind) even though the topics overlap.

```sql
SELECT bucket, rank, round(score, 2) AS score, title, blocking_reasons
FROM public.match_profile('maya-chen', 5, 3, DATE '2026-10-12', 'seed');
```

CLI output from this database, Harborlight Community Clinic, sample notices only:

```text
Harborlight Community Clinic  (nonprofit, CA)
as of 2026-10-12

ELIGIBLE
  1. 95.00  Rural Health Network Outreach
       Health Resources and Services Administration · grant · open · $50,000–$300,000 · closes 2035-06-01
       topic 40.00 · keyword 20.00 · award 15.00 · recency 10 · status 10
       window_open, applicant_type_match, geo_national, award_overlap, kind_match
  2. 82.00  California Community Clinic Support
       Sample State Health Partnership · grant · open · $25,000–$400,000 · closes 2035-09-30
       topic 32.00 · keyword 15.00 · award 15.00 · recency 10 · status 10
       window_open, applicant_type_match, geo_state_match, award_overlap, kind_match

NEAR MISS
  1. 77.00  Rural Health Network Outreach (Closed Cycle)
       closed
```

The web demo shows the same function: four profiles, sample notices, the live Grants.gov slice, or both, plus today's request budget from `public.sync_health()`.

## Cost control

The daily counter lives in `grantfit.provider_budgets`, seeded at 200 requests for `grants_gov` with a minimum gap between calls. `grantfit.try_consume_request` locks the row, resets the counter when the UTC date changes, and returns `rate_limited` or `budget_exhausted` instead of going over. The Python client and the Edge Function both call it before every HTTP request. A per-run `--max-requests` cap stops a single invocation even sooner.

Retries cover 429 and 5xx. `Retry-After` wins over exponential backoff. Both waits are capped at 8 seconds. The client gives up after four attempts.

`grantfit.http_cache` stores the cache key (method, URL, and a canonical JSON body), the ETag, `Last-Modified`, and the SHA-256 of the body. The next call sends `If-None-Match` and `If-Modified-Since` when those validators exist. A 304 counts as a cache hit and does not re-parse the notice. An identical body with a new response is also a hit. Grants.gov often omits validators; the list fingerprint is the incremental path that still works. The fingerprint is the opportunity number, title, dates, status, and agency code. An unchanged search hit does not spend a detail request.

`grantfit.upsert_opportunities` inserts or updates on `(source, external_id)`. A second upsert of the same payload returns `unchanged` and does not bump `updated_at`. The stored `raw` document keeps structural fields only. Tokens and other unknown keys are dropped before insert.

Sync runs are recorded in `grantfit.sync_runs` with request counts, insert and update counts, and the error string if the run failed.

## Schedules

Both schedulers are in the repo.

- `supabase/migrations/20261012120400_cron.sql` installs a daily `pg_cron` job at 06:15 UTC when the extension exists. The job calls `grantfit.enqueue_sync('grants_gov', 'pg_cron')`. `python -m grantfit drain` claims one pending row and syncs it. On a database without `pg_cron` the migration prints a notice and continues. That is what happened in CI and in this environment.
- `.github/workflows/sync.yml` runs the same worker at 06:15 UTC, and on demand. Set the `GRANTFIT_DATABASE_URL` secret to the worker role. The workflow exits cleanly when the secret is absent, so a fork does not fail the schedule.

The Edge Function is the hosted equivalent of the worker. It uses the same normalize rules, checked against `fixtures/grants_gov/expected_nsf_26503.json` from both Python and Deno.

```bash
curl -X POST "$SUPABASE_URL/functions/v1/sync-opportunities" \
  -H "x-grantfit-sync-secret: $GRANTFIT_SYNC_SECRET" \
  -H "content-type: application/json" \
  -d '{"keyword":"scholarship","rows":25,"maxPages":1,"maxRequests":10}'
```

## Access control

Row level security is on and forced for profiles, notices, budgets, the HTTP cache, and the sync tables.

- `anon` and `grantfit_demo` can read demo profiles and every notice, and can execute `match_profile` and `sync_health`. They cannot upsert, and they cannot read cache validators or sync error text. `sync_health` returns only the budget snapshot.
- `authenticated` users can insert and update profiles they own. They cannot mark a profile as a demo.
- `grantfit_worker` and `service_role` can upsert and spend the budget. The public upsert wrapper is `SECURITY DEFINER` and is not granted to `anon`.

## Layout

```text
supabase/migrations   schema, matching, upsert, RLS, pg_cron, Edge RPC wrappers
supabase/seed.sql     four demo profiles and sample notices
supabase/tests        pgTAP for matching, sync, RLS, and the seed stories
supabase/functions    Deno sync, shared with the Python normalizer
worker/               grantfit CLI: sync, drain, match, health
web/                  Next.js demo
fixtures/grants_gov   captured search and detail payloads
scripts/              bootstrap_local.sh and test_sql.sh
```

## Limitations

- Grants.gov is the only provider. Adding another means a new normalizer plus a `provider_budgets` row. The budget and cache tables are already keyed by provider.
- The live API in this run did not return ETags, so conditional requests were not observed against the network. The 304 path is covered by unit tests with a fake transport.
- Narrative eligibility is a sentence heuristic. It drops negated sentences and "who may serve as PI" rules, and it fails closed when a notice uses an unfamiliar applicant code and no usable sentence.
- Geography is national or a list of US states. There is no county, country, or citizenship check beyond what the narrative parser can see.
- Some synopsis records name a person as `agencyName` and append "Grantor". The normalizer keeps the search-list agency in that case. Other agency strings are stored as Grants.gov sends them.
- Seed notices are written for the demo. They are not agency solicitations, and their close dates sit in 2035 so the sample stays eligible.
- `supabase start` needs Docker. This environment has the CLI and no Docker, so the hosted local stack was not booted. Plain Postgres ran the migrations, the seed, the demo, and the tests.
- The local role passwords in `scripts/bootstrap_local.sh` are development defaults. They are not production secrets, and they are the only credentials in the repo.
