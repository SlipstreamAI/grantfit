import { assertEquals } from "jsr:@std/assert";
import { handleSyncRequest, type Rpc, type SyncStats, runGrantsGovSync } from "./sync.ts";

const root = new URL("../../../fixtures/grants_gov/", import.meta.url);

function fakeRpc(overrides: Partial<Rpc> = {}): Rpc & { upserts: Record<string, unknown>[][] } {
  const upserts: Record<string, unknown>[][] = [];
  const rpc: Rpc & { upserts: Record<string, unknown>[][] } = {
    upserts,
    consume: () => Promise.resolve({ allowed: true, remaining: 10, retry_after_ms: 0, reason: "ok" }),
    fingerprints: () => Promise.resolve({}),
    upsert: (rows) => {
      upserts.push(rows);
      return Promise.resolve(rows.map((row) => ({ external_id: String(row.external_id), action: "inserted" })));
    },
    getCache: () => Promise.resolve(null),
    putCache: () => Promise.resolve(),
    touchCache: () => Promise.resolve(),
    startRun: () => Promise.resolve("run-1"),
    finishRun: () => Promise.resolve(),
    noteHighWater: () => Promise.resolve(),
    ...overrides,
  };
  return rpc;
}

Deno.test("edge sync upserts a detail and stops when the budget is gone", async () => {
  const search = await Deno.readTextFile(new URL("search_scholarship.json", root));
  const searchJson = JSON.parse(search);
  searchJson.data.oppHits = searchJson.data.oppHits.slice(0, 1);
  const detail = await Deno.readTextFile(new URL("opportunity_361238.json", root));
  const bodies = [JSON.stringify(searchJson), detail];
  let calls = 0;
  const rpc = fakeRpc();
  const stats = await runGrantsGovSync({
    rpc,
    maxRequests: 8,
    rows: 25,
    sleep: () => Promise.resolve(),
    fetch: () => {
      const body = bodies[calls++] ?? "{}";
      return Promise.resolve(new Response(body, { status: 200 }));
    },
  });
  assertEquals(stats.status, "success");
  assertEquals(stats.inserted, 1);
  assertEquals(stats.requests_made, 2);
  assertEquals(rpc.upserts[0][0].kind, "grant");
  assertEquals(rpc.upserts[0][0].eligible_applicants, ["nonprofit", "university"]);
});

Deno.test("a one-request cap defers the detail", async () => {
  const search = JSON.parse(await Deno.readTextFile(new URL("search_scholarship.json", root)));
  search.data.oppHits = search.data.oppHits.slice(0, 1);
  const rpc = fakeRpc();
  const stats = await runGrantsGovSync({
    rpc,
    maxRequests: 1,
    sleep: () => Promise.resolve(),
    fetch: () => Promise.resolve(new Response(JSON.stringify(search), { status: 200 })),
  });
  assertEquals(stats.status, "budget_stopped");
  assertEquals(stats.deferred, 1);
  assertEquals(rpc.upserts.length, 0);
});

Deno.test("handler rejects a missing or wrong sync secret", async () => {
  const rpc = fakeRpc();
  const missing = await handleSyncRequest(new Request("http://localhost/", { method: "POST" }), {
    rpc,
    fetch,
    env: {},
  });
  assertEquals(missing.status, 500);
  const denied = await handleSyncRequest(new Request("http://localhost/", {
    method: "POST",
    headers: { "x-grantfit-sync-secret": "nope" },
  }), {
    rpc,
    fetch,
    env: { GRANTFIT_SYNC_SECRET: "correct" },
  });
  assertEquals(denied.status, 401);
  const stats: SyncStats = { status: "success", requests_made: 0, inserted: 0, updated: 0, unchanged: 0, skipped: 0, deferred: 0, cache_hits: 0, error: null };
  void stats;
});
