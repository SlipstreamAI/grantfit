// Hosted entry point. pg_net (from pg_cron) or GitHub Actions POST here.
// verify_jwt is disabled in config.toml; GRANTFIT_SYNC_SECRET is required.

import { createClient } from "npm:@supabase/supabase-js@2";
import { handleSyncRequest, type BudgetDecision, type Rpc, type SyncStats } from "../_shared/sync.ts";

function firstRow<T>(data: T | T[] | null): T | null {
  if (!data) return null;
  return Array.isArray(data) ? data[0] ?? null : data;
}

function rpcClient(): Rpc {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required");
  const supabase = createClient(url, key, { auth: { persistSession: false } });
  return {
    async consume(): Promise<BudgetDecision> {
      const { data, error } = await supabase.rpc("try_consume_request", { p_provider: "grants_gov", p_cost: 1 });
      if (error) throw new Error(error.message);
      const row = firstRow(data as BudgetDecision[]);
      if (!row) throw new Error("try_consume_request returned no row");
      return row;
    },
    async fingerprints(ids) {
      const { data, error } = await supabase.rpc("list_fingerprints", { p_source: "grants_gov", p_ids: ids });
      if (error) throw new Error(error.message);
      const out: Record<string, string | null> = {};
      for (const row of (data ?? []) as Array<{ external_id: string; list_fingerprint: string | null }>) {
        out[row.external_id] = row.list_fingerprint;
      }
      return out;
    },
    async upsert(rows) {
      const { data, error } = await supabase.rpc("upsert_opportunities", { p_items: rows });
      if (error) throw new Error(error.message);
      return (data ?? []) as Array<{ external_id: string; action: string }>;
    },
    async getCache(key) {
      const { data, error } = await supabase.rpc("get_http_cache", { p_key: key });
      if (error) throw new Error(error.message);
      return firstRow(data as Array<{ etag: string | null; last_modified: string | null; body_sha256: string | null }>);
    },
    async putCache(key, etag, lastModified, bodySha) {
      const { error } = await supabase.rpc("put_http_cache", {
        p_key: key,
        p_etag: etag,
        p_last_modified: lastModified,
        p_body_sha256: bodySha,
      });
      if (error) throw new Error(error.message);
    },
    async touchCache(key) {
      const { error } = await supabase.rpc("touch_http_cache", { p_key: key });
      if (error) throw new Error(error.message);
    },
    async startRun() {
      const { data, error } = await supabase.rpc("start_sync_run", { p_provider: "grants_gov" });
      if (error) throw new Error(error.message);
      return String(data);
    },
    async finishRun(id, status, stats: SyncStats) {
      const { error } = await supabase.rpc("finish_sync_run", {
        p_id: id,
        p_status: status,
        p_requests: stats.requests_made,
        p_inserted: stats.inserted,
        p_updated: stats.updated,
        p_unchanged: stats.unchanged,
        p_skipped: stats.skipped,
        p_error: stats.error,
        p_detail: { deferred: stats.deferred, cache_hits: stats.cache_hits },
      });
      if (error) throw new Error(error.message);
    },
    async noteHighWater(day) {
      const { error } = await supabase.rpc("note_high_water", { p_provider: "grants_gov", p_date: day });
      if (error) throw new Error(error.message);
    },
  };
}

Deno.serve((req) => {
  let rpc: Rpc;
  try {
    rpc = rpcClient();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return new Response(JSON.stringify({ error: message }), { status: 500 });
  }
  return handleSyncRequest(req, {
    rpc,
    fetch,
    env: {
      GRANTFIT_SYNC_SECRET: Deno.env.get("GRANTFIT_SYNC_SECRET"),
    },
  });
});
