"use client";

import { Button } from "@/components/ui/button";

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <main className="mx-auto flex min-h-full max-w-lg flex-col justify-center gap-4 px-6 py-16">
      <p className="font-heading text-3xl tracking-tight">The matcher hit an error</p>
      <p className="text-sm leading-6 text-muted-foreground">
        {error.message || "Something failed while reading the demo database."}
      </p>
      <div>
        <Button type="button" onClick={() => reset()}>
          Try again
        </Button>
      </div>
    </main>
  );
}
