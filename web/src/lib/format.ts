const REASONS: Record<string, string> = {
  window_open: "Open now",
  window_forecasted: "Forecasted",
  window_unknown: "Window unknown",
  closed: "Closed or past the deadline",
  applicant_unrestricted: "Any applicant type",
  applicant_type_unspecified: "Applicant type not stated",
  applicant_type_match: "Applicant type fits",
  applicant_type_mismatch: "Applicant type does not fit",
  geo_national: "Open nationwide",
  geo_profile_national: "Profile has no state limit",
  geo_state_match: "State matches",
  geo_mismatch: "Wrong state",
  award_mismatch: "Award size is outside the profile",
  award_unconstrained: "Award size not fully stated",
  award_overlap: "Award range overlaps",
  kind_unconstrained: "No opportunity-kind preference",
  kind_match: "Opportunity kind fits",
  kind_mismatch: "Opportunity kind does not fit",
};

const KINDS: Record<string, string> = {
  grant: "Grant",
  scholarship: "Scholarship",
  fellowship: "Fellowship",
  cooperative_agreement: "Cooperative agreement",
  other: "Other",
  nonprofit: "Nonprofit",
  university: "University",
  individual: "Individual",
  tribal_government: "Tribal government",
  state_government: "State government",
  local_government: "Local government",
  small_business: "Small business",
  school_district: "School district",
};

export function label(value: string): string {
  return REASONS[value] ?? KINDS[value] ?? value.replaceAll("_", " ");
}

export function kindLabel(value: string): string {
  return KINDS[value] ?? value.replaceAll("_", " ");
}

const money = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

export function formatMoney(value: string | null): string | null {
  if (value == null || value === "") return null;
  const amount = Number(value);
  if (!Number.isFinite(amount)) return null;
  return money.format(amount);
}

export function awardRange(floor: string | null, ceiling: string | null): string {
  const low = formatMoney(floor);
  const high = formatMoney(ceiling);
  if (low && high) return `${low}–${high}`;
  if (high) return `Up to ${high}`;
  if (low) return `From ${low}`;
  return "Award not listed";
}

export function formatDate(value: string | null): string {
  if (!value) return "—";
  const [year, month, day] = value.split("-").map(Number);
  if (!year || !month || !day) return value;
  return new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  }).format(new Date(Date.UTC(year, month - 1, day)));
}

export function points(value: string): number {
  const amount = Number(value);
  return Number.isFinite(amount) ? amount : 0;
}

export function scoreText(value: string): string {
  const amount = points(value);
  return amount.toFixed(amount % 1 === 0 ? 0 : 2);
}

export function href(profile: string | null, source: string): string {
  const params = new URLSearchParams();
  if (profile && profile !== "harborlight") params.set("profile", profile);
  if (source !== "seed") params.set("source", source);
  const query = params.toString();
  return query ? `/?${query}` : "/";
}
