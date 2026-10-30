#!/usr/bin/env bash
# schema_smoke_test.sh
#
# Verifies that the schema was applied correctly by the pg_test launcher.
# Relies on PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD being set.

set -euo pipefail

require_env() {
    local var="$1"
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set" >&2
        exit 1
    fi
}

require_env PGHOST
require_env PGPORT
require_env PGDATABASE
require_env PGUSER
require_env PGPASSWORD

psql() {
    PGPASSWORD="$PGPASSWORD" command psql \
        -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
        --no-password -v ON_ERROR_STOP=1 -t -A "$@"
}

echo "--- schema_smoke_test ---"
echo "Connecting to $PGDATABASE on $PGHOST:$PGPORT as $PGUSER"

# Verify tables exist
for table in users posts tags post_tags; do
    count=$(psql -c "SELECT COUNT(*) FROM information_schema.tables
                     WHERE table_schema='public' AND table_name='$table';")
    if [[ "$count" != "1" ]]; then
        echo "FAIL: table '$table' not found" >&2
        exit 1
    fi
    echo "OK: table '$table' exists"
done

# Verify users table is empty (no seed loaded in this test)
user_count=$(psql -c "SELECT COUNT(*) FROM users;")
if [[ "$user_count" != "0" ]]; then
    echo "FAIL: expected 0 users (no seed), got $user_count" >&2
    exit 1
fi
echo "OK: users table is empty (no seed)"

# Verify index exists
idx_count=$(psql -c "SELECT COUNT(*) FROM pg_indexes
                     WHERE tablename='posts' AND indexname='posts_user_id_idx';")
if [[ "$idx_count" != "1" ]]; then
    echo "FAIL: index posts_user_id_idx not found" >&2
    exit 1
fi
echo "OK: index posts_user_id_idx exists"

# For the per-version targets (//tests:pg<major>_smoke_test), check the
# server really is that major: pg_test's postgres_version was once ignored
# and every version ran PostgreSQL 16.
if [[ "${TEST_TARGET:-}" =~ :pg([0-9]+)_smoke_test$ ]]; then
    want="${BASH_REMATCH[1]}"
    got=$(( $(psql -c "SHOW server_version_num;") / 10000 ))
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: expected PostgreSQL $want, server is $got" >&2
        exit 1
    fi
    echo "OK: server is PostgreSQL $got ($(psql -c 'SHOW server_version;'))"
fi

echo "--- PASS ---"
