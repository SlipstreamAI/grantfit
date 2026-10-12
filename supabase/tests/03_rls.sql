BEGIN;
SELECT no_plan();

INSERT INTO grantfit.profiles (
  slug, display_name, organization_name, organization_kinds, interests, is_demo, owner_id
) VALUES
  ('visible-demo', 'Demo', 'Demo Org', ARRAY['nonprofit']::grantfit.organization_kind[], ARRAY['grant'], true, NULL),
  ('secret-profile', 'Secret', 'Secret Org', ARRAY['nonprofit']::grantfit.organization_kind[], ARRAY['grant'], false, '22222222-2222-2222-2222-222222222222');

INSERT INTO grantfit.opportunities (
  source, external_id, title, kind, status, open_date, close_date,
  award_floor, award_ceiling, eligible_applicants, topics, keywords,
  geo_scope, states, tags, content_hash
) VALUES (
  'test', 'rls-grant', 'RLS grant', 'grant', 'open', DATE '2026-10-12', DATE '2035-01-01',
  0, 100, ARRAY['nonprofit'], ARRAY['health'], ARRAY['clinic'],
  'national', ARRAY[]::text[], ARRAY[]::text[], 'hash-rls'
);

INSERT INTO grantfit.sync_runs (provider, status) VALUES ('grants_gov', 'running');
GRANT SELECT ON grantfit.sync_runs TO grantfit_demo;

-- Assertions stay as the superuser. The helpers switch role internally so
-- pgTAP can still write its result rows.
CREATE FUNCTION pg_temp.demo_count(p_sql text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  n bigint;
BEGIN
  EXECUTE 'SET LOCAL ROLE grantfit_demo';
  EXECUTE 'SELECT count(*) FROM (' || p_sql || ') AS q' INTO n;
  RETURN n;
END;
$$;

CREATE FUNCTION pg_temp.demo_consume() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'SET LOCAL ROLE grantfit_demo';
  PERFORM * FROM grantfit.try_consume_request('grants_gov', 1);
END;
$$;

CREATE FUNCTION pg_temp.insert_as_user(p_slug text, p_actor uuid, p_owner uuid, p_demo boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claim.sub', p_actor::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO grantfit.profiles (
    slug, display_name, organization_name, organization_kinds, interests, owner_id, is_demo
  ) VALUES (
    p_slug, p_slug, p_slug, ARRAY['nonprofit']::grantfit.organization_kind[],
    ARRAY['grant'], p_owner, p_demo
  );
END;
$$;

SELECT is(
  pg_temp.demo_count($$SELECT 1 FROM grantfit.profiles WHERE slug = 'visible-demo'$$),
  1::bigint,
  'demo role sees demo profiles'
);

SELECT is(
  pg_temp.demo_count($$SELECT 1 FROM grantfit.profiles WHERE slug = 'secret-profile'$$),
  0::bigint,
  'demo role cannot see private profiles'
);

SELECT cmp_ok(
  pg_temp.demo_count($$SELECT 1 FROM grantfit.opportunities$$),
  '>',
  0::bigint,
  'demo role can read notices'
);

SELECT is(
  pg_temp.demo_count($$SELECT 1 FROM grantfit.sync_runs$$),
  0::bigint,
  'RLS hides sync runs even when table select is granted'
);

SELECT throws_ok(
  $$SELECT pg_temp.demo_consume()$$,
  '42501',
  'permission denied for function try_consume_request',
  'demo role cannot spend request budget'
);

SELECT cmp_ok(
  pg_temp.demo_count($$SELECT 1 FROM grantfit.sync_health()$$),
  '>',
  0::bigint,
  'demo role can read the public budget snapshot'
);

SELECT cmp_ok(
  pg_temp.demo_count($$SELECT 1 FROM grantfit.match_profile('visible-demo', 5, 0, DATE '2026-10-12', 'test')$$),
  '>',
  0::bigint,
  'demo role can match a demo profile'
);

SELECT is(
  pg_temp.demo_count($$SELECT 1 FROM grantfit.match_profile('secret-profile', 5, 5, DATE '2026-10-12', NULL)$$),
  0::bigint,
  'demo role cannot match a private profile'
);

SELECT lives_ok(
  $$SELECT pg_temp.insert_as_user(
      'mine',
      '11111111-1111-1111-1111-111111111111',
      '11111111-1111-1111-1111-111111111111',
      false
    )$$,
  'authenticated user inserts their own profile'
);

SELECT throws_ok(
  $$SELECT pg_temp.insert_as_user(
      'not-mine',
      '11111111-1111-1111-1111-111111111111',
      '33333333-3333-3333-3333-333333333333',
      false
    )$$,
  '42501',
  'new row violates row-level security policy for table "profiles"',
  'cannot insert a profile for someone else'
);

SELECT throws_ok(
  $$SELECT pg_temp.insert_as_user(
      'fake-demo',
      '11111111-1111-1111-1111-111111111111',
      '11111111-1111-1111-1111-111111111111',
      true
    )$$,
  '42501',
  'new row violates row-level security policy for table "profiles"',
  'authenticated users cannot create demo profiles'
);

SELECT * FROM finish();
ROLLBACK;
