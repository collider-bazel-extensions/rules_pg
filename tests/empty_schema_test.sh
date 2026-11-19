#!/usr/bin/env bash
# empty_schema_test.sh
#
# A pg_test with no schema, or with a postgres_schema that has no srcs, gets
# a running server with its (empty) database, in $TEST_TMPDIR/<name>.pg.
#
# $1: the pg_test's target name

set -euo pipefail

require_env() {
    if [[ -z "${!1:-}" ]]; then
        echo "FAIL: \$$1 is not set" >&2
        exit 1
    fi
}
for v in TEST_TMPDIR PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PG_BIN; do require_env "$v"; done
fail() { echo "FAIL: $*" >&2; exit 1; }

psql_run() {
    command psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
        --no-password -v ON_ERROR_STOP=1 -t -A "$@"
}

[[ "$(psql_run -c "SELECT current_database()")" == "$PGDATABASE" ]] || fail "not connected to $PGDATABASE"
n=$(psql_run -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
[[ "$n" == 0 ]] || fail "expected no tables in public, got $n"
psql_run -c "CREATE TABLE t (v int); INSERT INTO t VALUES (1);" >/dev/null
echo "OK: empty database $PGDATABASE is usable"

[[ -f "$TEST_TMPDIR/$1.pg/pgdata/PG_VERSION" ]] || fail "no cluster in \$TEST_TMPDIR/$1.pg/pgdata"
echo "OK: cluster in \$TEST_TMPDIR/$1.pg/pgdata"
echo "--- PASS ---"
