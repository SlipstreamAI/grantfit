import { Suspense } from "react";
import { BoardSkeleton } from "@/components/board-skeleton";
import { MatchBoard } from "@/components/match-board";

export default function Home({ searchParams }: PageProps<"/">) {
  return (
    <main>
      <header className="border-b bg-card/80">
        <div className="mx-auto flex max-w-6xl flex-col gap-3 px-4 py-5 md:flex-row md:items-end md:justify-between md:px-6">
          <div className="max-w-2xl">
            <p className="font-heading text-3xl tracking-tight">GrantFit</p>
            <p className="mt-1 text-sm leading-6 text-muted-foreground">
              Federal notices, ranked against an applicant. Hard eligibility and the 100-point
              score both run in Postgres. This page only reads the result.
            </p>
          </div>
          <p className="max-w-sm text-xs leading-5 text-muted-foreground">
            Topic overlap is worth 40, keywords 25, award fit 15, recency 10, and an open
            status 10. A single blocking reason keeps a notice in the near-miss list.
          </p>
        </div>
      </header>
      <Suspense fallback={<BoardSkeleton />}>
        <MatchBoard searchParams={searchParams} />
      </Suspense>
    </main>
  );
}
