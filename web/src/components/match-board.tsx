import { connection } from "next/server";
import { Badge } from "@/components/ui/badge";
import { buttonVariants } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import {
  databaseErrorMessage,
  loadBoard,
  type HealthRow,
  type MatchRow,
  type Profile,
} from "@/lib/db";
import {
  awardRange,
  formatDate,
  href,
  kindLabel,
  label,
  points,
  scoreText,
} from "@/lib/format";
import { cn } from "cn";

const SOURCES = [
  { id: "seed", label: "Sample notices" },
  { id: "grants_gov", label: "Grants.gov" },
  { id: "all", label: "Both" },
] as const;

const PARTS = [
  { key: "topic_points", label: "Topic", max: 40 },
  { key: "keyword_points", label: "Keyword", max: 25 },
  { key: "award_points", label: "Award", max: 15 },
  { key: "recency_points", label: "Recency", max: 10 },
  { key: "status_points", label: "Status", max: 10 },
] as const;

export async function MatchBoard({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await connection();
  const params = await searchParams;
  try {
    const board = await loadBoard(params.profile, params.source);
    return <BoardView board={board} />;
  } catch (error) {
    return <DatabaseDown message={databaseErrorMessage(error)} />;
  }
}

function BoardView({
  board,
}: {
  board: Awaited<ReturnType<typeof loadBoard>>;
}) {
  const eligible = board.matches.filter((row) => row.bucket === "eligible");
  const near = board.matches.filter((row) => row.bucket === "near_miss");
  const profile = board.selected;
  const slug = profile?.slug ?? null;

  return (
    <div className="mx-auto grid w-full max-w-6xl gap-6 px-4 py-6 md:grid-cols-[17.5rem_1fr] md:px-6">
      <aside className="space-y-3 md:sticky md:top-4 md:self-start">
        <div className="flex items-baseline justify-between">
          <h2 className="font-heading text-lg">Profiles</h2>
          <span className="text-xs text-muted-foreground">{board.profiles.length} demo</span>
        </div>
        <div className="flex gap-2 overflow-x-auto pb-1 md:flex-col md:overflow-visible">
          {board.profiles.map((item) => (
            <a
              key={item.slug}
              href={href(item.slug, board.source)}
              className={cn(
                "min-w-56 rounded-xl border bg-card p-3 text-left transition-colors md:min-w-0",
                item.slug === slug
                  ? "border-primary ring-2 ring-primary/30"
                  : "hover:bg-accent",
              )}
            >
              <span className="block text-sm font-medium">{item.display_name}</span>
              <span className="mt-1 block text-xs text-muted-foreground">
                {item.organization_kinds.map(kindLabel).join(", ")}
                {item.state_code ? ` · ${item.state_code}` : " · any state"}
              </span>
            </a>
          ))}
        </div>
        {board.profiles.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No demo profiles yet. Run <code>scripts/bootstrap_local.sh</code>.
          </p>
        ) : null}
      </aside>

      <section className="space-y-5">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex flex-wrap gap-2">
            {SOURCES.map((item) => (
              <a
                key={item.id}
                href={href(slug, item.id)}
                className={buttonVariants({
                  variant: board.source === item.id ? "default" : "outline",
                  size: "sm",
                })}
              >
                {item.label}
              </a>
            ))}
          </div>
          <Budget health={board.health} />
        </div>

        {board.unknownSlug ? (
          <Card>
            <CardHeader>
              <CardTitle>No profile named {board.unknownSlug}</CardTitle>
              <CardDescription>
                Choose one of the demo profiles. Private profiles stay hidden from this role.
              </CardDescription>
            </CardHeader>
          </Card>
        ) : null}

        {profile ? <ProfileHeader profile={profile} asOf={board.asOf} /> : null}

        <div className="space-y-3">
          <h2 className="font-heading text-xl">Eligible</h2>
          {eligible.length === 0 ? (
            <Card>
              <CardContent className="text-sm leading-6 text-muted-foreground">
                Nothing in this source clears the hard rules for this profile. Closed
                windows, the wrong applicant type, the wrong state, an award outside the
                range, or the wrong opportunity kind all block a match.
              </CardContent>
            </Card>
          ) : (
            eligible.map((row) => <NoticeCard key={`${row.source}-${row.external_id}`} row={row} />)
          )}
        </div>

        <div className="space-y-3">
          <h2 className="font-heading text-xl">Near misses</h2>
          <p className="text-sm text-muted-foreground">
            Scored the same way, then held back by a blocking reason. Useful when a notice
            is close but the applicant cannot apply.
          </p>
          {near.length === 0 ? (
            <p className="text-sm text-muted-foreground">No near misses in this slice.</p>
          ) : (
            near.map((row) => <NoticeCard key={`${row.source}-${row.external_id}`} row={row} />)
          )}
        </div>
      </section>
    </div>
  );
}

function ProfileHeader({ profile, asOf }: { profile: Profile; asOf: string }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="font-heading text-2xl tracking-tight">
          {profile.display_name}
        </CardTitle>
        <CardDescription className="text-sm leading-6">{profile.summary}</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-wrap gap-2">
        {profile.organization_kinds.map((kind) => (
          <Badge key={kind} variant="secondary">
            {kindLabel(kind)}
          </Badge>
        ))}
        <Badge variant="outline">{profile.state_code ?? "Any state"}</Badge>
        <Badge variant="outline">{awardRange(profile.min_award, profile.max_award)}</Badge>
        {profile.interests.map((interest) => (
          <Badge key={interest} variant="outline">
            {kindLabel(interest)}
          </Badge>
        ))}
        <span className="self-center text-xs text-muted-foreground">As of {formatDate(asOf)}</span>
      </CardContent>
    </Card>
  );
}

function NoticeCard({ row }: { row: MatchRow }) {
  const blocked = row.bucket === "near_miss";
  const reasons = blocked ? row.blocking_reasons ?? [] : row.reasons ?? [];
  return (
    <Card>
      <CardHeader>
        <div className="flex flex-col-reverse gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div className="min-w-0 space-y-1">
            <p className="text-xs tracking-wide text-muted-foreground uppercase">
              {blocked ? "Near miss" : "Eligible"} · rank {row.rank}
            </p>
            <CardTitle className="font-heading text-xl leading-snug tracking-tight">
              {row.url ? (
                <a href={row.url} className="hover:underline" target="_blank" rel="noreferrer">
                  {row.title}
                </a>
              ) : (
                row.title
              )}
            </CardTitle>
            <CardDescription>
              {row.agency || "Agency not listed"} · {kindLabel(row.kind)} · {kindLabel(row.status)}
            </CardDescription>
          </div>
          <p className="shrink-0 font-heading text-3xl tabular-nums tracking-tight">
            <span className="mr-2 text-xs font-sans font-normal tracking-normal text-muted-foreground sm:hidden">
              Score
            </span>
            {scoreText(row.score)}
          </p>
        </div>
      </CardHeader>
      <CardContent className="space-y-4">
        {row.summary ? <p className="line-clamp-4 text-sm leading-6">{clip(row.summary)}</p> : null}
        <div className="grid gap-1.5">
          {PARTS.map((part) => (
            <Meter
              key={part.key}
              label={part.label}
              value={points(row[part.key])}
              max={part.max}
            />
          ))}
        </div>
        <Separator />
        <div className="flex flex-wrap gap-2">
          {reasons.map((reason) => (
            <Badge key={reason} variant={blocked ? "destructive" : "secondary"}>
              {label(reason)}
            </Badge>
          ))}
        </div>
        <p className="text-xs leading-5 text-muted-foreground">
          {awardRange(row.award_floor, row.award_ceiling)}
          {" · "}
          Closes {formatDate(row.close_date)}
          {row.geo_scope === "state" && row.states?.length
            ? ` · ${row.states.join(", ")}`
            : row.geo_scope
              ? ` · ${row.geo_scope}`
              : ""}
          {row.eligibility_basis === "narrative" ? " · Eligibility read from the notice text" : ""}
          {row.source === "grants_gov" ? " · Grants.gov" : " · Sample notice"}
        </p>
      </CardContent>
    </Card>
  );
}

function clip(text: string): string {
  const flat = text.replace(/\s+/g, " ").trim();
  if (flat.length <= 420) return flat;
  const cut = flat.slice(0, 420);
  const word = cut.lastIndexOf(" ");
  return `${(word > 280 ? cut.slice(0, word) : cut).trim()}…`;
}

function Meter({ label: name, value, max }: { label: string; value: number; max: number }) {
  const width = Math.max(0, Math.min(100, (value / max) * 100));
  return (
    <div className="grid grid-cols-[4.5rem_1fr_2.75rem] items-center gap-2 text-xs">
      <span className="text-muted-foreground">{name}</span>
      <span className="h-1.5 overflow-hidden rounded-full bg-muted">
        <span className="block h-full rounded-full bg-primary" style={{ width: `${width}%` }} />
      </span>
      <span className="text-right tabular-nums">{scoreText(String(value))}</span>
    </div>
  );
}

function Budget({ health }: { health: HealthRow[] }) {
  const row = health[0];
  if (!row) return null;
  const name = row.provider === "grants_gov" ? "Grants.gov" : row.provider;
  return (
    <p className="text-xs text-muted-foreground">
      {name} budget: {row.requests_used} of {row.daily_request_budget} requests used, {row.remaining}{" "}
      left{row.last_run_status ? `, last run ${row.last_run_status}` : ""}
    </p>
  );
}

function DatabaseDown({ message }: { message: string }) {
  return (
    <div className="mx-auto max-w-xl px-4 py-10">
      <Card>
        <CardHeader>
          <CardTitle className="font-heading text-2xl">Database not ready</CardTitle>
          <CardDescription className="text-sm leading-6">{message}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-3 text-sm leading-6">
          <p>From the repository root:</p>
          <pre className="overflow-x-auto rounded-lg bg-muted p-3 text-xs">
            scripts/bootstrap_local.sh
          </pre>
          <p className="text-muted-foreground">
            The page reads <code>public.demo_profiles</code>, <code>public.match_profile</code>, and{" "}
            <code>public.sync_health</code> as the demo role. It does not call Grants.gov.
          </p>
        </CardContent>
      </Card>
    </div>
  );
}
