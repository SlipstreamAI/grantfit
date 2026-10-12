BEGIN;
SELECT no_plan();

SELECT is(
  (
    SELECT action FROM grantfit.upsert_opportunities($j$[
      {
        "source": "grants_gov",
        "external_id": "100",
        "title": "First title",
        "summary": "A notice",
        "agency": "NSF",
        "agency_code": "NSF",
        "kind": "grant",
        "status": "open",
        "open_date": "2026-09-20",
        "close_date": "2035-01-01",
        "award_floor": 10,
        "award_ceiling": 20,
        "eligible_applicants": ["University", "nonprofit"],
        "eligibility_basis": "structured",
        "topics": ["STEM", "stem"],
        "keywords": ["Research", "research"],
        "geo_scope": "national",
        "states": [],
        "tags": [],
        "raw": {"token": "do-not-store", "id": 100}
      }
    ]$j$::jsonb)
  ),
  'inserted',
  'first upsert inserts'
);

SELECT is(
  (SELECT raw ? 'token' FROM grantfit.opportunities WHERE external_id = '100'),
  false,
  'session token is stripped from raw'
);

SELECT is(
  (SELECT eligible_applicants FROM grantfit.opportunities WHERE external_id = '100'),
  ARRAY['nonprofit', 'university']::text[],
  'applicant kinds are normalized and sorted'
);

SELECT is(
  (
    SELECT action FROM grantfit.upsert_opportunities($j$[
      {
        "source": "grants_gov",
        "external_id": "100",
        "title": "First title",
        "summary": "A notice",
        "agency": "NSF",
        "agency_code": "NSF",
        "kind": "grant",
        "status": "open",
        "open_date": "2026-09-20",
        "close_date": "2035-01-01",
        "award_floor": 10,
        "award_ceiling": 20,
        "eligible_applicants": ["university", "nonprofit"],
        "eligibility_basis": "structured",
        "topics": ["stem"],
        "keywords": ["research"],
        "geo_scope": "national",
        "tags": [],
        "raw": {"id": 100}
      }
    ]$j$::jsonb)
  ),
  'unchanged',
  'same payload does not write again'
);

SELECT is(
  (SELECT updated_at = created_at FROM grantfit.opportunities WHERE external_id = '100'),
  true,
  'unchanged upsert leaves updated_at alone'
);

SELECT is(
  (
    SELECT action FROM grantfit.upsert_opportunities($j$[
      {
        "source": "grants_gov",
        "external_id": "100",
        "title": "Revised title",
        "kind": "grant",
        "status": "open",
        "eligible_applicants": ["nonprofit"],
        "geo_scope": "national"
      }
    ]$j$::jsonb)
  ),
  'updated',
  'title change updates the row'
);

SELECT throws_ok(
  $$SELECT * FROM grantfit.upsert_opportunities('[{"source":"grants_gov","external_id":"bad","title":"T","kind":"nope","status":"open"}]'::jsonb)$$,
  '22P02',
  'invalid input value for enum opportunity_kind: "nope"',
  'invalid kind is rejected'
);

SELECT throws_ok(
  $$SELECT * FROM grantfit.try_consume_request('no-such-provider', 1)$$,
  'P0001',
  'unknown provider: no-such-provider',
  'unknown provider is rejected'
);

UPDATE grantfit.provider_budgets
SET requests_used = 0,
    min_interval_ms = 0,
    last_request_at = now() - interval '1 day',
    window_started_at = now(),
    daily_request_budget = 2
WHERE provider = 'grants_gov';

SELECT is(
  (SELECT allowed FROM grantfit.try_consume_request('grants_gov', 1)),
  true,
  'budget allows the first request'
);

SELECT is(
  (SELECT requests_used FROM grantfit.provider_budgets WHERE provider = 'grants_gov'),
  1,
  'consume increments the counter'
);

SELECT is(
  (SELECT allowed FROM grantfit.try_consume_request('grants_gov', 1)),
  true,
  'second request still inside the budget'
);

SELECT is(
  (SELECT reason FROM grantfit.try_consume_request('grants_gov', 1)),
  'budget_exhausted',
  'third request is over the daily budget'
);

SELECT is(
  (SELECT requests_used FROM grantfit.provider_budgets WHERE provider = 'grants_gov'),
  2,
  'a denied request does not spend budget'
);

UPDATE grantfit.provider_budgets
SET requests_used = 0,
    min_interval_ms = 600000,
    last_request_at = now(),
    window_started_at = now(),
    daily_request_budget = 10
WHERE provider = 'grants_gov';

SELECT is(
  (SELECT reason FROM grantfit.try_consume_request('grants_gov', 1)),
  'rate_limited',
  'minimum interval blocks a second immediate call'
);

SELECT is(
  (SELECT requests_used FROM grantfit.provider_budgets WHERE provider = 'grants_gov'),
  0,
  'rate limiting does not spend budget'
);

SELECT cmp_ok(
  (SELECT retry_after_ms FROM grantfit.try_consume_request('grants_gov', 1)),
  '>',
  0,
  'rate limit reports a wait'
);

UPDATE grantfit.provider_budgets
SET requests_used = 10,
    daily_request_budget = 10,
    min_interval_ms = 0,
    last_request_at = now() - interval '2 days',
    window_started_at = now() - interval '2 days'
WHERE provider = 'grants_gov';

SELECT is(
  (SELECT allowed FROM grantfit.try_consume_request('grants_gov', 1)),
  true,
  'a new UTC day resets the counter'
);

SELECT is(
  (SELECT requests_used FROM grantfit.provider_budgets WHERE provider = 'grants_gov'),
  1,
  'reset counter starts at the new request'
);

SELECT lives_ok(
  $$SELECT grantfit.put_http_cache('k1', '"abc"', 'Mon, 01 Jan 2024 00:00:00 GMT', 'deadbeef')$$,
  'cache put'
);

SELECT is(
  (SELECT etag FROM grantfit.get_http_cache('k1')),
  '"abc"',
  'cache returns the stored etag'
);

SELECT lives_ok($$SELECT grantfit.touch_http_cache('k1')$$, 'cache touch');
SELECT is((SELECT hit_count FROM grantfit.http_cache WHERE cache_key = 'k1'), 1, 'touch increments hits');

SELECT is(
  grantfit.enqueue_sync('grants_gov', 'test'),
  grantfit.enqueue_sync('grants_gov', 'again'),
  'a second enqueue returns the open request'
);

SELECT is(
  (SELECT count(*) FROM grantfit.sync_requests WHERE provider = 'grants_gov' AND status = 'pending'),
  1::bigint,
  'only one pending request exists'
);

SELECT isnt(grantfit.claim_sync_request('grants_gov'), NULL::uuid, 'claim returns an id');
SELECT is(
  (SELECT status FROM grantfit.sync_requests WHERE provider = 'grants_gov'),
  'claimed',
  'claim marks the pending request'
);

SELECT is(grantfit.claim_sync_request('grants_gov'), NULL::uuid, 'nothing left to claim');

SELECT is(
  (SELECT list_fingerprint FROM grantfit.list_fingerprints('grants_gov', ARRAY['100'])),
  (SELECT list_fingerprint FROM grantfit.opportunities WHERE external_id = '100'),
  'fingerprint lookup returns the stored value'
);

SELECT * FROM finish();
ROLLBACK;
