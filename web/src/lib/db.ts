import { Pool, types } from "pg";

types.setTypeParser(1082, (value) => value);

const DEFAULT_URL =
  "postgresql://grantfit_demo:grantfit_local_dev@127.0.0.1:5432/grantfit";

const globalForPg = globalThis as unknown as { grantfitPool?: Pool };

export function getPool(): Pool {
  if (!globalForPg.grantfitPool) {
    globalForPg.grantfitPool = new Pool({
      connectionString: process.env.DATABASE_URL || DEFAULT_URL,
      max: 4,
      connectionTimeoutMillis: 3000,
    });
  }
  return globalForPg.grantfitPool;
}

export type Profile = {
  slug: string;
  display_name: string;
  organization_name: string;
  summary: string;
  organization_kinds: string[];
  state_code: string | null;
  topics: string[];
  keywords: string[];
  min_award: string | null;
  max_award: string | null;
  interests: string[];
};

export type MatchRow = {
  bucket: "eligible" | "near_miss";
  rank: number;
  source: string;
  external_id: string;
  title: string;
  agency: string | null;
  kind: string;
  status: string;
  score: string;
  topic_points: string;
  keyword_points: string;
  award_points: string;
  recency_points: string;
  status_points: string;
  reasons: string[] | null;
  blocking_reasons: string[] | null;
  open_date: string | null;
  close_date: string | null;
  award_floor: string | null;
  award_ceiling: string | null;
  topics: string[] | null;
  eligible_applicants: string[] | null;
  states: string[] | null;
  geo_scope: string | null;
  eligibility_basis: string | null;
  url: string | null;
  summary: string | null;
};

export type HealthRow = {
  provider: string;
  daily_request_budget: number;
  requests_used: number;
  remaining: number;
  high_water_date: string | null;
  last_success_at: Date | null;
  last_run_status: string | null;
};

export type Board = {
  profiles: Profile[];
  selected: Profile | null;
  unknownSlug: string | null;
  matches: MatchRow[];
  health: HealthRow[];
  source: "seed" | "grants_gov" | "all";
  asOf: string;
};

function one(value: string | string[] | undefined): string | undefined {
  if (Array.isArray(value)) return value[0];
  return value;
}

export function parseSource(value: string | string[] | undefined): Board["source"] {
  const raw = one(value);
  if (raw === "grants_gov" || raw === "all") return raw;
  return "seed";
}

export async function loadBoard(
  profileParam: string | string[] | undefined,
  sourceParam: string | string[] | undefined,
): Promise<Board> {
  const source = parseSource(sourceParam);
  const requested = one(profileParam)?.trim() || null;
  const pool = getPool();
  const profiles = await pool.query<Profile>(`
    SELECT
      slug,
      display_name,
      organization_name,
      summary,
      organization_kinds::text[] AS organization_kinds,
      state_code,
      topics,
      keywords,
      min_award::text,
      max_award::text,
      interests
    FROM public.demo_profiles
    ORDER BY display_name
  `);
  const health = await pool.query<HealthRow>(`
    SELECT
      provider,
      daily_request_budget,
      requests_used,
      remaining,
      high_water_date::text,
      last_success_at,
      last_run_status
    FROM public.sync_health()
  `);
  const clock = await pool.query<{ today: string }>(`SELECT CURRENT_DATE::text AS today`);
  const known = profiles.rows.find((row) => row.slug === requested);
  const selected =
    known ??
    profiles.rows.find((row) => row.slug === "harborlight") ??
    profiles.rows[0] ??
    null;
  const unknownSlug = requested && !known ? requested : null;
  let matches: MatchRow[] = [];
  if (selected && !unknownSlug) {
    const result = await pool.query<MatchRow>(
      `
        SELECT
          bucket,
          rank,
          source,
          external_id,
          title,
          agency,
          kind,
          status,
          score::text,
          topic_points::text,
          keyword_points::text,
          award_points::text,
          recency_points::text,
          status_points::text,
          reasons,
          blocking_reasons,
          open_date::text,
          close_date::text,
          award_floor::text,
          award_ceiling::text,
          topics,
          eligible_applicants,
          states,
          geo_scope,
          eligibility_basis,
          url,
          summary
        FROM public.match_profile($1, 8, 4, CURRENT_DATE, $2)
      `,
      [selected.slug, source === "all" ? null : source],
    );
    matches = result.rows;
  }
  return {
    profiles: profiles.rows,
    selected: unknownSlug ? null : selected,
    unknownSlug,
    matches,
    health: health.rows,
    source,
    asOf: clock.rows[0]?.today ?? "",
  };
}

export function databaseErrorMessage(error: unknown): string {
  const err = error as { code?: string; message?: string };
  if (err.code === "ECONNREFUSED" || err.code === "ENOTFOUND") {
    return "Postgres is not accepting connections on 127.0.0.1:5432.";
  }
  if (err.code === "28P01" || err.code === "28000") {
    return "The demo role could not log in. Run scripts/bootstrap_local.sh.";
  }
  if (err.code === "3D000") {
    return "The grantfit database does not exist yet. Run scripts/bootstrap_local.sh.";
  }
  if (err.code === "42P01" || err.code === "42883") {
    return "The match functions are missing. Apply the migrations with scripts/bootstrap_local.sh.";
  }
  return err.message || "The database query failed.";
}
