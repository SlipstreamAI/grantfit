-- Row level security and the PostgREST-facing wrappers in public.

ALTER TABLE grantfit.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE grantfit.profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE grantfit.opportunities ENABLE ROW LEVEL SECURITY;
ALTER TABLE grantfit.opportunities FORCE ROW LEVEL SECURITY;
ALTER TABLE grantfit.provider_budgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE grantfit.provider_budgets FORCE ROW LEVEL SECURITY;
ALTER TABLE grantfit.http_cache ENABLE ROW LEVEL SECURITY;
ALTER TABLE grantfit.http_cache FORCE ROW LEVEL SECURITY;
ALTER TABLE grantfit.sync_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE grantfit.sync_runs FORCE ROW LEVEL SECURITY;
ALTER TABLE grantfit.sync_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE grantfit.sync_requests FORCE ROW LEVEL SECURITY;
ALTER TABLE grantfit.sync_queries ENABLE ROW LEVEL SECURITY;
ALTER TABLE grantfit.sync_queries FORCE ROW LEVEL SECURITY;

CREATE POLICY profiles_read ON grantfit.profiles
  FOR SELECT
  USING (is_demo OR owner_id = auth.uid());

CREATE POLICY profiles_insert ON grantfit.profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (
    owner_id IS NOT NULL
    AND owner_id = auth.uid()
    AND is_demo = false
  );

CREATE POLICY profiles_update ON grantfit.profiles
  FOR UPDATE
  TO authenticated
  USING (owner_id = auth.uid() AND is_demo = false)
  WITH CHECK (owner_id = auth.uid() AND is_demo = false);

CREATE POLICY opportunities_read ON grantfit.opportunities
  FOR SELECT
  USING (true);

GRANT SELECT ON grantfit.profiles TO anon, authenticated, service_role, grantfit_demo;
GRANT INSERT, UPDATE ON grantfit.profiles TO authenticated;
GRANT SELECT ON grantfit.opportunities TO anon, authenticated, service_role, grantfit_demo;

CREATE FUNCTION grantfit.sync_health()
RETURNS TABLE (
  provider text,
  daily_request_budget integer,
  requests_used integer,
  remaining integer,
  window_started_at timestamptz,
  high_water_date date,
  last_success_at timestamptz,
  last_run_status text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
  SELECT
    b.provider,
    b.daily_request_budget,
    b.requests_used,
    GREATEST(b.daily_request_budget - b.requests_used, 0) AS remaining,
    b.window_started_at,
    b.high_water_date,
    b.last_success_at,
    b.last_run_status
  FROM grantfit.provider_budgets AS b
  ORDER BY b.provider;
$$;

COMMENT ON FUNCTION grantfit.sync_health() IS
  'Non-secret sync budget snapshot. Does not expose ETags, cache bodies, or error text.';

REVOKE ALL ON FUNCTION grantfit.sync_health() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION grantfit.sync_health() TO anon, authenticated, service_role, grantfit_demo, grantfit_worker;

REVOKE ALL ON FUNCTION grantfit.dice_coefficient(text[], text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.evaluate_one(uuid, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.match_profile(text, integer, integer, date, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION grantfit.dice_coefficient(text[], text[]) TO anon, authenticated, service_role, grantfit_demo, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.evaluate_one(uuid, uuid, date) TO anon, authenticated, service_role, grantfit_demo, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.match_profile(text, integer, integer, date, text) TO anon, authenticated, service_role, grantfit_demo, grantfit_worker;

CREATE FUNCTION public.match_profile(
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
  SELECT *
  FROM grantfit.match_profile(p_slug, p_eligible_limit, p_near_miss_limit, p_as_of, p_source);
$$;

CREATE FUNCTION public.sync_health()
RETURNS TABLE (
  provider text,
  daily_request_budget integer,
  requests_used integer,
  remaining integer,
  window_started_at timestamptz,
  high_water_date date,
  last_success_at timestamptz,
  last_run_status text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = grantfit, public, pg_temp
AS $$
  SELECT * FROM grantfit.sync_health();
$$;

CREATE FUNCTION public.upsert_opportunities(p_items jsonb)
RETURNS TABLE(external_id text, action text)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
  SELECT * FROM grantfit.upsert_opportunities(p_items);
$$;

COMMENT ON FUNCTION public.match_profile(text, integer, integer, date, text) IS
  'PostgREST wrapper. Respects RLS, so anon only matches demo profiles or their own.';

REVOKE ALL ON FUNCTION public.match_profile(text, integer, integer, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_health() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_opportunities(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.match_profile(text, integer, integer, date, text) TO anon, authenticated, service_role, grantfit_demo, grantfit_worker;
GRANT EXECUTE ON FUNCTION public.sync_health() TO anon, authenticated, service_role, grantfit_demo, grantfit_worker;
GRANT EXECUTE ON FUNCTION public.upsert_opportunities(jsonb) TO service_role, grantfit_worker;

CREATE VIEW public.demo_profiles
WITH (security_invoker = true) AS
SELECT
  id,
  slug,
  display_name,
  organization_name,
  summary,
  organization_kinds::text[] AS organization_kinds,
  state_code,
  topics,
  keywords,
  min_award,
  max_award,
  interests
FROM grantfit.profiles
WHERE is_demo;

COMMENT ON VIEW public.demo_profiles IS
  'Demo profiles only. security_invoker so RLS still applies.';

GRANT SELECT ON public.demo_profiles TO anon, authenticated, service_role, grantfit_demo;
