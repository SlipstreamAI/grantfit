-- Idempotent upserts, shared request budgets, and the HTTP validator cache.
-- Sync workers (Python, Edge Function) call these instead of writing tables directly.

CREATE FUNCTION grantfit.text_set(p jsonb)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(ARRAY(
    SELECT DISTINCT lower(btrim(value))
    FROM jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(p) = 'array' THEN p ELSE '[]'::jsonb END
    ) AS value
    WHERE btrim(value) <> ''
    ORDER BY 1
  ), ARRAY[]::text[]);
$$;

CREATE FUNCTION grantfit.state_set(p jsonb)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT COALESCE(ARRAY(
    SELECT DISTINCT upper(btrim(value))
    FROM jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(p) = 'array' THEN p ELSE '[]'::jsonb END
    ) AS value
    WHERE btrim(value) <> ''
    ORDER BY 1
  ), ARRAY[]::text[]);
$$;

CREATE FUNCTION grantfit.opportunity_fingerprint(
  p_source text,
  p_external_id text,
  p_opportunity_number text,
  p_title text,
  p_summary text,
  p_agency text,
  p_agency_code text,
  p_kind text,
  p_status text,
  p_open_date date,
  p_close_date date,
  p_award_floor numeric,
  p_award_ceiling numeric,
  p_estimated_funding numeric,
  p_eligible_applicants text[],
  p_eligibility_basis text,
  p_topics text[],
  p_keywords text[],
  p_geo_scope text,
  p_states text[],
  p_tags text[],
  p_url text,
  p_list_fingerprint text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(digest(convert_to(concat_ws(
    E'\x1f',
    coalesce(p_source, ''),
    coalesce(p_external_id, ''),
    coalesce(p_opportunity_number, ''),
    coalesce(p_title, ''),
    coalesce(p_summary, ''),
    coalesce(p_agency, ''),
    coalesce(p_agency_code, ''),
    coalesce(p_kind, ''),
    coalesce(p_status, ''),
    coalesce(p_open_date::text, ''),
    coalesce(p_close_date::text, ''),
    coalesce(to_char(p_award_floor, 'FM999999999999990.00'), ''),
    coalesce(to_char(p_award_ceiling, 'FM999999999999990.00'), ''),
    coalesce(to_char(p_estimated_funding, 'FM999999999999990.00'), ''),
    array_to_string(coalesce(p_eligible_applicants, '{}'), ','),
    coalesce(p_eligibility_basis, ''),
    array_to_string(coalesce(p_topics, '{}'), ','),
    array_to_string(coalesce(p_keywords, '{}'), ','),
    coalesce(p_geo_scope, ''),
    array_to_string(coalesce(p_states, '{}'), ','),
    array_to_string(coalesce(p_tags, '{}'), ','),
    coalesce(p_url, ''),
    coalesce(p_list_fingerprint, '')
  ), 'UTF8'), 'sha256'), 'hex');
$$;

CREATE FUNCTION grantfit.upsert_opportunities(p_items jsonb)
RETURNS TABLE(external_id text, action text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
DECLARE
  item jsonb;
  v_source text;
  v_external_id text;
  v_number text;
  v_title text;
  v_summary text;
  v_agency text;
  v_agency_code text;
  v_kind grantfit.opportunity_kind;
  v_status grantfit.opportunity_status;
  v_open date;
  v_close date;
  v_floor numeric;
  v_ceiling numeric;
  v_estimated numeric;
  v_applicants text[];
  v_basis text;
  v_topics text[];
  v_keywords text[];
  v_geo grantfit.geo_scope;
  v_states text[];
  v_tags text[];
  v_url text;
  v_fingerprint text;
  v_raw jsonb;
  v_hash text;
  v_old text;
  v_action text;
BEGIN
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'upsert_opportunities expects a JSON array';
  END IF;

  FOR item IN
    SELECT value FROM jsonb_array_elements(p_items) AS t(value)
  LOOP
    v_source := btrim(coalesce(item->>'source', ''));
    v_external_id := btrim(coalesce(item->>'external_id', ''));
    IF v_source = '' OR v_external_id = '' THEN
      RAISE EXCEPTION 'source and external_id are required';
    END IF;

    v_title := btrim(coalesce(item->>'title', ''));
    IF v_title = '' THEN
      RAISE EXCEPTION 'title is required';
    END IF;

    v_number := NULLIF(btrim(coalesce(item->>'opportunity_number', '')), '');
    v_summary := left(coalesce(item->>'summary', ''), 8000);
    v_agency := coalesce(item->>'agency', '');
    v_agency_code := coalesce(item->>'agency_code', '');
    v_kind := (item->>'kind')::grantfit.opportunity_kind;
    v_status := (item->>'status')::grantfit.opportunity_status;
    v_open := NULLIF(item->>'open_date', '')::date;
    v_close := NULLIF(item->>'close_date', '')::date;
    v_floor := NULLIF(item->>'award_floor', '')::numeric;
    v_ceiling := NULLIF(item->>'award_ceiling', '')::numeric;
    v_estimated := NULLIF(item->>'estimated_funding', '')::numeric;
    v_applicants := grantfit.text_set(item->'eligible_applicants');
    v_basis := coalesce(NULLIF(item->>'eligibility_basis', ''), 'structured');
    v_topics := grantfit.text_set(item->'topics');
    v_keywords := grantfit.text_set(item->'keywords');
    v_geo := coalesce(NULLIF(item->>'geo_scope', ''), 'national')::grantfit.geo_scope;
    v_states := grantfit.state_set(item->'states');
    v_tags := grantfit.text_set(item->'tags');
    v_url := NULLIF(item->>'url', '');
    v_fingerprint := NULLIF(item->>'list_fingerprint', '');
    v_raw := CASE
      WHEN jsonb_typeof(item->'raw') = 'object' THEN (item->'raw') - 'token'
      ELSE '{}'::jsonb
    END;

    v_hash := grantfit.opportunity_fingerprint(
      v_source, v_external_id, v_number, v_title, v_summary, v_agency, v_agency_code,
      v_kind::text, v_status::text, v_open, v_close, v_floor, v_ceiling, v_estimated,
      v_applicants, v_basis, v_topics, v_keywords, v_geo::text, v_states, v_tags,
      v_url, v_fingerprint
    );

    SELECT o.content_hash INTO v_old
    FROM grantfit.opportunities AS o
    WHERE o.source = v_source AND o.external_id = v_external_id
    FOR UPDATE;

    IF NOT FOUND THEN
      BEGIN
        INSERT INTO grantfit.opportunities (
          source, external_id, opportunity_number, title, summary, agency, agency_code,
          kind, status, open_date, close_date, award_floor, award_ceiling, estimated_funding,
          eligible_applicants, eligibility_basis, topics, keywords, geo_scope, states, tags,
          url, list_fingerprint, content_hash, raw
        ) VALUES (
          v_source, v_external_id, v_number, v_title, v_summary, v_agency, v_agency_code,
          v_kind, v_status, v_open, v_close, v_floor, v_ceiling, v_estimated,
          v_applicants, v_basis, v_topics, v_keywords, v_geo, v_states, v_tags,
          v_url, v_fingerprint, v_hash, v_raw
        );
        v_action := 'inserted';
      EXCEPTION WHEN unique_violation THEN
        UPDATE grantfit.opportunities AS o
        SET opportunity_number = v_number,
            title = v_title,
            summary = v_summary,
            agency = v_agency,
            agency_code = v_agency_code,
            kind = v_kind,
            status = v_status,
            open_date = v_open,
            close_date = v_close,
            award_floor = v_floor,
            award_ceiling = v_ceiling,
            estimated_funding = v_estimated,
            eligible_applicants = v_applicants,
            eligibility_basis = v_basis,
            topics = v_topics,
            keywords = v_keywords,
            geo_scope = v_geo,
            states = v_states,
            tags = v_tags,
            url = v_url,
            list_fingerprint = v_fingerprint,
            content_hash = v_hash,
            raw = v_raw,
            updated_at = now(),
            fetched_at = now()
        WHERE o.source = v_source
          AND o.external_id = v_external_id
          AND o.content_hash IS DISTINCT FROM v_hash;
        IF FOUND THEN
          v_action := 'updated';
        ELSE
          v_action := 'unchanged';
        END IF;
      END;
    ELSIF v_old IS NOT DISTINCT FROM v_hash THEN
      v_action := 'unchanged';
    ELSE
      UPDATE grantfit.opportunities AS o
      SET opportunity_number = v_number,
          title = v_title,
          summary = v_summary,
          agency = v_agency,
          agency_code = v_agency_code,
          kind = v_kind,
          status = v_status,
          open_date = v_open,
          close_date = v_close,
          award_floor = v_floor,
          award_ceiling = v_ceiling,
          estimated_funding = v_estimated,
          eligible_applicants = v_applicants,
          eligibility_basis = v_basis,
          topics = v_topics,
          keywords = v_keywords,
          geo_scope = v_geo,
          states = v_states,
          tags = v_tags,
          url = v_url,
          list_fingerprint = v_fingerprint,
          content_hash = v_hash,
          raw = v_raw,
          updated_at = now(),
          fetched_at = now()
      WHERE o.source = v_source AND o.external_id = v_external_id;
      v_action := 'updated';
    END IF;

    external_id := v_external_id;
    action := v_action;
    RETURN NEXT;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION grantfit.upsert_opportunities(jsonb) IS
  'Insert or update notices. Returns unchanged and does not write when the content hash matches. Strips raw.token so session JWTs are not stored.';

CREATE FUNCTION grantfit.try_consume_request(p_provider text, p_cost integer DEFAULT 1)
RETURNS TABLE(allowed boolean, remaining integer, retry_after_ms integer, reason text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
DECLARE
  v_row grantfit.provider_budgets%ROWTYPE;
  v_elapsed_ms bigint;
BEGIN
  IF p_cost IS NULL OR p_cost < 1 THEN
    RAISE EXCEPTION 'cost must be a positive integer';
  END IF;

  SELECT * INTO v_row
  FROM grantfit.provider_budgets
  WHERE provider = p_provider
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown provider: %', p_provider;
  END IF;

  IF (v_row.window_started_at AT TIME ZONE 'UTC')::date
     < (now() AT TIME ZONE 'UTC')::date THEN
    UPDATE grantfit.provider_budgets
    SET requests_used = 0,
        window_started_at = now()
    WHERE provider = p_provider
    RETURNING * INTO v_row;
  END IF;

  IF v_row.last_request_at IS NOT NULL AND v_row.min_interval_ms > 0 THEN
    v_elapsed_ms := floor(EXTRACT(EPOCH FROM (now() - v_row.last_request_at)) * 1000)::bigint;
    IF v_elapsed_ms < v_row.min_interval_ms THEN
      allowed := false;
      remaining := v_row.daily_request_budget - v_row.requests_used;
      retry_after_ms := (v_row.min_interval_ms - v_elapsed_ms)::integer;
      reason := 'rate_limited';
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  IF v_row.requests_used + p_cost > v_row.daily_request_budget THEN
    allowed := false;
    remaining := v_row.daily_request_budget - v_row.requests_used;
    retry_after_ms := 0;
    reason := 'budget_exhausted';
    RETURN NEXT;
    RETURN;
  END IF;

  UPDATE grantfit.provider_budgets
  SET requests_used = requests_used + p_cost,
      last_request_at = now()
  WHERE provider = p_provider
  RETURNING * INTO v_row;

  allowed := true;
  remaining := v_row.daily_request_budget - v_row.requests_used;
  retry_after_ms := 0;
  reason := 'ok';
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION grantfit.try_consume_request(text, integer) IS
  'Atomically spends daily budget. Returns rate_limited without spending when min_interval_ms has not elapsed. Resets the counter on a new UTC day.';

CREATE FUNCTION grantfit.get_http_cache(p_key text)
RETURNS TABLE(etag text, last_modified text, body_sha256 text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
  SELECT c.etag, c.last_modified, c.body_sha256
  FROM grantfit.http_cache AS c
  WHERE c.cache_key = p_key;
$$;

CREATE FUNCTION grantfit.put_http_cache(
  p_key text,
  p_etag text,
  p_last_modified text,
  p_body_sha256 text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
  INSERT INTO grantfit.http_cache (cache_key, etag, last_modified, body_sha256)
  VALUES (p_key, p_etag, p_last_modified, p_body_sha256)
  ON CONFLICT (cache_key) DO UPDATE
  SET etag = EXCLUDED.etag,
      last_modified = EXCLUDED.last_modified,
      body_sha256 = EXCLUDED.body_sha256,
      stored_at = now();
$$;

CREATE FUNCTION grantfit.touch_http_cache(p_key text)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
  UPDATE grantfit.http_cache
  SET hit_count = hit_count + 1
  WHERE cache_key = p_key;
$$;

CREATE FUNCTION grantfit.list_fingerprints(p_source text, p_ids text[])
RETURNS TABLE(external_id text, list_fingerprint text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
  SELECT o.external_id, o.list_fingerprint
  FROM grantfit.opportunities AS o
  WHERE o.source = p_source
    AND o.external_id = ANY(coalesce(p_ids, ARRAY[]::text[]));
$$;

CREATE FUNCTION grantfit.note_high_water(p_provider text, p_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
BEGIN
  IF p_date IS NULL THEN
    RETURN;
  END IF;
  UPDATE grantfit.provider_budgets
  SET high_water_date = CASE
    WHEN high_water_date IS NULL THEN p_date
    ELSE GREATEST(high_water_date, p_date)
  END
  WHERE provider = p_provider;
END;
$$;

CREATE FUNCTION grantfit.enabled_queries(p_provider text)
RETURNS TABLE(keyword text, statuses text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
  SELECT q.keyword, q.statuses
  FROM grantfit.sync_queries AS q
  WHERE q.provider = p_provider AND q.enabled
  ORDER BY q.id;
$$;

CREATE FUNCTION grantfit.start_sync_run(p_provider text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  INSERT INTO grantfit.sync_runs (provider)
  VALUES (p_provider)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE FUNCTION grantfit.finish_sync_run(
  p_id uuid,
  p_status text,
  p_requests integer,
  p_inserted integer,
  p_updated integer,
  p_unchanged integer,
  p_skipped integer,
  p_error text,
  p_detail jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
DECLARE
  v_provider text;
BEGIN
  IF p_status NOT IN ('success', 'partial', 'failed', 'budget_stopped') THEN
    RAISE EXCEPTION 'invalid sync status: %', p_status;
  END IF;

  UPDATE grantfit.sync_runs
  SET finished_at = now(),
      status = p_status,
      requests_made = coalesce(p_requests, 0),
      records_inserted = coalesce(p_inserted, 0),
      records_updated = coalesce(p_updated, 0),
      records_unchanged = coalesce(p_unchanged, 0),
      records_skipped = coalesce(p_skipped, 0),
      error = p_error,
      detail = coalesce(p_detail, '{}'::jsonb)
  WHERE id = p_id
  RETURNING provider INTO v_provider;

  IF v_provider IS NOT NULL THEN
    UPDATE grantfit.provider_budgets
    SET last_run_status = p_status,
        last_success_at = CASE
          WHEN p_status IN ('success', 'partial', 'budget_stopped') THEN now()
          ELSE last_success_at
        END
    WHERE provider = v_provider;
  END IF;
END;
$$;

CREATE FUNCTION grantfit.enqueue_sync(p_provider text, p_reason text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  BEGIN
    INSERT INTO grantfit.sync_requests (provider, reason)
    VALUES (p_provider, coalesce(NULLIF(p_reason, ''), 'manual'))
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT id INTO v_id
    FROM grantfit.sync_requests
    WHERE provider = p_provider AND status IN ('pending', 'claimed')
    ORDER BY created_at
    LIMIT 1;
  END;
  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION grantfit.enqueue_sync(text, text) IS
  'Insert a pending sync request unless one is already pending or claimed for the provider.';

CREATE FUNCTION grantfit.claim_sync_request(p_provider text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  UPDATE grantfit.sync_requests
  SET status = 'claimed',
      claimed_at = now()
  WHERE id = (
    SELECT id
    FROM grantfit.sync_requests
    WHERE provider = p_provider AND status = 'pending'
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  )
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE FUNCTION grantfit.complete_sync_request(p_id uuid, p_status text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = grantfit, public, pg_temp
AS $$
BEGIN
  IF p_id IS NULL THEN
    RETURN;
  END IF;
  IF p_status NOT IN ('done', 'failed') THEN
    RAISE EXCEPTION 'invalid request status: %', p_status;
  END IF;
  UPDATE grantfit.sync_requests
  SET status = p_status,
      finished_at = now()
  WHERE id = p_id;
END;
$$;

REVOKE ALL ON FUNCTION grantfit.upsert_opportunities(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.try_consume_request(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.get_http_cache(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.put_http_cache(text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.touch_http_cache(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.list_fingerprints(text, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.note_high_water(text, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.enabled_queries(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.start_sync_run(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.finish_sync_run(uuid, text, integer, integer, integer, integer, integer, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.enqueue_sync(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.claim_sync_request(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION grantfit.complete_sync_request(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION grantfit.upsert_opportunities(jsonb) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.try_consume_request(text, integer) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.get_http_cache(text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.put_http_cache(text, text, text, text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.touch_http_cache(text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.list_fingerprints(text, text[]) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.note_high_water(text, date) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.enabled_queries(text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.start_sync_run(text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.finish_sync_run(uuid, text, integer, integer, integer, integer, integer, text, jsonb) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.enqueue_sync(text, text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.claim_sync_request(text) TO service_role, grantfit_worker;
GRANT EXECUTE ON FUNCTION grantfit.complete_sync_request(uuid, text) TO service_role, grantfit_worker;
