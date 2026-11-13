#!/usr/bin/env bash
# Applies every migration in supabase/migrations to a THROWAWAY Supabase Postgres
# container, then runs the behaviour checks in supabase/tests/*.sql. The container is
# removed on exit. This never connects to a real project.
#
#   scripts/verify-migrations.sh
#
# Exit status is non-zero if a migration fails to apply or any check prints FAIL.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${SUPABASE_PG_IMAGE:-public.ecr.aws/supabase/postgres:17.6.1.165}"
NAME="st-migration-check-$$"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Starting throwaway database ($IMAGE)…"
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres "$IMAGE" >/dev/null

run_sql() {
  docker exec -i -e PGPASSWORD=postgres "$NAME" \
    psql -U postgres -h localhost -d postgres -v ON_ERROR_STOP=1 -q "$@"
}

# The image finishes its own init scripts (roles, auth schema) after it first accepts
# connections, so wait for auth.users rather than just pg_isready.
for _ in $(seq 1 90); do
  if run_sql -tAc "select to_regclass('auth.users') is not null" 2>/dev/null | grep -qx t; then
    break
  fi
  sleep 2
done
run_sql -tAc "select to_regclass('auth.users') is not null" | grep -qx t || {
  echo "database did not finish initialising"; exit 1;
}

for migration in supabase/migrations/*.sql; do
  echo "apply  $migration"
  run_sql < "$migration" >/dev/null
done

status=0
for check in supabase/tests/*.sql; do
  echo "check  $check"
  output="$(run_sql < "$check")"
  printf '%s\n' "$output" | grep -E '^(ok|FAIL)' || true
  if printf '%s\n' "$output" | grep -q '^FAIL'; then status=1; fi
  if ! printf '%s\n' "$output" | grep -q '^ok'; then
    echo "FAIL   $check produced no results"; status=1
  fi
done

if [ "$status" -eq 0 ]; then echo "All migration checks passed."; else echo "Migration checks FAILED."; fi
exit "$status"
