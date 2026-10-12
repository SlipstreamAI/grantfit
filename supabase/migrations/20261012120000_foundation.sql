-- GrantFit foundation: portable roles, tables, and cost-control storage.
-- Applies on Supabase (auth schema already present) and on plain Postgres 16+.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grantfit_demo') THEN
    CREATE ROLE grantfit_demo NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grantfit_worker') THEN
    CREATE ROLE grantfit_worker NOLOGIN NOINHERIT;
  END IF;
END
$roles$;

DO $auth$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'auth') THEN
    CREATE SCHEMA auth;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'auth' AND p.proname = 'uid'
  ) THEN
    CREATE FUNCTION auth.uid() RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $fn$
      SELECT COALESCE(
        NULLIF(current_setting('request.jwt.claim.sub', true), ''),
        NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
      )::uuid;
    $fn$;
  END IF;
END
$auth$;

CREATE SCHEMA IF NOT EXISTS grantfit;
REVOKE ALL ON SCHEMA grantfit FROM PUBLIC;

COMMENT ON SCHEMA grantfit IS
  'Federal grant and scholarship matching. Eligibility and scores are SQL; sync workers only normalize and upsert.';

DO $usage$
BEGIN
  GRANT USAGE ON SCHEMA grantfit TO anon, authenticated, service_role;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grantfit_demo') THEN
    GRANT USAGE ON SCHEMA grantfit TO grantfit_demo;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grantfit_worker') THEN
    GRANT USAGE ON SCHEMA grantfit TO grantfit_worker;
  END IF;
END
$usage$;

CREATE TYPE grantfit.organization_kind AS ENUM (
  'individual',
  'nonprofit',
  'university',
  'small_business',
  'for_profit',
  'state_government',
  'local_government',
  'special_district',
  'school_district',
  'tribal_government',
  'tribal_organization',
  'housing_authority'
);

CREATE TYPE grantfit.opportunity_kind AS ENUM (
  'grant',
  'cooperative_agreement',
  'scholarship',
  'fellowship',
  'loan',
  'other'
);

CREATE TYPE grantfit.opportunity_status AS ENUM (
  'forecasted',
  'open',
  'closed',
  'unknown'
);

CREATE TYPE grantfit.geo_scope AS ENUM (
  'national',
  'state'
);

CREATE TABLE grantfit.profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid,
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9-]+$'),
  display_name text NOT NULL,
  organization_name text NOT NULL,
  summary text NOT NULL DEFAULT '',
  organization_kinds grantfit.organization_kind[] NOT NULL,
  state_code text,
  topics text[] NOT NULL DEFAULT '{}',
  keywords text[] NOT NULL DEFAULT '{}',
  min_award numeric(14,2),
  max_award numeric(14,2),
  interests text[] NOT NULL DEFAULT '{}',
  is_demo boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT profile_kinds_present CHECK (cardinality(organization_kinds) > 0),
  CONSTRAINT profile_state CHECK (state_code IS NULL OR state_code ~ '^[A-Z]{2}$'),
  CONSTRAINT profile_award_bounds CHECK (
    min_award IS NULL OR max_award IS NULL OR min_award <= max_award
  ),
  CONSTRAINT profile_interests_known CHECK (
    interests <@ ARRAY[
      'grant', 'cooperative_agreement', 'scholarship', 'fellowship', 'loan', 'other'
    ]::text[]
  )
);

COMMENT ON TABLE grantfit.profiles IS
  'Applicant profiles. organization_kinds, state, award bounds, and interests are hard eligibility inputs. topics and keywords only affect score.';

COMMENT ON COLUMN grantfit.profiles.state_code IS
  'USPS code. NULL means the applicant can perform work in any state.';

COMMENT ON COLUMN grantfit.profiles.min_award IS
  'Smallest award the applicant wants to administer. NULL leaves that side unconstrained.';

CREATE FUNCTION grantfit.states_are_codes(p_states text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM unnest(coalesce(p_states, ARRAY[]::text[])) AS s
    WHERE s !~ '^[A-Z]{2}$'
  );
$$;

CREATE TABLE grantfit.opportunities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source text NOT NULL CHECK (source <> ''),
  external_id text NOT NULL CHECK (external_id <> ''),
  opportunity_number text,
  title text NOT NULL CHECK (title <> ''),
  summary text NOT NULL DEFAULT '',
  agency text NOT NULL DEFAULT '',
  agency_code text NOT NULL DEFAULT '',
  kind grantfit.opportunity_kind NOT NULL,
  status grantfit.opportunity_status NOT NULL,
  open_date date,
  close_date date,
  award_floor numeric(14,2),
  award_ceiling numeric(14,2),
  estimated_funding numeric(14,2),
  eligible_applicants text[] NOT NULL DEFAULT '{}',
  eligibility_basis text NOT NULL DEFAULT 'structured',
  topics text[] NOT NULL DEFAULT '{}',
  keywords text[] NOT NULL DEFAULT '{}',
  geo_scope grantfit.geo_scope NOT NULL DEFAULT 'national',
  states text[] NOT NULL DEFAULT '{}',
  tags text[] NOT NULL DEFAULT '{}',
  url text,
  list_fingerprint text,
  content_hash text NOT NULL,
  raw jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  fetched_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, external_id),
  CONSTRAINT award_bounds CHECK (
    award_floor IS NULL OR award_ceiling IS NULL OR award_floor <= award_ceiling
  ),
  CONSTRAINT geo_states CHECK (
    (geo_scope = 'national' AND cardinality(states) = 0)
    OR (geo_scope = 'state' AND cardinality(states) > 0)
  ),
  CONSTRAINT states_are_codes CHECK (grantfit.states_are_codes(states)),
  CONSTRAINT eligibility_basis_known CHECK (
    eligibility_basis IN ('structured', 'narrative', 'unrestricted', 'see_text')
  ),
  CONSTRAINT eligible_applicants_known CHECK (
    eligible_applicants <@ ARRAY[
      'individual', 'nonprofit', 'university', 'small_business', 'for_profit',
      'state_government', 'local_government', 'special_district', 'school_district',
      'tribal_government', 'tribal_organization', 'housing_authority', 'unrestricted'
    ]::text[]
  ),
  CONSTRAINT tags_known CHECK (
    tags <@ ARRAY['scholarship_program', 'fellowship_program']::text[]
  )
);

COMMENT ON TABLE grantfit.opportunities IS
  'Normalized notices. source+external_id is the idempotency key. content_hash skips unchanged rewrites.';

COMMENT ON COLUMN grantfit.opportunities.eligible_applicants IS
  'Organization kinds, plus the sentinel unrestricted. An empty array means eligibility was not determined (fail closed).';

COMMENT ON COLUMN grantfit.opportunities.list_fingerprint IS
  'Hash of the search-hit fields. When it matches, the sync skips the detail request.';

COMMENT ON COLUMN grantfit.opportunities.eligibility_basis IS
  'structured: Grants.gov applicant codes. narrative: parsed from the eligibility text. unrestricted: open to all. see_text: could not determine, fail closed.';

CREATE INDEX opportunities_status_close_idx
  ON grantfit.opportunities (status, close_date);

CREATE INDEX opportunities_topics_gin
  ON grantfit.opportunities USING gin (topics);

CREATE INDEX opportunities_applicants_gin
  ON grantfit.opportunities USING gin (eligible_applicants);

CREATE TABLE grantfit.provider_budgets (
  provider text PRIMARY KEY,
  daily_request_budget integer NOT NULL DEFAULT 200 CHECK (daily_request_budget >= 0),
  min_interval_ms integer NOT NULL DEFAULT 250 CHECK (min_interval_ms >= 0),
  requests_used integer NOT NULL DEFAULT 0 CHECK (requests_used >= 0),
  window_started_at timestamptz NOT NULL DEFAULT now(),
  last_request_at timestamptz,
  high_water_date date,
  last_success_at timestamptz,
  last_run_status text
);

COMMENT ON TABLE grantfit.provider_budgets IS
  'Shared daily request budget and minimum interval. Workers must call try_consume_request before every outbound HTTP call, including retries.';

CREATE TABLE grantfit.http_cache (
  cache_key text PRIMARY KEY,
  etag text,
  last_modified text,
  body_sha256 text,
  stored_at timestamptz NOT NULL DEFAULT now(),
  hit_count integer NOT NULL DEFAULT 0 CHECK (hit_count >= 0)
);

COMMENT ON TABLE grantfit.http_cache IS
  'Validators for conditional requests. A matching body hash is treated as not-modified even when the origin ignores ETag.';

CREATE TABLE grantfit.sync_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  status text NOT NULL DEFAULT 'running'
    CHECK (status IN ('running', 'success', 'partial', 'failed', 'budget_stopped')),
  requests_made integer NOT NULL DEFAULT 0,
  records_inserted integer NOT NULL DEFAULT 0,
  records_updated integer NOT NULL DEFAULT 0,
  records_unchanged integer NOT NULL DEFAULT 0,
  records_skipped integer NOT NULL DEFAULT 0,
  error text,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE grantfit.sync_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL,
  reason text NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'claimed', 'done', 'failed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  claimed_at timestamptz,
  finished_at timestamptz
);

CREATE UNIQUE INDEX sync_requests_one_open
  ON grantfit.sync_requests (provider)
  WHERE status IN ('pending', 'claimed');

COMMENT ON TABLE grantfit.sync_requests IS
  'Queue filled by pg_cron. A worker claims a row and runs the sync. Direct worker invocations do not need this table.';

CREATE TABLE grantfit.sync_queries (
  id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider text NOT NULL,
  keyword text NOT NULL CHECK (keyword <> ''),
  statuses text NOT NULL DEFAULT 'forecasted|posted',
  enabled boolean NOT NULL DEFAULT true
);

INSERT INTO grantfit.provider_budgets (provider, daily_request_budget, min_interval_ms)
VALUES ('grants_gov', 200, 250);

INSERT INTO grantfit.sync_queries (provider, keyword, statuses)
VALUES
  ('grants_gov', 'scholarship', 'forecasted|posted'),
  ('grants_gov', 'rural health', 'forecasted|posted'),
  ('grants_gov', 'tribal housing', 'forecasted|posted');
