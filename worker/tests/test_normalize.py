import json
from pathlib import Path

from grantfit.normalize import applicant_eligibility, normalize_detail, parse_narrative_applicants
from grantfit.providers.grants_gov import GrantsGovProvider

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "fixtures" / "grants_gov"


def test_search_decodes_entities_and_maps_status():
    payload = json.loads((FIXTURES / "search_scholarship.json").read_text())
    hits = GrantsGovProvider().parse_search(json.dumps(payload).encode())
    assert hits[0]["external_id"] == "361238"
    assert hits[0]["status"] == "open"
    assert hits[0]["open_date"] == "2026-02-04"
    assert "&" not in hits[1]["title"]
    assert "Scholarship" in hits[1]["title"]


def test_nsf_detail_is_an_institutional_grant_not_a_student_scholarship():
    detail = json.loads((FIXTURES / "opportunity_361238.json").read_text())
    hit = json.loads((FIXTURES / "search_scholarship.json").read_text())["data"]["oppHits"][0]
    row = normalize_detail(detail, hit)
    assert row["external_id"] == "361238"
    assert row["opportunity_number"] == "26-503"
    assert row["kind"] == "grant"
    assert row["tags"] == ["scholarship_program"]
    assert row["eligible_applicants"] == ["nonprofit", "university"]
    assert row["eligibility_basis"] == "narrative"
    assert row["topics"] == ["education", "stem"]
    assert row["award_floor"] == 300000
    assert row["award_ceiling"] == 2500000
    assert row["open_date"] == "2026-02-04"
    assert row["close_date"] == "2027-04-05"
    assert row["status"] == "open"
    assert row["agency_code"] == "NSF"
    assert "token" not in row["raw"]
    assert row["keywords"][:4] == ["artificial", "intelligence", "cybersecurity", "education"]
    snapshot = {key: value for key, value in row.items() if key != "raw"}
    expected = json.loads((FIXTURES / "expected_nsf_26503.json").read_text())
    assert expected == snapshot


def test_grantor_contact_does_not_replace_the_listed_agency():
    row = normalize_detail(
        {
            "data": {
                "id": 329436,
                "opportunityTitle": "Scholarship support",
                "synopsis": {"agencyName": "Andrew J Ford Grantor", "agencyCode": "DOE-ID"},
            }
        },
        {"agency": "Idaho Field Office", "oppStatus": "posted"},
    )
    assert row["agency"] == "Idaho Field Office"


def test_narrative_respects_negation_and_ignores_pi_rules():
    text = (
        "Who May Submit Proposals: Universities are not eligible. Individuals may apply. "
        "Who May Serve as PI: Small businesses are not eligible."
    )
    assert parse_narrative_applicants(text) == ["individual"]


def test_structured_codes_win_over_the_narrative():
    row = normalize_detail({
        "data": {
            "id": 9,
            "opportunityNumber": "X",
            "opportunityTitle": "Community clinics",
            "synopsis": {
                "agencyName": "HRSA",
                "agencyCode": "HRSA",
                "synopsisDesc": "<p>Health clinics.</p>",
                "applicantEligibilityDesc": "Universities may apply.",
                "applicantTypes": [{"id": "12", "description": "Nonprofits having a 501(c)(3) status"}],
                "fundingInstruments": [{"id": "G", "description": "Grant"}],
                "fundingActivityCategories": [{"id": "HL", "description": "Health"}],
                "awardFloor": "1000",
                "awardCeiling": "2000",
                "postingDateStr": "2026-09-01-00-00-00",
                "responseDateStr": "2027-01-01-00-00-00",
            },
        }
    }, {"oppStatus": "posted"})
    assert row["eligible_applicants"] == ["nonprofit"]
    assert row["eligibility_basis"] == "structured"
    assert row["topics"] == ["health"]
    assert row["kind"] == "grant"


def test_code_25_with_no_narrative_fails_closed():
    eligible, basis = applicant_eligibility(
        [{"id": "25", "description": "Others (see text field entitled \"Additional Information on Eligibility\")"}],
        "",
    )
    assert eligible == []
    assert basis == "see_text"
