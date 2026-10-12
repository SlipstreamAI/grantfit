"""Grants.gov search2 + fetchOpportunity. No API key."""

from __future__ import annotations

import json

from grantfit.http import cache_key
from grantfit.models import ProviderError, RequestSpec
from grantfit.normalize import html_to_text, list_fingerprint, map_status, normalize_detail, parse_date

SEARCH_URL = "https://api.grants.gov/v1/api/search2"
DETAIL_URL = "https://api.grants.gov/v1/api/fetchOpportunity"


class GrantsGovProvider:
    name = "grants_gov"

    def search_request(self, *, start: int, rows: int, keyword: str, statuses: str) -> RequestSpec:
        body = {
            "rows": rows,
            "keyword": keyword,
            "oppStatuses": statuses,
            "startRecordNum": start,
        }
        return RequestSpec("POST", SEARCH_URL, body, cache_key("POST", SEARCH_URL, body))

    def detail_request(self, opportunity_id: str) -> RequestSpec:
        body = {"opportunityId": int(opportunity_id)}
        return RequestSpec("POST", DETAIL_URL, body, cache_key("POST", DETAIL_URL, body))

    def parse_search(self, body: bytes) -> list[dict]:
        payload = _load(body)
        data = payload.get("data") or {}
        hits = []
        for row in data.get("oppHits") or []:
            status = map_status(row.get("oppStatus"))
            title = html_to_text(row.get("title"))
            number = html_to_text(row.get("number"))
            open_date = parse_date(row.get("openDate"))
            close_date = parse_date(row.get("closeDate"))
            agency_code = row.get("agencyCode") or ""
            hits.append({
                "id": str(row.get("id")),
                "external_id": str(row.get("id")),
                "number": number,
                "title": title,
                "agency": html_to_text(row.get("agency")),
                "agencyCode": agency_code,
                "openDate": row.get("openDate"),
                "closeDate": row.get("closeDate"),
                "open_date": open_date,
                "close_date": close_date,
                "oppStatus": row.get("oppStatus"),
                "status": status,
                "list_fingerprint": list_fingerprint(number, title, open_date, close_date, status, agency_code),
            })
        return hits

    def parse_detail(self, body: bytes, hit: dict) -> dict:
        payload = _load(body)
        return normalize_detail(payload, hit, source=self.name)


def _load(body: bytes) -> dict:
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProviderError("Grants.gov returned a body that is not JSON") from exc
    if payload.get("errorcode") not in (0, None):
        raise ProviderError(payload.get("msg") or "Grants.gov error")
    return payload
