#!/usr/bin/env bash
#
# load.sh — build the sample databases for "SQL from My Heart".
#
#   ./load.sh retail sm        one dataset, small
#   ./load.sh all sm           all three, small
#   ./load.sh telemetry lg     one dataset, large
#
# Connection comes from the standard libpq environment variables, defaulting to a
# local cluster as set up in Chapter 2:
#
#   PGHOST      (default: localhost)
#   PGPORT      (default: 5432)
#   PGUSER      (default: your OS username, which is what Homebrew and most
#                Linux packages give you)
#   PGPASSWORD  (not set by default; use ~/.pgpass for anything long-lived)
#
# Re-running is safe. Each dataset's database is dropped and recreated from
# scratch, so there is no half-loaded state to reason about.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PSQL="${PSQL:-psql}"

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-$(id -un)}"
# PGDATABASE would override the -d we pass on every call. Get it out of the way.
unset PGDATABASE

MIN_VERSION_NUM=150000
DATASETS="retail telemetry hr"

die() {
    printf '\nload.sh: %s\n\n' "$1" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF

usage: ./load.sh <retail|telemetry|hr|all> <sm|lg>

  sm   about 10,000 rows per dataset. Loads in under a second.
  lg   10,000,000+ rows for telemetry, proportionally large for the others.
       Takes minutes and several GB. You do not need it before Part VIII.

examples:
  ./load.sh retail sm
  ./load.sh all sm
  ./load.sh telemetry lg

connection is taken from PGHOST / PGPORT / PGUSER / PGPASSWORD
(currently: host=${PGHOST} port=${PGPORT} user=${PGUSER})

EOF
    exit 2
}

# --------------------------------------------------------------- argument parsing
[ $# -eq 2 ] || usage

TARGET="$1"
SIZE="$2"

case "$TARGET" in
    retail|telemetry|hr) TO_LOAD="$TARGET" ;;
    all)                 TO_LOAD="$DATASETS" ;;
    *)                   usage ;;
esac

case "$SIZE" in
    sm) DATA_FILE="seed-sm.sql" ;;
    lg) DATA_FILE="generate-lg.sql" ;;
    *)  usage ;;
esac

# --------------------------------------------------------------- preflight
command -v "$PSQL" >/dev/null 2>&1 || die \
"cannot find '$PSQL' on your PATH.
  Install the PostgreSQL client tools, or point PSQL at the binary:
    PSQL=/opt/homebrew/opt/libpq/bin/psql ./load.sh $TARGET $SIZE"

for ds in $TO_LOAD; do
    [ -f "$HERE/$ds/schema.sql" ]  || die "missing $HERE/$ds/schema.sql"
    [ -f "$HERE/$ds/$DATA_FILE" ]  || die "missing $HERE/$ds/$DATA_FILE"
done

if ! version_num="$("$PSQL" -d postgres -X -A -t -q -c 'SHOW server_version_num' 2>&1)"; then
    die "cannot reach a PostgreSQL server at ${PGHOST}:${PGPORT} as user '${PGUSER}'.

  psql said:
    ${version_num}

  Check that the server is running and that PGHOST / PGPORT / PGUSER are right.
  On macOS with Homebrew:   brew services start postgresql@17
  On Debian/Ubuntu:         sudo systemctl start postgresql"
fi

version_num="$(printf '%s' "$version_num" | tr -d '[:space:]')"

case "$version_num" in
    ''|*[!0-9]*) die "could not read server_version_num from the server (got '${version_num}')." ;;
esac

if [ "$version_num" -lt "$MIN_VERSION_NUM" ]; then
    pretty="$("$PSQL" -d postgres -X -A -t -q -c 'SHOW server_version' | tr -d '[:space:]')"
    die "this book requires PostgreSQL 15 or newer; ${PGHOST}:${PGPORT} is running ${pretty}.

  Upgrade the server, or point PGHOST/PGPORT at a newer cluster."
fi

server_version="$("$PSQL" -d postgres -X -A -t -q -c 'SHOW server_version' | tr -d '[:space:]')"

printf '\n  server   %s:%s as %s (PostgreSQL %s)\n' \
    "$PGHOST" "$PGPORT" "$PGUSER" "$server_version"
printf '  loading  %s [%s]\n' "$TARGET" "$SIZE"
if [ "$SIZE" = "lg" ]; then
    printf '  note     the large variant takes minutes and several GB of disk.\n'
fi

# --------------------------------------------------------------- load
run_sql() {   # run_sql <database> <file>
    "$PSQL" -d "$1" -X -q -v ON_ERROR_STOP=1 -f "$2"
}

# One statement that counts every table in the database, so the script does not
# have to carry a hardcoded table list per dataset.
COUNT_SQL="
SELECT relname AS table,
       to_char((xpath('/row/c/text()',
                query_to_xml(format('SELECT count(*) AS c FROM %I.%I', schemaname, relname),
                             false, true, '')))[1]::text::bigint,
               'FM999,999,999') AS rows
FROM   pg_stat_user_tables
ORDER  BY relname;"

for ds in $TO_LOAD; do
    printf '\n--- %s -----------------------------------------------------\n' "$ds"
    started=$SECONDS

    "$PSQL" -d postgres -X -q -v ON_ERROR_STOP=1 \
        -c "DROP DATABASE IF EXISTS \"$ds\" WITH (FORCE)" \
        -c "CREATE DATABASE \"$ds\""

    run_sql "$ds" "$HERE/$ds/schema.sql"
    run_sql "$ds" "$HERE/$ds/$DATA_FILE"

    elapsed=$(( SECONDS - started ))

    "$PSQL" -d "$ds" -X -q -c "$COUNT_SQL"

    size="$("$PSQL" -d "$ds" -X -A -t -q \
        -c "SELECT pg_size_pretty(pg_database_size(current_database()))")"
    printf 'database "%s": %s on disk, loaded in %ds\n' "$ds" "$size" "$elapsed"
done

printf '\nDone. Connect with:  psql -d %s\n\n' "${TO_LOAD%% *}"
