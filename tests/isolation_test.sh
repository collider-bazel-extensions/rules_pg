#!/usr/bin/env bash
# isolation_test.sh
#
# Nothing a pg_server instance does is written outside $TEST_TMPDIR:
#   - it runs from a read-only working directory with a read-only HOME and
#     TMPDIR;
#   - the test makes it write what it can: tables, an index, a sort that
#     spills to a temp file, a temp table, a parallel query (dynamic shared
#     memory), a checkpoint, statistics;
#   - while it runs, neither the postmaster nor any of its children maps a
#     file under /dev/shm (POSIX dynamic shared memory, the PostgreSQL
#     default, puts segments there); parallel workers did run;
#   - afterwards no file outside $TEST_TMPDIR is newer than a marker (in
#     /dev/shm: and still there 2 s later; see below).
#
# $1: rootpath of the pg_server; $2: its target name; $3: expected major

set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -n "${TEST_TMPDIR:-}" ]] || fail "\$TEST_TMPDIR not set"

SERVER="$TEST_SRCDIR/$TEST_WORKSPACE/$1"
NAME="$2"
MAJOR="$3"
ENV_FILE="$TEST_TMPDIR/$NAME.env"

ro="$TEST_TMPDIR/readonly"
mkdir -p "$ro"
marker="$TEST_TMPDIR/marker"
touch "$marker"
sleep 1   # mtime granularity
chmod 555 "$ro"

(cd "$ro" && HOME="$ro" TMPDIR="$ro" exec "$SERVER") > "$TEST_TMPDIR/server.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; chmod 755 "$ro"' EXIT
for _ in $(seq 1 300); do
    [[ -f "$ENV_FILE" ]] && break
    kill -0 "$pid" 2>/dev/null || { cat "$TEST_TMPDIR/server.log" >&2; fail "server exited"; }
    sleep 0.1
done
[[ -f "$ENV_FILE" ]] || { cat "$TEST_TMPDIR/server.log" >&2; fail "env file not written"; }
set -a; source "$ENV_FILE"; set +a
for v in PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PG_BIN; do
    [[ -n "${!v:-}" ]] || fail "$v missing from $ENV_FILE"
done

q() {
    (cd "$ro" && HOME="$ro" TMPDIR="$ro" command "$PG_BIN/psql" -h "$PGHOST" -p "$PGPORT" \
        -U "$PGUSER" -d "$PGDATABASE" --no-password -v ON_ERROR_STOP=1 -t -A -c "$1")
}

v=$(q "SHOW server_version_num")
[[ "${v:0:2}" == "$MAJOR" ]] || fail "server_version_num $v, expected major $MAJOR"
echo "OK: PostgreSQL $v"

# Write everything we can.
q "CREATE TABLE big (k int, s text);
   INSERT INTO big SELECT g, md5(g::text) FROM generate_series(1, 200000) g;
   CREATE INDEX big_s ON big (s);
   ANALYZE big;
   CREATE TEMP TABLE scratch AS SELECT * FROM big LIMIT 10;" >/dev/null
q "SET work_mem = '64kB'; SELECT count(*) FROM (SELECT s FROM big ORDER BY s DESC) t;" >/dev/null
q "CHECKPOINT;" >/dev/null
echo "OK: wrote tables, an index, a spilled sort, a temp table, a checkpoint"

# A parallel query: its workers share state through dynamic shared memory.
plan=$(q "SET client_min_messages = warning; SET max_parallel_workers_per_gather = 2;
          SET parallel_setup_cost = 0; SET parallel_tuple_cost = 0;
          SET min_parallel_table_scan_size = 0;
          EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF) SELECT count(*) FROM big WHERE s LIKE 'a%';")
echo "$plan"
grep -Eq "Workers Launched: [1-9]" <<<"$plan" || fail "no parallel workers launched"
echo "OK: parallel query ran with workers"

# Nothing the instance maps lives under /dev/shm.
datadir=$(q "SHOW data_directory")
pm=$(head -n 1 "$datadir/postmaster.pid")
[[ -n "$pm" && -d "/proc/$pm" ]] || fail "postmaster pid not found in $datadir/postmaster.pid"
ppid_of() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $2}'; }
procs=("$pm")
for st in /proc/[0-9]*/stat; do
    p=${st#/proc/}; p=${p%/stat}
    pp=$(ppid_of "$p") || continue
    if [[ "$pp" == "$pm" ]]; then procs+=("$p"); fi
done
shm=$(for p in "${procs[@]}"; do grep -h ' /dev/shm/' "/proc/$p/maps" 2>/dev/null || true; done | awk '{print $6}' | sort -u)
if [[ -n "$shm" ]]; then
    echo "$shm" >&2
    fail "the instance (postmaster $pm and ${#procs[@]} processes) maps files under /dev/shm"
fi
echo "OK: none of the ${#procs[@]} instance processes maps a file under /dev/shm"
[[ "$(q "SHOW dynamic_shared_memory_type")" == mmap ]] || fail "dynamic_shared_memory_type is not mmap"
[[ "$(q "SHOW unix_socket_directories")" == "" ]] || fail "unix_socket_directories is not empty"

# Where the instance lives.
inst="$TEST_TMPDIR/$NAME.pg"
[[ "$(realpath "$datadir")" == "$(realpath -m "$inst/pgdata")" ]] \
    || fail "data_directory is $datadir, want $inst/pgdata"
ls "$inst/pgdata/pg_dynshmem" | grep -q . || fail "$inst/pgdata/pg_dynshmem is empty"
[[ -f "$inst/pg.log" ]] || fail "$inst/pg.log missing"
echo "OK: data directory, dynamic shared memory and log under $inst"

kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
trap 'chmod 755 "$ro"' EXIT
[[ $rc == 0 ]] || fail "SIGTERM exit status $rc"
echo "OK: stopped"

# Nothing newer than the marker outside $TEST_TMPDIR, wherever the instance
# could write: the working directory and runfiles tree, /tmp (the sandbox's
# own), and, by name, the host-shared /var/tmp and /dev/shm.
outside=()
for d in "$PWD" "$TEST_SRCDIR" /tmp /var/tmp /dev/shm; do
    [[ -d "$d" ]] || continue
    filter=(cat)
    [[ "$d" == /var/tmp || "$d" == /dev/shm ]] && filter=(grep -iE 'postgres|pgsql|/pg')
    while IFS= read -r f; do outside+=("$f"); done < <(
        find "$d" -xdev \( -path "$TEST_TMPDIR" -o -path "$TEST_TMPDIR/*" \) -prune -o -newer "$marker" \
            ! -type d -user "$(id -u)" -print 2>/dev/null | "${filter[@]}" || true)
done
# /dev/shm is host-wide: other tests' initdb (on PostgreSQL 14 and 15, its
# bootstrap backends use POSIX segments) create and remove segments while
# this runs. Keep only what is still there 2 s later, i.e. left behind; the
# instance's own use was checked through /proc above.
if (( ${#outside[@]} )); then
    sleep 2
    kept=()
    for f in "${outside[@]}"; do
        [[ "$f" == /dev/shm/* && ! -e "$f" ]] && { echo "ignored: $f (transient, gone)"; continue; }
        kept+=("$f")
    done
    outside=("${kept[@]+"${kept[@]}"}")
fi
if (( ${#outside[@]} )); then printf '  %s\n' "${outside[@]}" >&2; fail "files written outside \$TEST_TMPDIR"; fi
echo "OK: no file outside \$TEST_TMPDIR is newer than the start"
echo "--- PASS ---"
