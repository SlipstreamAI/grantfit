-- PostgREST wrappers for the sync worker. service_role and grantfit_worker only.
-- The Python worker calls grantfit.* directly; the Edge Function uses these names.

CREATE FUNCTION public.try_consume_request(p_provider text, p_cost integer DEFAULT 1)
RETURNS TABLE(allowed boolean, remaining integer, retry_after_ms integer, reason text)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$ SELECT * FROM grantfit.try_consume_request(p_provider, p_cost); $$;

CREATE FUNCTION public.get_http_cache(p_key text)
RETURNS TABLE(etag text, last_modified text, body_sha256 text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$ SELECT * FROM grantfit.get_http_cache(p_key); $$;

CREATE FUNCTION public.put_http_cache(p_key text, p_etag text, p_last_modified text, p_body_sha256 text)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$ SELECT grantfit.put_http_cache(p_key, p_etag, p_last_modified, p_body_sha256); $$;

CREATE FUNCTION public.touch_http_cache(p_key text)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$ SELECT grantfit.touch_http_cache(p_key); $$;

CREATE FUNCTION public.list_fingerprints(p_source text, p_ids text[])
RETURNS TABLE(external_id text, list_fingerprint text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$ SELECT * FROM grantfit.list_fingerprints(p_source, p_ids); $$;

CREATE FUNCTION public.start_sync_run(p_provider text)
RETURNS uuid
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$ SELECT grantfit.start_sync_run(p_provider); $$;

CREATE FUNCTION public.finish_sync_run(
  p_id uuid, p_status text, p_requests integer, p_inserted integer,
  p_updated integer, p_unchanged integer, p_skipped integer, p_error text, p_detail jsonb
)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
  SELECT grantfit.finish_sync_run(
    p_id, p_status, p_requests, p_inserted, p_updated, p_unchanged, p_skipped, p_error, p_detail
  );
$$;

CREATE FUNCTION public.note_high_water(p_provider text, p_date date)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$ SELECT grantfit.note_high_water(p_provider, p_date); $$;

REVOKE ALL ON FUNCTION public.try_consume_request(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_http_cache(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.put_http_cache(text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.touch_http_cache(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_fingerprints(text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.start_sync_run(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finish_sync_run(uuid, text, integer, integer, integer, integer, integer, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.note_high_water(text, date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.try_consume_request(text, integer) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION public.get_http_cache(text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION public.put_http_cache(text, text, text, text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION public.touch_http_cache(text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION public.list_fingerprints(text, text[]) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION public.start_sync_run(text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION public.finish_sync_run(uuid, text, integer, integer, integer, integer, integer, text, jsonb) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION public.note_high_water(text, date) TO service_role, grantfit_worker;
