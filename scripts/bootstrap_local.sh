#!/usr/bin/env bash
# Create the local demo database, apply migrations, and load sample profiles.
# Pass --reset to drop the demo database first. Roles are cluster-wide.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="${GRANTFIT_DB:-grantfit}"

if ! pg_isready -q; then
  sudo pg_ctlcluster 16 main start
fi

if [[ "${1:-}" == "--reset" ]]; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB}' AND pid <> pg_backend_pid();" >/dev/null
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${DB};"
fi

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB}'" | grep -q 1; then
  sudo -u postgres createdb "$DB"
fi

if ! sudo -u postgres psql -d "$DB" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='grantfit'" | grep -q 1; then
  for f in "$ROOT"/supabase/migrations/*.sql; do
    echo "apply $(basename "$f")"
    sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB" -f "$f"
  done
fi

sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/supabase/seed.sql" >/dev/null

# Local demo passwords. They are not production secrets. See .env.example.
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB" <<'SQL'
ALTER ROLE grantfit_demo WITH LOGIN PASSWORD 'grantfit_local_dev';
ALTER ROLE grantfit_worker WITH LOGIN PASSWORD 'grantfit_local_dev';
ALTER ROLE grantfit_demo SET search_path = public, grantfit;
ALTER ROLE grantfit_worker SET search_path = public, grantfit;
SQL

echo "Demo database ready."
echo "  demo   postgresql://grantfit_demo:grantfit_local_dev@127.0.0.1:5432/${DB}"
echo "  worker postgresql://grantfit_worker:grantfit_local_dev@127.0.0.1:5432/${DB}"
