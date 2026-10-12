BEGIN;
SELECT no_plan();

SELECT is(grantfit.dice_coefficient(ARRAY['health'], ARRAY['health']), 1.0000::numeric, 'identical topics');
SELECT is(grantfit.dice_coefficient(ARRAY['a','b'], ARRAY['b','c']), 0.5000::numeric, 'partial overlap');
SELECT is(grantfit.dice_coefficient(ARRAY['a'], ARRAY['b']), 0.0000::numeric, 'disjoint topics');
SELECT is(grantfit.dice_coefficient(ARRAY[]::text[], ARRAY['a']), NULL::numeric, 'empty side is null');
SELECT is(
  grantfit.dice_coefficient(ARRAY['Health','health'], ARRAY['HEALTH']),
  1.0000::numeric,
  'dice is case-insensitive and distinct'
);

INSERT INTO grantfit.profiles (
  slug, display_name, organization_name, organization_kinds,
  state_code, topics, keywords, min_award, max_award, interests, is_demo
) VALUES
  ('perfect', 'Perfect', 'Perfect Org', ARRAY['nonprofit']::grantfit.organization_kind[], NULL, ARRAY['health'], ARRAY['clinic'], 0, 100, ARRAY['grant'], true),
  ('texan', 'Texan', 'Texan Org', ARRAY['nonprofit']::grantfit.organization_kind[], 'TX', ARRAY['health'], ARRAY['clinic'], 0, 100, ARRAY['grant'], true),
  ('californian', 'Californian', 'Californian Org', ARRAY['nonprofit']::grantfit.organization_kind[], 'CA', ARRAY['health'], ARRAY['clinic'], 0, 100, ARRAY['grant'], true),
  ('anywhere', 'Anywhere', 'Anywhere Org', ARRAY['nonprofit']::grantfit.organization_kind[], NULL, ARRAY['health'], ARRAY['clinic'], 0, 100, ARRAY['grant'], true),
  ('big-awards', 'Big', 'Big Org', ARRAY['nonprofit']::grantfit.organization_kind[], NULL, ARRAY['health'], ARRAY['clinic'], 50, 100, ARRAY['grant'], true),
  ('scholar', 'Scholar', 'Scholar', ARRAY['individual']::grantfit.organization_kind[], NULL, ARRAY['health'], ARRAY['clinic'], 0, 100, ARRAY['scholarship'], true),
  ('no-topics', 'No Topics', 'No Topics', ARRAY['nonprofit']::grantfit.organization_kind[], NULL, ARRAY[]::text[], ARRAY['clinic'], 0, 100, ARRAY['grant'], true),
  ('no-keywords', 'No Keywords', 'No Keywords', ARRAY['nonprofit']::grantfit.organization_kind[], NULL, ARRAY['health'], ARRAY[]::text[], 0, 100, ARRAY['grant'], true),
  ('open-interests', 'Open', 'Open', ARRAY['nonprofit']::grantfit.organization_kind[], NULL, ARRAY['health'], ARRAY['clinic'], NULL, NULL, ARRAY[]::text[], true);

INSERT INTO grantfit.opportunities (
  source, external_id, title, kind, status, open_date, close_date,
  award_floor, award_ceiling, eligible_applicants, eligibility_basis,
  topics, keywords, geo_scope, states, tags, content_hash
) VALUES
  ('test', 'perfect', 'Perfect grant', 'grant', 'open', DATE '2026-10-12', DATE '2030-01-01', 0, 100, ARRAY['nonprofit'], 'structured', ARRAY['health'], ARRAY['clinic'], 'national', ARRAY[]::text[], ARRAY[]::text[], 'h-perfect'),
  ('test', 'ca-only', 'CA grant', 'grant', 'open', DATE '2026-10-12', DATE '2030-01-01', 0, 100, ARRAY['nonprofit'], 'structured', ARRAY['health'], ARRAY['clinic'], 'state', ARRAY['CA'], ARRAY[]::text[], 'h-ca'),
  ('test', 'closed-one', 'Closed', 'grant', 'closed', DATE '2020-01-01', DATE '2021-01-01', 0, 100, ARRAY['nonprofit'], 'structured', ARRAY['health'], ARRAY['clinic'], 'national', ARRAY[]::text[], ARRAY[]::text[], 'h-closed'),
  ('test', 'past-close', 'Past close', 'grant', 'open', DATE '2020-01-01', DATE '2021-01-01', 0, 100, ARRAY['nonprofit'], 'structured', ARRAY['health'], ARRAY['clinic'], 'national', ARRAY[]::text[], ARRAY[]::text[], 'h-past'),
  ('test', 'forecast-one', 'Forecast', 'grant', 'forecasted', DATE '2027-01-01', DATE '2030-01-01', 0, 100, ARRAY['nonprofit'], 'structured', ARRAY['health'], ARRAY['clinic'], 'national', ARRAY[]::text[], ARRAY[]::text[], 'h-forecast'),
  ('test', 'scholarship-one', 'Scholarship', 'scholarship', 'open', DATE '2026-10-12', DATE '2030-01-01', 0, 100, ARRAY['nonprofit'], 'structured', ARRAY['health'], ARRAY['clinic'], 'national', ARRAY[]::text[], ARRAY[]::text[], 'h-sch'),
  ('test', 'unrestricted-one', 'Open call', 'grant', 'open', DATE '2026-10-12', DATE '2030-01-01', 0, 100, ARRAY['unrestricted'], 'unrestricted', ARRAY['health'], ARRAY['clinic'], 'national', ARRAY[]::text[], ARRAY[]::text[], 'h-un'),
  ('test', 'unspecified-one', 'See text', 'grant', 'open', DATE '2026-10-12', DATE '2030-01-01', 0, 100, ARRAY[]::text[], 'see_text', ARRAY['health'], ARRAY['clinic'], 'national', ARRAY[]::text[], ARRAY[]::text[], 'h-see'),
  ('test', 'tiny-award', 'Tiny', 'grant', 'open', DATE '2026-10-12', DATE '2030-01-01', 0, 10, ARRAY['nonprofit'], 'structured', ARRAY['health'], ARRAY['clinic'], 'national', ARRAY[]::text[], ARRAY[]::text[], 'h-tiny'),
  ('test', 'tagged-grant', 'Institutional scholarship', 'grant', 'open', DATE '2026-10-12', DATE '2030-01-01', 0, 100, ARRAY['individual'], 'structured', ARRAY['health'], ARRAY['clinic'], 'national', ARRAY[]::text[], ARRAY['scholarship_program'], 'h-tag');

SELECT is(
  (SELECT eligible FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'perfect'),
    DATE '2026-10-12')),
  true,
  'perfect pair is eligible'
);

SELECT is(
  (SELECT score FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'perfect'),
    DATE '2026-10-12')),
  100.00::numeric,
  'perfect pair scores 100'
);

SELECT is(
  (SELECT reasons FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'perfect'),
    DATE '2026-10-12')),
  ARRAY['window_open','applicant_type_match','geo_national','award_overlap','kind_match']::text[],
  'perfect reasons in spec order'
);

SELECT is(
  (SELECT eligible FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'texan'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'ca-only'),
    DATE '2026-10-12')),
  false,
  'wrong state is ineligible'
);

SELECT is(
  (SELECT blocking_reasons FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'texan'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'ca-only'),
    DATE '2026-10-12')),
  ARRAY['geo_mismatch']::text[],
  'geo mismatch is the only block'
);

SELECT is(
  (SELECT score FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'texan'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'ca-only'),
    DATE '2026-10-12')),
  100.00::numeric,
  'near-miss score is still computed'
);

SELECT is(
  (SELECT eligible FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'californian'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'ca-only'),
    DATE '2026-10-12')),
  true,
  'listed state matches'
);

SELECT ok(
  (SELECT 'geo_state_match' = ANY(reasons) FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'californian'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'ca-only'),
    DATE '2026-10-12')),
  'state match reason'
);

SELECT ok(
  (SELECT 'geo_profile_national' = ANY(reasons) FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'anywhere'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'ca-only'),
    DATE '2026-10-12')),
  'null state can work in a restricted notice'
);

SELECT is(
  (SELECT blocking_reasons FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'closed-one'),
    DATE '2026-10-12')),
  ARRAY['closed']::text[],
  'closed status blocks'
);

SELECT is(
  (SELECT blocking_reasons FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'past-close'),
    DATE '2026-10-12')),
  ARRAY['closed']::text[],
  'past close date blocks an otherwise open notice'
);

SELECT is(
  (SELECT status_points FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'forecast-one'),
    DATE '2026-10-12')),
  6::numeric,
  'forecasted status is worth 6'
);

SELECT is(
  (SELECT recency_points FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'forecast-one'),
    DATE '2026-10-12')),
  6::numeric,
  'future open date is worth 6'
);

SELECT is(
  (SELECT eligible FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'forecast-one'),
    DATE '2026-10-12')),
  true,
  'forecasted notices stay eligible'
);

SELECT is(
  (SELECT blocking_reasons FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'scholarship-one'),
    DATE '2026-10-12')),
  ARRAY['kind_mismatch']::text[],
  'scholarship does not satisfy a grant-only interest'
);

SELECT is(
  (SELECT eligible FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'scholar'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'unrestricted-one'),
    DATE '2026-10-12')),
  false,
  'unrestricted applicant still has to match kind'
);

SELECT ok(
  (SELECT 'applicant_unrestricted' = ANY(reasons) FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'unrestricted-one'),
    DATE '2026-10-12')),
  'unrestricted applicant reason'
);

SELECT is(
  (SELECT blocking_reasons FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'perfect'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'unspecified-one'),
    DATE '2026-10-12')),
  ARRAY['applicant_type_unspecified']::text[],
  'empty applicant list fails closed'
);

SELECT is(
  (SELECT blocking_reasons FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'big-awards'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'tiny-award'),
    DATE '2026-10-12')),
  ARRAY['award_mismatch']::text[],
  'ceiling below the profile minimum blocks'
);

SELECT is(
  (SELECT award_points FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'big-awards'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'tiny-award'),
    DATE '2026-10-12')),
  0::numeric,
  'award mismatch scores zero award points'
);

SELECT is(
  (SELECT eligible FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'scholar'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'tagged-grant'),
    DATE '2026-10-12')),
  true,
  'scholarship interest matches a tagged institutional grant'
);

SELECT is(
  (SELECT topic_points FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'no-topics'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'perfect'),
    DATE '2026-10-12')),
  10::numeric,
  'missing topics get the neutral 10'
);

SELECT is(
  (SELECT keyword_points FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'no-keywords'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'perfect'),
    DATE '2026-10-12')),
  8::numeric,
  'missing keywords get the neutral 8'
);

SELECT is(
  (SELECT award_points FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'open-interests'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'perfect'),
    DATE '2026-10-12')),
  8::numeric,
  'missing award bounds score 8'
);

SELECT ok(
  (SELECT 'kind_unconstrained' = ANY(reasons) FROM grantfit.evaluate_one(
    (SELECT id FROM grantfit.profiles WHERE slug = 'open-interests'),
    (SELECT id FROM grantfit.opportunities WHERE external_id = 'perfect'),
    DATE '2026-10-12')),
  'empty interests do not filter kind'
);

SELECT is_empty(
  $$SELECT * FROM grantfit.match_profile('does-not-exist')$$,
  'unknown slug returns no rows'
);

SELECT * FROM finish();
ROLLBACK;
