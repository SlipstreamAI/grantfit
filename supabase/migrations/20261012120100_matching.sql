-- Eligibility is a hard gate. Score is relevance among rows that already passed,
-- and is also computed for near-misses so the UI can show what almost matched.
--
-- Score, max 100:
--   topics    40 * Dice coefficient, or 10 when either side has no topics
--   keywords  25 * |intersection| / |profile keywords|, or 8 when the profile has none
--   award     15 * overlap / opportunity span when all four bounds exist,
--             8 when a bound is missing, 0 when the ranges do not overlap
--   recency   10 within 30 days, 7 within 120, 4 within 365, 2 older,
--             6 if the open date is still in the future, 4 if unknown
--   status    10 open, 6 forecasted, 3 unknown, 0 closed
--
-- Hard rules, all must pass:
--   window     not closed, and close_date is null or on/after as_of
--   applicant  unrestricted, or kinds overlap; empty applicant list fails closed
--   geography  national, or profile has no state, or profile state is listed
--   award      ceiling is not below the profile minimum, and floor is not above the maximum
--   kind       interests empty, or kind matches, or a grant carries a scholarship/fellowship tag the profile asked for

CREATE FUNCTION grantfit.dice_coefficient(a text[], b text[])
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  WITH aa AS (
    SELECT DISTINCT lower(btrim(x)) AS t
    FROM unnest(coalesce(a, ARRAY[]::text[])) AS x
    WHERE btrim(coalesce(x, '')) <> ''
  ),
  bb AS (
    SELECT DISTINCT lower(btrim(x)) AS t
    FROM unnest(coalesce(b, ARRAY[]::text[])) AS x
    WHERE btrim(coalesce(x, '')) <> ''
  ),
  counts AS (
    SELECT
      (SELECT count(*) FROM aa) AS na,
      (SELECT count(*) FROM bb) AS nb,
      (SELECT count(*) FROM aa JOIN bb USING (t)) AS ni
  )
  SELECT CASE
    WHEN na = 0 OR nb = 0 THEN NULL
    ELSE round((2.0 * ni) / (na + nb), 4)
  END
  FROM counts;
$$;

COMMENT ON FUNCTION grantfit.dice_coefficient(text[], text[]) IS
  'Sørensen–Dice overlap of two token arrays. NULL when either side is empty. Case-insensitive.';

CREATE FUNCTION grantfit.evaluate_one(
  p_profile_id uuid,
  p_opportunity_id uuid,
  p_as_of date
)
RETURNS TABLE (
  eligible boolean,
  score numeric,
  topic_points numeric,
  keyword_points numeric,
  award_points numeric,
  recency_points numeric,
  status_points numeric,
  reasons text[],
  blocking_reasons text[]
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = grantfit, public, pg_temp
AS $$
DECLARE
  v_p grantfit.profiles%ROWTYPE;
  v_o grantfit.opportunities%ROWTYPE;
  v_reasons text[] := ARRAY[]::text[];
  v_blocking text[] := ARRAY[]::text[];
  v_topic numeric := 0;
  v_keyword numeric := 0;
  v_award numeric := 0;
  v_recency numeric := 0;
  v_status numeric := 0;
  v_dice numeric;
  v_closed boolean;
  v_nkeys integer;
  v_inter integer;
  v_overlap numeric;
  v_span numeric;
  v_award_block boolean := false;
BEGIN
  SELECT * INTO v_p FROM grantfit.profiles WHERE id = p_profile_id;
  SELECT * INTO v_o FROM grantfit.opportunities WHERE id = p_opportunity_id;
  IF v_p.id IS NULL OR v_o.id IS NULL THEN
    RETURN;
  END IF;

  v_closed := v_o.status = 'closed'
    OR (v_o.close_date IS NOT NULL AND v_o.close_date < p_as_of);
  IF v_closed THEN
    v_blocking := array_append(v_blocking, 'closed');
  ELSE
    v_reasons := array_append(v_reasons, CASE v_o.status
      WHEN 'open' THEN 'window_open'
      WHEN 'forecasted' THEN 'window_forecasted'
      ELSE 'window_unknown'
    END);
  END IF;

  IF 'unrestricted' = ANY(coalesce(v_o.eligible_applicants, '{}')) THEN
    v_reasons := array_append(v_reasons, 'applicant_unrestricted');
  ELSIF cardinality(coalesce(v_o.eligible_applicants, '{}')) = 0 THEN
    v_blocking := array_append(v_blocking, 'applicant_type_unspecified');
  ELSIF EXISTS (
    SELECT 1
    FROM unnest(v_p.organization_kinds) AS k
    WHERE k::text = ANY(v_o.eligible_applicants)
  ) THEN
    v_reasons := array_append(v_reasons, 'applicant_type_match');
  ELSE
    v_blocking := array_append(v_blocking, 'applicant_type_mismatch');
  END IF;

  IF v_o.geo_scope = 'national' THEN
    v_reasons := array_append(v_reasons, 'geo_national');
  ELSIF v_p.state_code IS NULL THEN
    v_reasons := array_append(v_reasons, 'geo_profile_national');
  ELSIF v_p.state_code = ANY(v_o.states) THEN
    v_reasons := array_append(v_reasons, 'geo_state_match');
  ELSE
    v_blocking := array_append(v_blocking, 'geo_mismatch');
  END IF;

  IF v_o.award_ceiling IS NOT NULL AND v_p.min_award IS NOT NULL
     AND v_o.award_ceiling < v_p.min_award THEN
    v_award_block := true;
  END IF;
  IF v_o.award_floor IS NOT NULL AND v_p.max_award IS NOT NULL
     AND v_o.award_floor > v_p.max_award THEN
    v_award_block := true;
  END IF;

  IF v_award_block THEN
    v_blocking := array_append(v_blocking, 'award_mismatch');
    v_award := 0;
  ELSIF v_p.min_award IS NULL OR v_p.max_award IS NULL
     OR v_o.award_floor IS NULL OR v_o.award_ceiling IS NULL THEN
    v_reasons := array_append(v_reasons, 'award_unconstrained');
    v_award := 8;
  ELSE
    v_reasons := array_append(v_reasons, 'award_overlap');
    v_overlap := LEAST(v_p.max_award, v_o.award_ceiling)
      - GREATEST(v_p.min_award, v_o.award_floor);
    v_span := v_o.award_ceiling - v_o.award_floor;
    IF v_span = 0 THEN
      v_award := 15;
    ELSE
      v_award := round(15 * v_overlap / v_span, 2);
    END IF;
  END IF;

  IF cardinality(coalesce(v_p.interests, '{}')) = 0 THEN
    v_reasons := array_append(v_reasons, 'kind_unconstrained');
  ELSIF v_o.kind::text = ANY(v_p.interests)
     OR (
       v_o.kind = 'grant'
       AND 'scholarship' = ANY(v_p.interests)
       AND 'scholarship_program' = ANY(coalesce(v_o.tags, '{}'))
     )
     OR (
       v_o.kind = 'grant'
       AND 'fellowship' = ANY(v_p.interests)
       AND 'fellowship_program' = ANY(coalesce(v_o.tags, '{}'))
     )
  THEN
    v_reasons := array_append(v_reasons, 'kind_match');
  ELSE
    v_blocking := array_append(v_blocking, 'kind_mismatch');
  END IF;

  v_dice := grantfit.dice_coefficient(v_p.topics, v_o.topics);
  IF v_dice IS NULL THEN
    v_topic := 10;
  ELSE
    v_topic := round(40 * v_dice, 2);
  END IF;

  SELECT count(*) INTO v_nkeys
  FROM (
    SELECT DISTINCT lower(btrim(x)) AS t
    FROM unnest(coalesce(v_p.keywords, '{}')) AS x
    WHERE btrim(coalesce(x, '')) <> ''
  ) AS s;

  IF v_nkeys = 0 THEN
    v_keyword := 8;
  ELSE
    SELECT count(*) INTO v_inter
    FROM (
      SELECT DISTINCT lower(btrim(x)) AS t
      FROM unnest(coalesce(v_p.keywords, '{}')) AS x
      WHERE btrim(coalesce(x, '')) <> ''
      INTERSECT
      SELECT DISTINCT lower(btrim(y)) AS t
      FROM unnest(coalesce(v_o.keywords, '{}')) AS y
      WHERE btrim(coalesce(y, '')) <> ''
    ) AS s;
    v_keyword := round(25 * v_inter::numeric / v_nkeys::numeric, 2);
  END IF;

  IF v_o.open_date IS NULL THEN
    v_recency := 4;
  ELSIF v_o.open_date > p_as_of THEN
    v_recency := 6;
  ELSIF (p_as_of - v_o.open_date) <= 30 THEN
    v_recency := 10;
  ELSIF (p_as_of - v_o.open_date) <= 120 THEN
    v_recency := 7;
  ELSIF (p_as_of - v_o.open_date) <= 365 THEN
    v_recency := 4;
  ELSE
    v_recency := 2;
  END IF;

  v_status := CASE v_o.status
    WHEN 'open' THEN 10
    WHEN 'forecasted' THEN 6
    WHEN 'unknown' THEN 3
    ELSE 0
  END;

  eligible := cardinality(v_blocking) = 0;
  score := round(v_topic + v_keyword + v_award + v_recency + v_status, 2);
  topic_points := v_topic;
  keyword_points := v_keyword;
  award_points := v_award;
  recency_points := v_recency;
  status_points := v_status;
  reasons := v_reasons;
  blocking_reasons := v_blocking;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION grantfit.evaluate_one(uuid, uuid, date) IS
  'Eligibility and score for one profile/notice pair. Score is still returned when the pair is ineligible.';

CREATE TYPE grantfit.match_result AS (
  bucket text,
  rank integer,
  opportunity_id uuid,
  source text,
  external_id text,
  title text,
  agency text,
  kind text,
  status text,
  score numeric,
  topic_points numeric,
  keyword_points numeric,
  award_points numeric,
  recency_points numeric,
  status_points numeric,
  reasons text[],
  blocking_reasons text[],
  open_date date,
  close_date date,
  award_floor numeric,
  award_ceiling numeric,
  topics text[],
  eligible_applicants text[],
  states text[],
  geo_scope text,
  tags text[],
  eligibility_basis text,
  url text,
  summary text
);

CREATE FUNCTION grantfit.match_profile(
  p_slug text,
  p_eligible_limit integer DEFAULT 10,
  p_near_miss_limit integer DEFAULT 5,
  p_as_of date DEFAULT CURRENT_DATE,
  p_source text DEFAULT NULL
)
RETURNS SETOF grantfit.match_result
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = grantfit, public, pg_temp
AS $$
  WITH prof AS (
    SELECT * FROM grantfit.profiles WHERE slug = p_slug
  ),
  scored AS MATERIALIZED (
    SELECT
      o.id AS opportunity_id,
      o.source,
      o.external_id,
      o.title,
      o.agency,
      o.kind::text AS kind,
      o.status::text AS status,
      ev.score,
      ev.topic_points,
      ev.keyword_points,
      ev.award_points,
      ev.recency_points,
      ev.status_points,
      ev.reasons,
      ev.blocking_reasons,
      ev.eligible,
      o.open_date,
      o.close_date,
      o.award_floor,
      o.award_ceiling,
      o.topics,
      o.eligible_applicants,
      o.states,
      o.geo_scope::text AS geo_scope,
      o.tags,
      o.eligibility_basis,
      o.url,
      o.summary
    FROM prof AS p
    JOIN grantfit.opportunities AS o
      ON (p_source IS NULL OR o.source = p_source)
    CROSS JOIN LATERAL grantfit.evaluate_one(p.id, o.id, p_as_of) AS ev
  ),
  eligible_rows AS (
    SELECT *
    FROM scored
    WHERE eligible
    ORDER BY score DESC, close_date NULLS LAST, external_id
    LIMIT LEAST(GREATEST(coalesce(p_eligible_limit, 0), 0), 100)
  ),
  near_rows AS (
    SELECT *
    FROM scored
    WHERE NOT eligible
    ORDER BY score DESC, close_date NULLS LAST, external_id
    LIMIT LEAST(GREATEST(coalesce(p_near_miss_limit, 0), 0), 100)
  ),
  ranked AS (
    SELECT
      'eligible'::text AS bucket,
      row_number() OVER (
        ORDER BY score DESC, close_date NULLS LAST, external_id
      )::integer AS rank,
      e.*
    FROM eligible_rows AS e
    UNION ALL
    SELECT
      'near_miss'::text,
      row_number() OVER (
        ORDER BY score DESC, close_date NULLS LAST, external_id
      )::integer,
      n.*
    FROM near_rows AS n
  )
  SELECT
    bucket,
    rank,
    opportunity_id,
    source,
    external_id,
    title,
    agency,
    kind,
    status,
    score,
    topic_points,
    keyword_points,
    award_points,
    recency_points,
    status_points,
    reasons,
    blocking_reasons,
    open_date,
    close_date,
    award_floor,
    award_ceiling,
    topics,
    eligible_applicants,
    states,
    geo_scope,
    tags,
    eligibility_basis,
    url,
    summary
  FROM ranked
  ORDER BY CASE bucket WHEN 'eligible' THEN 0 ELSE 1 END, rank;
$$;

COMMENT ON FUNCTION grantfit.match_profile(text, integer, integer, date, text) IS
  'Ranked eligible notices for a profile slug, then near misses. p_source limits rows to one loader (seed, grants_gov). Unknown or RLS-hidden slugs return no rows.';
