import { assertEquals } from "jsr:@std/assert";
import { chooseAgency, htmlToText, normalizeDetail, parseNarrativeApplicants } from "./grantsGov.ts";

const root = new URL("../../../fixtures/grants_gov/", import.meta.url);

Deno.test("NSF fixture matches the Python normalizer contract", async () => {
  const detail = JSON.parse(await Deno.readTextFile(new URL("opportunity_361238.json", root)));
  const search = JSON.parse(await Deno.readTextFile(new URL("search_scholarship.json", root)));
  const expected = JSON.parse(await Deno.readTextFile(new URL("expected_nsf_26503.json", root)));
  const row = await normalizeDetail(detail, search.data.oppHits[0]);
  const { raw: _raw, ...snapshot } = row;
  assertEquals(snapshot, expected);
  assertEquals((row.raw as Record<string, unknown>).token, undefined);
});

Deno.test("narrative parser drops negated sentences and PI rules", () => {
  const text = [
    "Who May Submit Proposals: Universities are not eligible. Individuals may apply.",
    "Who May Serve as PI: Small businesses are not eligible.",
  ].join(" ");
  assertEquals(parseNarrativeApplicants(text), ["individual"]);
});

Deno.test("a Grantor contact yields to the search-list agency", () => {
  assertEquals(chooseAgency("Andrew J Ford Grantor", "Idaho Field Office"), "Idaho Field Office");
  assertEquals(chooseAgency("U.S. National Science Foundation", "NSF"), "U.S. National Science Foundation");
});

Deno.test("double-encoded nbsp collapses", () => {
  assertEquals(htmlToText("Track:&amp;nbsp;open"), "Track: open");
});
