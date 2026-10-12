// Grants.gov normalizer. Keep in lockstep with worker/src/grantfit/normalize.py.
// The fixture fixtures/grants_gov/expected_nsf_26503.json is the contract.

const SUMMARY_LIMIT = 8000;
const KEYWORD_LIMIT = 12;

const STRUCTURED: Record<string, string> = {
  "00": "state_government",
  "01": "local_government",
  "02": "local_government",
  "04": "special_district",
  "05": "school_district",
  "06": "university",
  "07": "tribal_government",
  "08": "housing_authority",
  "11": "tribal_organization",
  "12": "nonprofit",
  "13": "nonprofit",
  "20": "university",
  "21": "individual",
  "22": "for_profit",
  "23": "small_business",
};

const CATEGORY_TOPICS: Record<string, string> = {
  AG: "agriculture",
  AR: "arts",
  BC: "business",
  CD: "community",
  CP: "consumer",
  ED: "education",
  ELT: "workforce",
  EN: "energy",
  ENV: "environment",
  FN: "nutrition",
  HL: "health",
  HO: "housing",
  HU: "humanities",
  II: "human_services",
  IS: "data",
  LJ: "justice",
  NR: "environment",
  RD: "community",
  ST: "stem",
  T: "transportation",
};

const TITLE_TOPICS: Array<[string, RegExp]> = [
  ["education", /scholarships?|fellowships?|education|teaching/i],
  ["health", /health|clinic|biomedical/i],
  ["housing", /housing|homeless/i],
  ["energy", /\benergy\b|nuclear|solar/i],
  ["environment", /environment|climate|conservation/i],
  ["workforce", /workforce|job training/i],
  ["stem", /cyber|artificial intelligence|\bresearch\b|\bscience\b/i],
  ["arts", /\bmuseums?\b|\barts?\b|\bhumanities\b/i],
];

const NARRATIVE: Array<[string, RegExp]> = [
  ["university", /institutions of higher education|\bihes?\b|\buniversit(?:y|ies)\b|\bcolleges?\b/i],
  ["nonprofit", /non-profits?|nonprofits?|501\(c\)\(3\)/i],
  ["small_business", /small businesses/i],
  ["for_profit", /for-profits?|for profits?/i],
  ["tribal_government", /tribal governments?/i],
  ["state_government", /state governments?/i],
  ["local_government", /local governments?|county governments?|city governments?/i],
  ["school_district", /school districts?/i],
  ["housing_authority", /housing authorit/i],
  ["individual", /\bindividuals?\b/i],
  ["unrestricted", /\bunrestricted\b/i],
];

const NEGATION = /not eligible|are ineligible|may not|ineligible/i;
const TOKEN_SOURCE = "[a-z][a-z0-9-]{3,}";

const STOPWORDS = new Set([
  "about", "after", "also", "their", "there", "these", "this", "that", "with", "from",
  "your", "have", "will", "into", "such", "than", "then", "them", "they", "been",
  "were", "which", "while", "where", "what", "when", "only", "other", "under", "over",
  "through", "program", "programs", "support", "supports", "including", "include",
  "funded", "funding", "grant", "grants", "award", "awards", "application",
  "applications", "applicant", "applicants", "project", "projects", "service",
  "services", "national", "federal", "using", "must", "shall", "each", "more", "most",
  "some", "both", "between", "within", "without", "across", "among", "provide",
  "provides", "provided", "based", "related", "information", "above", "below",
  "following", "please", "contact", "agency", "agencies",
]);

const NAMED: Record<string, string> = {
  amp: "&",
  nbsp: "\u00a0",
  rsquo: "\u2019",
  lsquo: "\u2018",
  ndash: "\u2013",
  mdash: "\u2014",
  quot: '"',
  apos: "'",
  sect: "\u00a7",
  lt: "<",
  gt: ">",
};

export function decodeOnce(value: string): string {
  return value.replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (entity) => {
    if (entity[1] === "#") {
      const hex = entity[2]?.toLowerCase() === "x";
      const raw = hex ? entity.slice(3, -1) : entity.slice(2, -1);
      const num = Number.parseInt(raw, hex ? 16 : 10);
      return Number.isFinite(num) ? String.fromCodePoint(num) : entity;
    }
    return NAMED[entity.slice(1, -1).toLowerCase()] ?? entity;
  });
}

export function htmlToText(value: string | null | undefined): string {
  let text = value ?? "";
  text = decodeOnce(decodeOnce(text));
  text = text.replace(/<br\s*\/?>/gi, " ");
  text = text.replace(/<\/(p|div|li|tr|h\d)>/gi, " ");
  text = text.replace(/<[^>]+>/g, " ");
  text = decodeOnce(text);
  text = text.replace(/\u00a0/g, " ");
  return text.replace(/\s+/g, " ").trim();
}

export function parseDate(value: string | null | undefined): string | null {
  if (!value) return null;
  const text = value.trim();
  const iso = text.match(/^(\d{4}-\d{2}-\d{2})/);
  if (iso) return iso[1];
  const us = text.match(/^(\d{2})\/(\d{2})\/(\d{4})/);
  if (us) return `${us[3]}-${us[1]}-${us[2]}`;
  return null;
}

export function parseMoney(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value === "boolean") return null;
  if (typeof value === "number") return Math.trunc(value);
  const digits = String(value).replace(/[^0-9.]/g, "");
  if (!digits) return null;
  return Math.trunc(Number(digits));
}

export function mapStatus(value: string | null | undefined): string {
  const label = (value ?? "").trim().toLowerCase();
  if (label === "posted" || label === "open") return "open";
  if (label === "forecasted") return "forecasted";
  if (label === "closed" || label === "archived") return "closed";
  return "unknown";
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function listFingerprint(
  number: string | null,
  title: string | null,
  openDate: string | null,
  closeDate: string | null,
  status: string | null,
  agencyCode: string | null,
): Promise<string> {
  const parts = [number ?? "", title ?? "", openDate ?? "", closeDate ?? "", status ?? "", agencyCode ?? ""];
  return await sha256Hex(parts.join("\n"));
}

function submitSection(text: string): string {
  const lowered = text.toLowerCase();
  const start = lowered.indexOf("who may submit");
  const from = start < 0 ? 0 : start;
  const end = lowered.indexOf("who may serve");
  if (end < 0 || end < from) return text.slice(from);
  return text.slice(from, end);
}

export function parseNarrativeApplicants(eligibilityText: string | null | undefined): string[] {
  const section = submitSection(htmlToText(eligibilityText));
  const found = new Set<string>();
  for (const chunk of section.split(/(?<=[.!?])\s+|\n+/)) {
    const piece = chunk.trim();
    if (!piece || NEGATION.test(piece)) continue;
    for (const [label, pattern] of NARRATIVE) {
      pattern.lastIndex = 0;
      if (pattern.test(piece)) found.add(label);
    }
  }
  return [...found].sort();
}

export function applicantEligibility(
  types: Array<Record<string, string>> | null | undefined,
  eligibilityText: string | null | undefined,
): { eligible: string[]; basis: string } {
  const structured: string[] = [];
  let unrestricted = false;
  for (const row of types ?? []) {
    const code = String(row.id ?? row.value ?? "");
    const description = String(row.description ?? row.label ?? "");
    if (code === "99" || description.toLowerCase().startsWith("unrestricted")) {
      unrestricted = true;
      continue;
    }
    if (code === "25" || description.toLowerCase().includes("additional information on eligibility")) {
      continue;
    }
    const mapped = STRUCTURED[code];
    if (mapped && !structured.includes(mapped)) structured.push(mapped);
  }
  if (unrestricted && structured.length === 0) return { eligible: ["unrestricted"], basis: "unrestricted" };
  if (structured.length) return { eligible: [...new Set(structured)].sort(), basis: "structured" };
  const parsed = parseNarrativeApplicants(eligibilityText);
  if (parsed.length) return { eligible: parsed, basis: "narrative" };
  return { eligible: [], basis: "see_text" };
}

export function topicsFor(title: string, categories: Array<Record<string, string>> | null | undefined): string[] {
  const found = new Set<string>();
  for (const row of categories ?? []) {
    const topic = CATEGORY_TOPICS[String(row.id ?? "")];
    if (topic) found.add(topic);
  }
  for (const [topic, pattern] of TITLE_TOPICS) {
    pattern.lastIndex = 0;
    if (pattern.test(title ?? "")) found.add(topic);
  }
  return [...found].sort();
}

export function keywordsFor(title: string, summary: string, limit = KEYWORD_LIMIT): string[] {
  const ordered: string[] = [];
  const seen = new Set<string>();
  const source = `${title} ${summary}`.toLowerCase();
  for (const token of source.match(new RegExp(TOKEN_SOURCE, "g")) ?? []) {
    if (STOPWORDS.has(token) || seen.has(token)) continue;
    seen.add(token);
    ordered.push(token);
    if (ordered.length >= limit) break;
  }
  return ordered;
}

export function classifyKind(
  title: string,
  summary: string,
  instruments: Array<Record<string, string>> | null | undefined,
  eligible: string[],
): { kind: string; tags: string[] } {
  const ids = new Set((instruments ?? []).map((row) => String(row.id ?? "")));
  const blob = `${title} ${summary}`;
  const tags: string[] = [];
  if (/\bscholarships?\b/i.test(blob)) tags.push("scholarship_program");
  if (/\bfellowships?\b/i.test(blob)) tags.push("fellowship_program");
  let kind = "other";
  if (ids.has("L")) kind = "loan";
  else if (/\bfellowships?\b/i.test(title ?? "") && eligible.includes("individual")) kind = "fellowship";
  else if (/\bscholarships?\b/i.test(title ?? "") && eligible.includes("individual")) kind = "scholarship";
  else if (ids.has("CA") && !ids.has("G")) kind = "cooperative_agreement";
  else if (ids.has("G") || ids.size === 0) kind = "grant";
  return { kind, tags };
}

export function chooseAgency(synopsisName: string | undefined, listedName: string | undefined): string {
  const detail = htmlToText(synopsisName ?? "");
  const listed = htmlToText(listedName ?? "");
  if (detail.toLowerCase().endsWith(" grantor") && listed) return listed;
  return detail || listed;
}

export async function normalizeDetail(
  payload: Record<string, unknown>,
  hit: Record<string, unknown> | null = null,
  source = "grants_gov",
): Promise<Record<string, unknown>> {
  const data = (payload.data && typeof payload.data === "object" ? payload.data : payload) as Record<string, unknown>;
  const synopsis = (data.synopsis ?? {}) as Record<string, unknown>;
  const rowHit = hit ?? {};
  const title = htmlToText(String(data.opportunityTitle ?? rowHit.title ?? ""));
  const summary = htmlToText(synopsis.synopsisDesc as string | undefined).slice(0, SUMMARY_LIMIT);
  const { eligible, basis } = applicantEligibility(
    synopsis.applicantTypes as Array<Record<string, string>> | undefined,
    synopsis.applicantEligibilityDesc as string | undefined,
  );
  const { kind, tags } = classifyKind(
    title,
    summary,
    synopsis.fundingInstruments as Array<Record<string, string>> | undefined,
    eligible,
  );
  const openDate = parseDate(synopsis.postingDateStr as string | undefined) ?? parseDate(rowHit.openDate as string | undefined);
  const closeDate = parseDate(synopsis.responseDateStr as string | undefined) ?? parseDate(rowHit.closeDate as string | undefined);
  const status = mapStatus(rowHit.oppStatus as string | undefined);
  const number = htmlToText(String(data.opportunityNumber ?? rowHit.number ?? ""));
  const agencyCode = String(synopsis.agencyCode ?? rowHit.agencyCode ?? data.owningAgencyCode ?? "");
  const externalId = String(data.id ?? rowHit.id ?? "");
  return {
    source,
    external_id: externalId,
    opportunity_number: number,
    title,
    summary,
    agency: chooseAgency(synopsis.agencyName as string | undefined, rowHit.agency as string | undefined),
    agency_code: agencyCode,
    kind,
    status,
    open_date: openDate,
    close_date: closeDate,
    award_floor: parseMoney(synopsis.awardFloor),
    award_ceiling: parseMoney(synopsis.awardCeiling),
    estimated_funding: parseMoney(synopsis.estimatedFunding),
    eligible_applicants: eligible,
    eligibility_basis: basis,
    topics: topicsFor(title, synopsis.fundingActivityCategories as Array<Record<string, string>> | undefined),
    keywords: keywordsFor(title, summary),
    geo_scope: "national",
    states: [],
    tags,
    url: externalId ? `https://www.grants.gov/search-results-detail/${externalId}` : null,
    list_fingerprint: await listFingerprint(number, title, openDate, closeDate, status, agencyCode),
    raw: {
      id: data.id,
      revision: data.revision,
      opportunityNumber: data.opportunityNumber,
      applicantTypes: synopsis.applicantTypes ?? [],
      fundingInstruments: synopsis.fundingInstruments ?? [],
      fundingActivityCategories: synopsis.fundingActivityCategories ?? [],
    },
  };
}

export const SEARCH_URL = "https://api.grants.gov/v1/api/search2";
export const DETAIL_URL = "https://api.grants.gov/v1/api/fetchOpportunity";

export function searchBody(start: number, rows: number, keyword: string, statuses: string) {
  return { rows, keyword, oppStatuses: statuses, startRecordNum: start };
}

export function detailBody(opportunityId: string) {
  return { opportunityId: Number(opportunityId) };
}
