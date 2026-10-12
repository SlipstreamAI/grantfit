BEGIN;
SELECT no_plan();

\ir ../seed.sql

SELECT is(
  (SELECT external_id FROM public.match_profile('harborlight', 6, 4, DATE '2026-10-12', 'seed')
    WHERE bucket = 'eligible' AND rank = 1),
  'rural-health',
  'clinic top match is the national rural outreach grant'
);

SELECT is(
  (SELECT score FROM public.match_profile('harborlight', 6, 4, DATE '2026-10-12', 'seed')
    WHERE bucket = 'eligible' AND rank = 1),
  95.00::numeric,
  'clinic top score is 95'
);

SELECT is(
  (SELECT external_id FROM public.match_profile('harborlight', 6, 4, DATE '2026-10-12', 'seed')
    WHERE bucket = 'eligible' AND rank = 2),
  'ca-clinic',
  'California clinic notice is second'
);

SELECT is(
  (SELECT score FROM public.match_profile('harborlight', 6, 4, DATE '2026-10-12', 'seed')
    WHERE external_id = 'ca-clinic'),
  82.00::numeric,
  'California clinic score is 82'
);

SELECT is(
  (SELECT external_id FROM public.match_profile('harborlight', 6, 4, DATE '2026-10-12', 'seed')
    WHERE bucket = 'near_miss' AND rank = 1),
  'closed-rural-health',
  'the closed cycle is the top near miss'
);

SELECT is(
  (SELECT blocking_reasons FROM public.match_profile('harborlight', 6, 4, DATE '2026-10-12', 'seed')
    WHERE external_id = 'closed-rural-health'),
  ARRAY['closed']::text[],
  'closed cycle is blocked only because it closed'
);

SELECT results_eq(
  $$SELECT external_id
    FROM public.match_profile('northwind', 6, 4, DATE '2026-10-12', 'seed')
    WHERE bucket = 'eligible'
    ORDER BY rank$$,
  $$VALUES ('nsf-research'::text), ('doe-scholarship-program'), ('wa-energy')$$,
  'university order is research, scholarship program, state energy'
);

SELECT is(
  (SELECT score FROM public.match_profile('northwind', 6, 4, DATE '2026-10-12', 'seed')
    WHERE external_id = 'nsf-research'),
  100.00::numeric,
  'university research notice is a perfect score'
);

SELECT is(
  (SELECT score FROM public.match_profile('northwind', 6, 4, DATE '2026-10-12', 'seed')
    WHERE external_id = 'doe-scholarship-program'),
  73.25::numeric,
  'institutional scholarship program scores 73.25'
);

SELECT is(
  (SELECT score FROM public.match_profile('northwind', 6, 4, DATE '2026-10-12', 'seed')
    WHERE external_id = 'wa-energy'),
  56.80::numeric,
  'Washington energy notice scores 56.80'
);

SELECT results_eq(
  $$SELECT external_id
    FROM public.match_profile('maya-chen', 6, 4, DATE '2026-10-12', 'seed')
    WHERE bucket = 'eligible'
    ORDER BY rank$$,
  $$VALUES ('udall-scholarship'::text)$$,
  'the student only matches the individual scholarship'
);

SELECT is(
  (SELECT blocking_reasons FROM public.match_profile('maya-chen', 6, 4, DATE '2026-10-12', 'seed')
    WHERE external_id = 'grad-fellowship'),
  ARRAY['award_mismatch']::text[],
  'graduate fellowship is too large for the student budget'
);

SELECT ok(
  (SELECT blocking_reasons FROM public.match_profile('maya-chen', 6, 4, DATE '2026-10-12', 'seed')
    WHERE external_id = 'doe-scholarship-program')
    @> ARRAY['applicant_type_mismatch', 'award_mismatch']::text[],
  'institutional scholarship program is not an individual award'
);

SELECT results_eq(
  $$SELECT external_id
    FROM public.match_profile('red-cedar', 6, 4, DATE '2026-10-12', 'seed')
    WHERE bucket = 'eligible'
    ORDER BY rank$$,
  $$VALUES ('tribal-housing'::text), ('tribal-housing-forecast')$$,
  'tribal authority gets the open housing grant ahead of the forecast'
);

SELECT is(
  (SELECT score FROM public.match_profile('red-cedar', 6, 4, DATE '2026-10-12', 'seed')
    WHERE external_id = 'tribal-housing'),
  85.75::numeric,
  'open tribal housing score'
);

SELECT is(
  (SELECT score FROM public.match_profile('red-cedar', 6, 4, DATE '2026-10-12', 'seed')
    WHERE external_id = 'tribal-housing-forecast'),
  77.75::numeric,
  'forecast scores lower because it is not open yet'
);

SELECT * FROM finish();
ROLLBACK;
