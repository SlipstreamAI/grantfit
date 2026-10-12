#!/usr/bin/env bash
# Apply migrations to a throwaway database and run the pgTAP suite.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="${GRANTFIT_TEST_DB:-grantfit_test}"

if ! pg_isready -q; then
  sudo pg_ctlcluster 16 main start
fi

sudo -u postgres psql -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB}' AND pid <> pg_backend_pid();" >/dev/null
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DB};"
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB};"
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS pgtap;"

for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "apply $(basename "$f")"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB" -f "$f"
done

sudo -u postgres pg_prove --ext .sql -d "$DB" "$ROOT"/supabase/tests/*.sql
