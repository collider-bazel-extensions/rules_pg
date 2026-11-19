#!/usr/bin/env bash
# two_servers_test.sh
#
# The test of //tests:two_servers_test, a rules_itest service_test that runs
# two pg_servers (:two_a, :two_b) as services. This script is itself a
# pg_test, so three instances share one $TEST_TMPDIR:
#   - each has its own data directory, $TEST_TMPDIR/<name>.pg/pgdata;
#   - each listens on its own port;
#   - a table written in one is not visible in the others.
# Before v0.7.0 all three used $TEST_TMPDIR/pgdata.
#
# rules_itest doesn't pass the pg_test's args, so its name is fixed here.

set -euo pipefail

require_env() {
    if [[ -z "${!1:-}" ]]; then
        echo "FAIL: \$$1 is not set" >&2
        exit 1
    fi
}
for v in TEST_TMPDIR PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PG_BIN; do require_env "$v"; done
fail() { echo "FAIL: $*" >&2; exit 1; }

SELF=two_servers_check  # this pg_test: $TEST_TMPDIR/two_servers_check.pg

# q <env file or "self"> <sql>: run SQL against one instance.
q() {
    local src="$1"; shift
    (
        if [[ "$src" != self ]]; then
            set -a; source "$TEST_TMPDIR/$src.env"; set +a
        fi
        command "$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
            --no-password -v ON_ERROR_STOP=1 -t -A -c "$1"
    )
}

for n in two_a two_b; do
    [[ -f "$TEST_TMPDIR/$n.env" ]] || fail "$TEST_TMPDIR/$n.env missing"
done

port() { (set -a; source "$TEST_TMPDIR/$1.env"; echo "$PGPORT"); }
pa=$(port two_a); pb=$(port two_b)
echo "self=$PGPORT two_a=$pa two_b=$pb"
[[ "$pa" != "$pb" && "$pa" != "$PGPORT" && "$pb" != "$PGPORT" ]] || fail "instances share a port"
echo "OK: three distinct ports"

# Each instance's data directory is its own, under its own name.
for src in self two_a two_b; do
    name="$src"; [[ "$src" == self ]] && name="$SELF"
    got=$(q "$src" "SHOW data_directory")
    want="$TEST_TMPDIR/$name.pg/pgdata"
    [[ "$(realpath "$got")" == "$(realpath -m "$want")" ]] || fail "$name: data_directory is $got, want $want"
    echo "OK: $name: data_directory=$got"
done
[[ ! -e "$TEST_TMPDIR/pgdata" ]] || fail "\$TEST_TMPDIR/pgdata exists (pre-v0.7.0 layout)"

# A write in one is invisible in the others.
q two_a "CREATE TABLE only_in_a (v int); INSERT INTO only_in_a VALUES (42);" >/dev/null
[[ "$(q two_a "SELECT v FROM only_in_a")" == 42 ]] || fail "two_a: write not readable"
for src in two_b self; do
    n=$(q "$src" "SELECT count(*) FROM information_schema.tables WHERE table_name = 'only_in_a'")
    [[ "$n" == 0 ]] || fail "$src sees two_a's table"
done
q self "CREATE TABLE only_in_self (v int)" >/dev/null
for src in two_a two_b; do
    n=$(q "$src" "SELECT count(*) FROM information_schema.tables WHERE table_name = 'only_in_self'")
    [[ "$n" == 0 ]] || fail "$src sees the pg_test's table"
done
echo "OK: writes stay in their own instance"

echo "--- PASS ---"
