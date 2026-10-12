-- Optional scheduler. No-ops when pg_cron is not installed (plain Postgres CI).
-- The job only enqueues a row. It does not call the network from the database.
-- GitHub Actions (.github/workflows/sync.yml) is the other scheduler and runs the worker directly.

DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron is not installed; use GitHub Actions or run the worker on a schedule';
    RETURN;
  END IF;

  CREATE EXTENSION IF NOT EXISTS pg_cron;

  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'cron' AND p.proname = 'unschedule'
  ) THEN
    BEGIN
      PERFORM cron.unschedule('grantfit-enqueue-sync');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'cron'
      AND p.proname = 'schedule'
      AND p.pronargs = 3
  ) THEN
    PERFORM cron.schedule(
      'grantfit-enqueue-sync',
      '15 6 * * *',
      $job$SELECT grantfit.enqueue_sync('grants_gov', 'pg_cron')$job$
    );
  ELSIF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'cron'
      AND p.proname = 'schedule'
      AND p.pronargs = 2
  ) THEN
    PERFORM cron.schedule(
      '15 6 * * *',
      $job$SELECT grantfit.enqueue_sync('grants_gov', 'pg_cron')$job$
    );
  ELSE
    RAISE NOTICE 'pg_cron.schedule was not found; enqueue was not scheduled';
  END IF;
END
$cron$;
