#!/usr/bin/env bash
# Inside a pg_test, the PostgreSQL clients are the bundled ones, at the
# test's version, never the host's (rules_pg#7); the bundled lib dir is not
# on the library path, where host programs would load it.
# Argv: <major version>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
want="$1"
[[ -n "${PG_BIN:-}" && -d "$PG_BIN" ]] || fail "PG_BIN not set to a directory: '${PG_BIN:-}'"
case "$PG_BIN" in "$TEST_SRCDIR"/*) ;; *) fail "PG_BIN $PG_BIN is not in the runfiles ($TEST_SRCDIR)";; esac
for tool in psql pg_dump pg_isready createdb dropdb pg_restore; do
  got=$(command -v "$tool") || fail "$tool not on PATH"
  [[ "$got" == "$PG_BIN/$tool" ]] || fail "$tool resolves to $got, not $PG_BIN/$tool"
  v=$("$tool" --version)
  [[ "$v" =~ \(PostgreSQL\)\ $want\. ]] || fail "$tool --version: $v (want $want.x)"
done
lib="$(dirname "$PG_BIN")/lib"
case ":${LD_LIBRARY_PATH:-}:${DYLD_LIBRARY_PATH:-}:" in *":$lib:"*|*"$(readlink -f "$lib"):"*) fail "the bundled lib dir is on the library path";; esac
createdb extra_db || fail "createdb"
[[ "$(psql -d extra_db -tAc 'select current_database()')" == extra_db ]] || fail "psql into the new database"
[[ "$(psql -tAc 'show server_version_num')" == "$want"* ]] || fail "server version"
echo "PASS: bundled $want clients on PATH ($PG_BIN)"
