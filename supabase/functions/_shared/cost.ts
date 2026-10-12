export const RETRYABLE = new Set([429, 500, 502, 503, 504]);

export function backoffMs(
  attempt: number,
  options: { baseMs?: number; capMs?: number; retryAfterMs?: number | null; jitterMs?: number } = {},
): number {
  const baseMs = options.baseMs ?? 200;
  const capMs = options.capMs ?? 8000;
  const jitterMs = options.jitterMs ?? 0;
  if (options.retryAfterMs !== undefined && options.retryAfterMs !== null) {
    return Math.min(Math.max(options.retryAfterMs, 0), capMs);
  }
  const exp = Math.min(capMs, baseMs * 2 ** attempt);
  return Math.min(capMs, exp + Math.max(jitterMs, 0));
}

export function parseRetryAfter(value: string | null, now = Date.now()): number | null {
  if (!value) return null;
  const text = value.trim();
  if (!text) return null;
  if (/^\d+$/.test(text)) return Number(text) * 1000;
  const when = Date.parse(text);
  if (Number.isNaN(when)) return null;
  return Math.max(when - now, 0);
}
