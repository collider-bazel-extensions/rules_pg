#!/usr/bin/env bash
# pg_test forwards `args` and `env` (with $(rootpath) / $(rlocationpath)
# expanded) to the wrapped test, after the database is up (rules_pg#5).
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "$#" == 4 ]] || fail "want 4 args, got $#: $*"
[[ "$1" == one && "$2" == "two words" ]] || fail "plain args: $1 / $2"
[[ "$3" == tests/args/fixture.txt ]] || fail "\$(rootpath): $3"
[[ "$4" == _main/tests/args/fixture.txt ]] || fail "\$(rlocationpath): $4"
[[ "$(cat "$3")" == "arg fixture" ]] || fail "rootpath not readable from the test's cwd"
[[ "$(cat "$TEST_SRCDIR/$4")" == "arg fixture" ]] || fail "rlocationpath not under TEST_SRCDIR"
[[ "${PG_ARGS_PLAIN:-}" == plain ]] || fail "env not forwarded: PG_ARGS_PLAIN=${PG_ARGS_PLAIN:-}"
[[ "${PG_ARGS_FILE:-}" == tests/args/fixture.txt ]] || fail "env \$(rootpath): ${PG_ARGS_FILE:-}"
psql -tAc 'select 1' | grep -qx 1 || fail "database not reachable"
echo "PASS"
