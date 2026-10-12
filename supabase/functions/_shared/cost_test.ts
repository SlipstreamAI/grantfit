import { assertEquals } from "jsr:@std/assert";
import { backoffMs, parseRetryAfter } from "./cost.ts";

Deno.test("backoff grows, caps, and prefers Retry-After", () => {
  assertEquals(backoffMs(0, { baseMs: 200, jitterMs: 0 }), 200);
  assertEquals(backoffMs(3, { baseMs: 200, jitterMs: 0 }), 1600);
  assertEquals(backoffMs(10, { baseMs: 200, capMs: 8000, jitterMs: 0 }), 8000);
  assertEquals(backoffMs(1, { retryAfterMs: 1500, jitterMs: 40 }), 1500);
  assertEquals(backoffMs(0, { retryAfterMs: 99999, capMs: 8000 }), 8000);
});

Deno.test("Retry-After seconds and HTTP dates", () => {
  assertEquals(parseRetryAfter("2"), 2000);
  assertEquals(parseRetryAfter(null), null);
  const now = Date.parse("2026-10-12T00:00:00Z");
  assertEquals(parseRetryAfter("Mon, 12 Oct 2026 00:00:03 GMT", now), 3000);
});
