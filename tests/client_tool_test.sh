#!/usr/bin/env bash
# The runnable client targets (//:psql_<v>, pg_dump_<v>, ...; rules_pg#9)
# run the bundled clients at their version, without PG_BIN on PATH and
# without a library path, from $BUILD_WORKING_DIRECTORY when it is set.
# Argv: <major version>; env: TOOL_<name> = rootpath of each target.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
want="$1"
export PATH=/usr/bin:/bin
unset LD_LIBRARY_PATH DYLD_LIBRARY_PATH
for tool in psql pg_dump pg_restore pg_dumpall pg_isready; do
  var="TOOL_$tool"; t="${!var:?$var not set}"
  v=$("$t" --version) || fail "$t --version"
  [[ "$v" =~ \(PostgreSQL\)\ $want\. ]] || fail "$t --version: $v (want $want.x)"
done
"$TOOL_pg_isready" -q || fail "pg_isready against the test server"
[[ "$("$TOOL_psql" -tAc 'show server_version_num')" == "$want"* ]] || fail "psql server version"
work="$TEST_TMPDIR/caller"; mkdir -p "$work"
BUILD_WORKING_DIRECTORY="$work" "$TOOL_pg_dump" -f ./out.sql || fail "pg_dump"
[[ -s "$work/out.sql" ]] || fail "pg_dump -f ./out.sql did not write into BUILD_WORKING_DIRECTORY"
grep -q "PostgreSQL database dump" "$work/out.sql" || fail "out.sql is not a dump"
BUILD_WORKING_DIRECTORY="$work" "$TOOL_psql" -v ON_ERROR_STOP=1 -q -c 'create database restored' \
  || fail "create database"
BUILD_WORKING_DIRECTORY="$work" "$TOOL_psql" -v ON_ERROR_STOP=1 -q -d restored -f ./out.sql >/dev/null \
  || fail "psql -f ./out.sql from BUILD_WORKING_DIRECTORY"
echo "PASS: //:{psql,pg_dump,pg_restore,pg_dumpall,pg_isready}_$want"
