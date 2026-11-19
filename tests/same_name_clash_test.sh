#!/usr/bin/env bash
# same_name_clash_test.sh
#
# Two pg_server targets with the same name from different packages
# (//tests:two_a and //tests/clash:two_a) in one test would share
# $TEST_TMPDIR/two_a.env and $TEST_TMPDIR/two_a.pg. The second one must fail
# at once, before initdb, naming both labels, and leave the first alone.
#
# $1, $2: rootpaths of //tests:two_a and //tests/clash:two_a

set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -n "${TEST_TMPDIR:-}" ]] || fail "\$TEST_TMPDIR not set"

FIRST="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
CLASH="$TEST_SRCDIR/$TEST_WORKSPACE/$2"
ENV_FILE="$TEST_TMPDIR/two_a.env"

pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

"$FIRST" > "$TEST_TMPDIR/first.log" 2>&1 & pids+=($!)
for _ in $(seq 1 300); do
    [[ -f "$ENV_FILE" ]] && break
    kill -0 "${pids[0]}" 2>/dev/null || { cat "$TEST_TMPDIR/first.log" >&2; fail "//tests:two_a exited"; }
    sleep 0.1
done
[[ -f "$ENV_FILE" ]] || { cat "$TEST_TMPDIR/first.log" >&2; fail "//tests:two_a never wrote $ENV_FILE"; }
echo "OK: //tests:two_a is up"

cp "$ENV_FILE" "$TEST_TMPDIR/two_a.env.before"
start=$(date +%s)
rc=0
timeout 60 "$CLASH" > "$TEST_TMPDIR/clash.log" 2>&1 || rc=$?
elapsed=$(( $(date +%s) - start ))
cat "$TEST_TMPDIR/clash.log"
[[ $rc != 0 && $rc != 124 ]] || fail "the clashing pg_server did not fail at once (exit $rc)"
grep -qF "//tests/clash:two_a" "$TEST_TMPDIR/clash.log" || fail "the error does not name //tests/clash:two_a"
grep -qF "//tests:two_a" "$TEST_TMPDIR/clash.log" || fail "the error does not name //tests:two_a"
if grep -q "Running initdb" "$TEST_TMPDIR/clash.log"; then fail "the clashing pg_server ran initdb"; fi
(( elapsed < 10 )) || fail "the clashing pg_server took ${elapsed}s to fail"
echo "OK: //tests/clash:two_a failed at once (exit $rc, ${elapsed}s), naming both"

cmp -s "$ENV_FILE" "$TEST_TMPDIR/two_a.env.before" || fail "the clash changed $ENV_FILE"
(
    set -a; source "$ENV_FILE"; set +a
    command "$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
        --no-password -v ON_ERROR_STOP=1 -t -A -c "SELECT 1" >/dev/null
) || fail "//tests:two_a no longer answers"
echo "OK: //tests:two_a is untouched and still answers"

# The claim names the first target.
claim="$TEST_TMPDIR/two_a.claim"
[[ -f "$claim" ]] || fail "$claim missing"
python3 -I - "$claim" <<'EOF' || fail "claim content: $(cat "$claim")"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["label"] == "//tests:two_a", c
assert c["rule"] == "pg_server", c
assert isinstance(c["pid"], int), c
EOF
echo "OK: $claim: $(cat "$claim")"

kill -TERM "${pids[0]}"
rc=0; wait "${pids[0]}" || rc=$?
pids=()
[[ $rc == 0 ]] || fail "//tests:two_a exited $rc after SIGTERM"
echo "--- PASS ---"
