"""Turn a Grants.gov detail payload into the row shape Postgres upserts.

The same rules are ported in supabase/functions/_shared/grantsGov.ts.
fixtures/grants_gov/expected_nsf_26503.json locks both implementations.
"""

from __future__ import annotations

import hashlib
import html
import re
from typing import Any

SUMMARY_LIMIT = 8000
KEYWORD_LIMIT = 12

STRUCTURED_APPLICANTS = {
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
}

CATEGORY_TOPICS = {
    "AG": "agriculture",
    "AR": "arts",
    "BC": "business",
    "CD": "community",
    "CP": "consumer",
    "ED": "education",
    "ELT": "workforce",
    "EN": "energy",
    "ENV": "environment",
    "FN": "nutrition",
    "HL": "health",
    "HO": "housing",
    "HU": "humanities",
    "II": "human_services",
    "IS": "data",
    "LJ": "justice",
    "NR": "environment",
    "RD": "community",
    "ST": "stem",
    "T": "transportation",
}

TITLE_TOPICS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("education", re.compile(r"scholarships?|fellowships?|education|teaching", re.I)),
    ("health", re.compile(r"health|clinic|biomedical", re.I)),
    ("housing", re.compile(r"housing|homeless", re.I)),
    ("energy", re.compile(r"\benergy\b|nuclear|solar", re.I)),
    ("environment", re.compile(r"environment|climate|conservation", re.I)),
    ("workforce", re.compile(r"workforce|job training", re.I)),
    ("stem", re.compile(r"cyber|artificial intelligence|\bresearch\b|\bscience\b", re.I)),
    ("arts", re.compile(r"\bmuseums?\b|\barts?\b|\bhumanities\b", re.I)),
)

NARRATIVE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("university", re.compile(r"institutions of higher education|\bihes?\b|\buniversit(?:y|ies)\b|\bcolleges?\b", re.I)),
    ("nonprofit", re.compile(r"non-profits?|nonprofits?|501\(c\)\(3\)", re.I)),
    ("small_business", re.compile(r"small businesses", re.I)),
    ("for_profit", re.compile(r"for-profits?|for profits?", re.I)),
    ("tribal_government", re.compile(r"tribal governments?", re.I)),
    ("state_government", re.compile(r"state governments?", re.I)),
    ("local_government", re.compile(r"local governments?|county governments?|city governments?", re.I)),
    ("school_district", re.compile(r"school districts?", re.I)),
    ("housing_authority", re.compile(r"housing authorit", re.I)),
    ("individual", re.compile(r"\bindividuals?\b", re.I)),
    ("unrestricted", re.compile(r"\bunrestricted\b", re.I)),
)

NEGATION = re.compile(r"not eligible|are ineligible|may not|ineligible", re.I)
TOKEN = re.compile(r"[a-z][a-z0-9-]{3,}")

STOPWORDS = frozenset({
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
})


def html_to_text(value: str | None) -> str:
    text = value or ""
    for _ in range(2):
        text = html.unescape(text)
    text = re.sub(r"(?i)<br\s*/?>", " ", text)
    text = re.sub(r"(?i)</(p|div|li|tr|h\d)>", " ", text)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    text = text.replace("\xa0", " ")
    return re.sub(r"\s+", " ", text).strip()


def parse_date(value: str | None) -> str | None:
    if not value:
        return None
    text = value.strip()
    iso = re.match(r"^(\d{4}-\d{2}-\d{2})", text)
    if iso:
        return iso.group(1)
    us = re.match(r"^(\d{2})/(\d{2})/(\d{4})", text)
    if us:
        return f"{us.group(3)}-{us.group(1)}-{us.group(2)}"
    return None


def parse_money(value: Any) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    digits = re.sub(r"[^0-9.]", "", str(value))
    if not digits:
        return None
    return int(float(digits))


def map_status(value: str | None) -> str:
    label = (value or "").strip().lower()
    if label in {"posted", "open"}:
        return "open"
    if label == "forecasted":
        return "forecasted"
    if label in {"closed", "archived"}:
        return "closed"
    return "unknown"


def list_fingerprint(
    number: str | None,
    title: str | None,
    open_date: str | None,
    close_date: str | None,
    status: str | None,
    agency_code: str | None,
) -> str:
    parts = [number or "", title or "", open_date or "", close_date or "", status or "", agency_code or ""]
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()


def _submit_section(text: str) -> str:
    lowered = text.lower()
    start = lowered.find("who may submit")
    if start < 0:
        start = 0
    end = lowered.find("who may serve")
    if end < 0 or end < start:
        return text[start:]
    return text[start:end]


def parse_narrative_applicants(eligibility_text: str | None) -> list[str]:
    section = _submit_section(html_to_text(eligibility_text))
    found: set[str] = set()
    chunks = re.split(r"(?<=[.!?])\s+|\n+", section)
    for chunk in chunks:
        piece = chunk.strip()
        if not piece or NEGATION.search(piece):
            continue
        for label, pattern in NARRATIVE_PATTERNS:
            if pattern.search(piece):
                found.add(label)
    return sorted(found)


def applicant_eligibility(types: list[dict] | None, eligibility_text: str | None) -> tuple[list[str], str]:
    structured: list[str] = []
    unrestricted = False
    for row in types or []:
        code = str(row.get("id") or row.get("value") or "")
        description = str(row.get("description") or row.get("label") or "")
        if code == "99" or description.lower().startswith("unrestricted"):
            unrestricted = True
            continue
        if code == "25" or "additional information on eligibility" in description.lower():
            continue
        mapped = STRUCTURED_APPLICANTS.get(code)
        if mapped and mapped not in structured:
            structured.append(mapped)
    if unrestricted and not structured:
        return ["unrestricted"], "unrestricted"
    if structured:
        return sorted(set(structured)), "structured"
    parsed = parse_narrative_applicants(eligibility_text)
    if parsed:
        return parsed, "narrative"
    return [], "see_text"


def topics_for(title: str, categories: list[dict] | None) -> list[str]:
    found: set[str] = set()
    for row in categories or []:
        code = str(row.get("id") or "")
        topic = CATEGORY_TOPICS.get(code)
        if topic:
            found.add(topic)
    for topic, pattern in TITLE_TOPICS:
        if pattern.search(title or ""):
            found.add(topic)
    return sorted(found)


def keywords_for(title: str, summary: str, limit: int = KEYWORD_LIMIT) -> list[str]:
    ordered: list[str] = []
    seen: set[str] = set()
    for token in TOKEN.findall(f"{title} {summary}".lower()):
        if token in STOPWORDS or token in seen:
            continue
        seen.add(token)
        ordered.append(token)
        if len(ordered) >= limit:
            break
    return ordered


def classify_kind(title: str, summary: str, instruments: list[dict] | None, eligible: list[str]) -> tuple[str, list[str]]:
    ids = {str(row.get("id") or "") for row in instruments or []}
    blob = f"{title} {summary}"
    tags: list[str] = []
    if re.search(r"\bscholarships?\b", blob, re.I):
        tags.append("scholarship_program")
    if re.search(r"\bfellowships?\b", blob, re.I):
        tags.append("fellowship_program")
    if "L" in ids:
        kind = "loan"
    elif re.search(r"\bfellowships?\b", title or "", re.I) and "individual" in eligible:
        kind = "fellowship"
    elif re.search(r"\bscholarships?\b", title or "", re.I) and "individual" in eligible:
        kind = "scholarship"
    elif "CA" in ids and "G" not in ids:
        kind = "cooperative_agreement"
    elif "G" in ids or not ids:
        kind = "grant"
    else:
        kind = "other"
    return kind, tags


def choose_agency(synopsis_name: str | None, listed_name: str | None) -> str:
    """Prefer the search-list agency when the detail names a person as Grantor."""
    detail = html_to_text(synopsis_name or "")
    listed = html_to_text(listed_name or "")
    if detail.lower().endswith(" grantor") and listed:
        return listed
    return detail or listed


def normalize_detail(payload: dict, hit: dict | None = None, *, source: str = "grants_gov") -> dict:
    data = payload.get("data") if isinstance(payload.get("data"), dict) else payload
    synopsis = data.get("synopsis") or {}
    hit = hit or {}
    title = html_to_text(data.get("opportunityTitle") or hit.get("title") or "")
    summary = html_to_text(synopsis.get("synopsisDesc"))[:SUMMARY_LIMIT]
    eligible, basis = applicant_eligibility(
        synopsis.get("applicantTypes"),
        synopsis.get("applicantEligibilityDesc"),
    )
    kind, tags = classify_kind(title, summary, synopsis.get("fundingInstruments"), eligible)
    open_date = parse_date(synopsis.get("postingDateStr")) or parse_date(hit.get("openDate"))
    close_date = parse_date(synopsis.get("responseDateStr")) or parse_date(hit.get("closeDate"))
    status = map_status(hit.get("oppStatus"))
    number = html_to_text(data.get("opportunityNumber") or hit.get("number") or "")
    agency_code = synopsis.get("agencyCode") or hit.get("agencyCode") or data.get("owningAgencyCode") or ""
    external_id = str(data.get("id") or hit.get("id") or "")
    return {
        "source": source,
        "external_id": external_id,
        "opportunity_number": number,
        "title": title,
        "summary": summary,
        "agency": choose_agency(synopsis.get("agencyName"), hit.get("agency")),
        "agency_code": agency_code,
        "kind": kind,
        "status": status,
        "open_date": open_date,
        "close_date": close_date,
        "award_floor": parse_money(synopsis.get("awardFloor")),
        "award_ceiling": parse_money(synopsis.get("awardCeiling")),
        "estimated_funding": parse_money(synopsis.get("estimatedFunding")),
        "eligible_applicants": eligible,
        "eligibility_basis": basis,
        "topics": topics_for(title, synopsis.get("fundingActivityCategories")),
        "keywords": keywords_for(title, summary),
        "geo_scope": "national",
        "states": [],
        "tags": tags,
        "url": f"https://www.grants.gov/search-results-detail/{external_id}" if external_id else None,
        "list_fingerprint": list_fingerprint(number, title, open_date, close_date, status, agency_code),
        "raw": {
            "id": data.get("id"),
            "revision": data.get("revision"),
            "opportunityNumber": data.get("opportunityNumber"),
            "applicantTypes": synopsis.get("applicantTypes") or [],
            "fundingInstruments": synopsis.get("fundingInstruments") or [],
            "fundingActivityCategories": synopsis.get("fundingActivityCategories") or [],
        },
    }
