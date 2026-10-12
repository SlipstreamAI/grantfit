import { BoardSkeleton } from "@/components/board-skeleton";

export default function Loading() {
  return (
    <main>
      <header className="border-b bg-card/80">
        <div className="mx-auto flex max-w-6xl items-end justify-between gap-4 px-4 py-5 md:px-6">
          <div>
            <p className="font-heading text-2xl tracking-tight">GrantFit</p>
            <p className="text-sm text-muted-foreground">Loading matches from Postgres…</p>
          </div>
        </div>
      </header>
      <BoardSkeleton />
    </main>
  );
}
