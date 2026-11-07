#!/usr/bin/env bash
# pg_server_test.sh
#
# Verifies pg_server lifecycle:
#   - starts an ephemeral cluster and writes the env file
#   - env file contains all required PG* variables, and PG_BIN (the bundled clients)
#   - database is reachable and schema + seed were applied
#   - SIGTERM causes a clean (exit 0) shutdown
#
# $1: rootpath of the pg_server binary (relative to TEST_SRCDIR)

set -euo pipefail

SERVER_BIN="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
# Env file name is derived from the pg_server target name: pg_server_test_svc
ENV_FILE="$TEST_TMPDIR/pg_server_test_svc.env"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "--- pg_server_test ---"

# Start the server in the background.  It inherits TEST_SRCDIR and TEST_TMPDIR
# from this test process, which is what the wrapper script needs.
"$SERVER_BIN" &
SERVER_PID=$!

# Wait up to 30 s for the env file to appear.  pg_server writes it only after
# _pg_setup completes (server ready, migrations applied, seed loaded).
echo "Waiting for env file: $ENV_FILE"
for i in $(seq 1 150); do
    [[ -f "$ENV_FILE" ]] && break
    sleep 0.2
done
if [[ ! -f "$ENV_FILE" ]]; then
    echo "FAIL: env file never appeared after 30 s" >&2
    exit 1
fi
echo "OK: env file appeared"

# Verify env file has all required variables.
source "$ENV_FILE"
for var in PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PG_BIN; do
    if [[ -z "${!var:-}" ]]; then
        echo "FAIL: $var is missing from env file" >&2
        exit 1
    fi
    echo "OK: $var=${!var}"
done

# Verify the database accepts connections.
psql_run() {
    PGPASSWORD="$PGPASSWORD" "$PG_BIN/psql" \
        -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
        --no-password -v ON_ERROR_STOP=1 -t -A "$@"
}

psql_run -c "SELECT 1;" >/dev/null
echo "OK: psql connection succeeded"

# Verify schema was applied (001_init.sql creates the users table).
table_count=$(psql_run -c "
    SELECT COUNT(*) FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'users';
")
if [[ "$table_count" != "1" ]]; then
    echo "FAIL: users table not found (schema not applied?)" >&2
    exit 1
fi
echo "OK: schema applied (users table present)"

# Verify seed data was loaded (test_seed has 2 users).
user_count=$(psql_run -c "SELECT COUNT(*) FROM users;")
if [[ "$user_count" != "2" ]]; then
    echo "FAIL: expected 2 users from seed, got $user_count" >&2
    exit 1
fi
echo "OK: seed applied (2 users)"

# Send SIGTERM and wait for pg_server to stop cleanly.
# The SIGTERM handler in main_server() calls pg_ctl stop then sys.exit(0).
kill -TERM "$SERVER_PID"
set +e
wait "$SERVER_PID"
EXIT_CODE=$?
set -e
SERVER_PID=""  # prevent double-kill in trap

if [[ "$EXIT_CODE" != "0" ]]; then
    echo "FAIL: pg_server exited with code $EXIT_CODE after SIGTERM (expected 0)" >&2
    exit 1
fi
echo "OK: pg_server exited cleanly (exit 0) after SIGTERM"

echo "--- PASS ---"
