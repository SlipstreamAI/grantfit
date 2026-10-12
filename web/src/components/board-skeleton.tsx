export function BoardSkeleton() {
  return (
    <div className="mx-auto grid w-full max-w-6xl gap-6 px-4 py-6 md:grid-cols-[17rem_1fr] md:px-6">
      <div className="h-64 animate-pulse rounded-xl bg-muted" />
      <div className="space-y-4">
        <div className="h-24 animate-pulse rounded-xl bg-muted" />
        <div className="h-40 animate-pulse rounded-xl bg-muted" />
        <div className="h-40 animate-pulse rounded-xl bg-muted" />
      </div>
    </div>
  );
}
