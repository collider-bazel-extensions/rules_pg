#!/usr/bin/env bash
# config_test.sh
#
# pg_test's `config` reaches postgresql.conf: each value is quoted, so a
# quote in a value survives; later settings override rules_pg's defaults.

set -euo pipefail

require_env() {
    if [[ -z "${!1:-}" ]]; then
        echo "FAIL: \$$1 is not set" >&2
        exit 1
    fi
}
for v in PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD; do require_env "$v"; done
fail() { echo "FAIL: $*" >&2; exit 1; }

show() {
    command psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
        --no-password -v ON_ERROR_STOP=1 -t -A -c "SHOW $1"
}

[[ "$(show work_mem)" == 7MB ]] || fail "work_mem is $(show work_mem)"
[[ "$(show cluster_name)" == "rules_pg's test" ]] || fail "cluster_name is $(show cluster_name)"
[[ "$(show max_connections)" == 42 ]] || fail "max_connections is $(show max_connections)"
# rules_pg's default, overridden.
[[ "$(show synchronous_commit)" == on ]] || fail "synchronous_commit is $(show synchronous_commit)"
echo "OK: config applied"
echo "--- PASS ---"
