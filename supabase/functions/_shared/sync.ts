// Bounded Grants.gov sync used by the Edge Function.
// The Python worker is the full scheduler; this path is the hosted trigger
// and follows the same budget, conditional-request, and upsert rules.

import { backoffMs, parseRetryAfter, RETRYABLE } from "./cost.ts";
import {
  DETAIL_URL,
  detailBody,
  htmlToText,
  listFingerprint,
  mapStatus,
  normalizeDetail,
  parseDate,
  SEARCH_URL,
  searchBody,
  sha256Hex,
} from "./grantsGov.ts";

export interface BudgetDecision {
  allowed: boolean;
  remaining: number;
  retry_after_ms: number;
  reason: string;
}

export interface Rpc {
  consume(): Promise<BudgetDecision>;
  fingerprints(ids: string[]): Promise<Record<string, string | null>>;
  upsert(rows: Record<string, unknown>[]): Promise<Array<{ external_id: string; action: string }>>;
  getCache(key: string): Promise<{ etag: string | null; last_modified: string | null; body_sha256: string | null } | null>;
  putCache(key: string, etag: string | null, lastModified: string | null, bodySha: string): Promise<void>;
  touchCache(key: string): Promise<void>;
  startRun(): Promise<string>;
  finishRun(id: string, status: string, stats: SyncStats): Promise<void>;
  noteHighWater(day: string): Promise<void>;
}

export interface SyncStats {
  status: string;
  requests_made: number;
  inserted: number;
  updated: number;
  unchanged: number;
  skipped: number;
  deferred: number;
  cache_hits: number;
  error: string | null;
}

export interface SyncDeps {
  rpc: Rpc;
  fetch: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  maxRequests?: number;
  rows?: number;
  keyword?: string;
  statuses?: string;
}

const empty = (): SyncStats => ({
  status: "running",
  requests_made: 0,
  inserted: 0,
  updated: 0,
  unchanged: 0,
  skipped: 0,
  deferred: 0,
  cache_hits: 0,
  error: null,
});

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map((item) => stableJson(item)).join(",")}]`;
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
    return `{${entries.map(([key, item]) => `${JSON.stringify(key)}:${stableJson(item)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

async function cacheKey(method: string, url: string, body: unknown): Promise<string> {
  return await sha256Hex(`${method}\n${url}\n${stableJson(body)}`);
}

class BudgetStop extends Error {
  constructor(readonly reason: string) {
    super(reason);
  }
}

async function acquire(deps: SyncDeps, stats: SyncStats): Promise<void> {
  if (stats.requests_made >= (deps.maxRequests ?? 8)) throw new BudgetStop("run_cap");
  for (let i = 0; i < 6; i++) {
    const decision = await deps.rpc.consume();
    if (decision.allowed) return;
    if (decision.reason === "budget_exhausted") throw new BudgetStop("budget_exhausted");
    if (decision.reason === "rate_limited") {
      await (deps.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))))(decision.retry_after_ms);
      continue;
    }
    throw new BudgetStop(decision.reason || "denied");
  }
  throw new Error("rate limit did not clear");
}

async function request(deps: SyncDeps, stats: SyncStats, url: string, body: unknown, key: string): Promise<{ status: number; body: Uint8Array; headers: Headers; notModified: boolean }> {
  const cached = await deps.rpc.getCache(key);
  const headers = new Headers({
    "Accept": "application/json",
    "Content-Type": "application/json",
    "User-Agent": "GrantFitDemo/1.0 (portfolio; edge)",
  });
  if (cached?.etag) headers.set("If-None-Match", cached.etag);
  if (cached?.last_modified) headers.set("If-Modified-Since", cached.last_modified);
  let last: Response | null = null;
  for (let attempt = 0; attempt < 4; attempt++) {
    await acquire(deps, stats);
    stats.requests_made += 1;
    const response = await deps.fetch(url, { method: "POST", headers, body: JSON.stringify(body) });
    if (response.status === 304 || (response.status >= 200 && response.status < 300)) {
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (response.status === 304) {
        await deps.rpc.touchCache(key);
        return { status: 304, body: new Uint8Array(), headers: response.headers, notModified: true };
      }
      const digest = await sha256Hex(new TextDecoder().decode(bytes));
      if (cached?.body_sha256 && cached.body_sha256 === digest) {
        await deps.rpc.putCache(key, response.headers.get("etag"), response.headers.get("last-modified"), digest);
        return { status: response.status, body: bytes, headers: response.headers, notModified: true };
      }
      await deps.rpc.putCache(key, response.headers.get("etag"), response.headers.get("last-modified"), digest);
      return { status: response.status, body: bytes, headers: response.headers, notModified: false };
    }
    last = response;
    if (RETRYABLE.has(response.status) && attempt < 3) {
      const wait = backoffMs(attempt, { retryAfterMs: parseRetryAfter(response.headers.get("retry-after")), jitterMs: 0 });
      await (deps.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))))(wait);
      continue;
    }
    throw new Error(`HTTP ${response.status}`);
  }
  throw new Error(`HTTP ${last?.status ?? 0}`);
}

export async function runGrantsGovSync(deps: SyncDeps): Promise<SyncStats> {
  const stats = empty();
  const keyword = deps.keyword ?? "scholarship";
  const statuses = deps.statuses ?? "forecasted|posted";
  const rows = deps.rows ?? 25;
  let runId: string | null = null;
  try {
    runId = await deps.rpc.startRun();
    const body = searchBody(0, rows, keyword, statuses);
    const key = await cacheKey("POST", SEARCH_URL, body);
    let page;
    try {
      page = await request(deps, stats, SEARCH_URL, body, key);
    } catch (error) {
      if (error instanceof BudgetStop) {
        stats.status = "budget_stopped";
        return stats;
      }
      throw error;
    }
    if (page.notModified) {
      stats.cache_hits += 1;
      stats.status = "success";
      return stats;
    }
    const payload = JSON.parse(new TextDecoder().decode(page.body));
    if (payload.errorcode) throw new Error(payload.msg || "Grants.gov error");
    const hits = payload.data?.oppHits ?? [];
    const ids = hits.map((hit: Record<string, unknown>) => String(hit.id));
    const known = await deps.rpc.fingerprints(ids);
    for (const hit of hits) {
      const title = htmlToText(String(hit.title ?? ""));
      const number = htmlToText(String(hit.number ?? ""));
      const openDate = parseDate(hit.openDate as string | undefined);
      const closeDate = parseDate(hit.closeDate as string | undefined);
      const status = mapStatus(hit.oppStatus as string | undefined);
      const agencyCode = String(hit.agencyCode ?? "");
      const fingerprint = await listFingerprint(number, title, openDate, closeDate, status, agencyCode);
      const externalId = String(hit.id);
      if (known[externalId] && known[externalId] === fingerprint) {
        stats.skipped += 1;
        continue;
      }
      const detailPayload = detailBody(externalId);
      const detailKey = await cacheKey("POST", DETAIL_URL, detailPayload);
      let detail;
      try {
        detail = await request(deps, stats, DETAIL_URL, detailPayload, detailKey);
      } catch (error) {
        if (error instanceof BudgetStop) {
          stats.deferred += 1;
          stats.status = "budget_stopped";
          return stats;
        }
        throw error;
      }
      if (detail.notModified) {
        stats.cache_hits += 1;
        stats.skipped += 1;
        continue;
      }
      const normalized = await normalizeDetail(JSON.parse(new TextDecoder().decode(detail.body)), hit);
      const actions = await deps.rpc.upsert([normalized]);
      for (const action of actions) {
        if (action.action === "inserted") stats.inserted += 1;
        else if (action.action === "updated") stats.updated += 1;
        else stats.unchanged += 1;
      }
      if (normalized.open_date) await deps.rpc.noteHighWater(String(normalized.open_date));
    }
    stats.status = "success";
  } catch (error) {
    stats.status = "failed";
    stats.error = error instanceof Error ? error.message : String(error);
  } finally {
    if (runId) await deps.rpc.finishRun(runId, stats.status === "running" ? "failed" : stats.status, stats);
  }
  return stats;
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function handleSyncRequest(req: Request, deps: SyncDeps & { env: Record<string, string | undefined> }): Promise<Response> {
  if (req.method !== "POST") return json({ error: "POST required" }, 405);
  const secret = deps.env.GRANTFIT_SYNC_SECRET;
  if (!secret) return json({ error: "GRANTFIT_SYNC_SECRET is not set" }, 500);
  const header = req.headers.get("x-grantfit-sync-secret") ?? "";
  if (!safeEqual(header, secret)) return json({ error: "unauthorized" }, 401);
  let extra: Record<string, unknown> = {};
  if (req.headers.get("content-type")?.includes("application/json")) {
    extra = await req.json().catch(() => ({}));
  }
  const maxRequests = Math.min(Number(extra.maxRequests ?? deps.maxRequests ?? 8), 40);
  const stats = await runGrantsGovSync({
    ...deps,
    keyword: typeof extra.keyword === "string" ? extra.keyword : deps.keyword,
    maxRequests,
  });
  return json(stats, stats.status === "failed" ? 502 : 200);
}
