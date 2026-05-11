# rules_pg — Design Document

## Goals

`rules_pg` provides hermetic, parallel-safe PostgreSQL clusters for Bazel test
targets. The design is driven by three constraints:

1. **No CDN downloads required in CI.** Air-gapped and sandboxed build
   environments must work out of the box by pointing at the host-installed
   PostgreSQL.
2. **Full `--jobs` parallelism.** Each test must own an independent database
   cluster with no shared state. Port allocation must not serialize tests.
3. **Zero test-code changes.** Tests receive standard `PG*` environment
   variables and connect over TCP as if to any PostgreSQL server.

---

## High-level architecture

```
MODULE.bazel / WORKSPACE
        │
        ▼
  extensions.bzl / repositories.bzl          ← fetch or symlink PG binaries
        │
        ▼
  postgres_binary  (private/binary.bzl)       ← platform-agnostic binary target
        │
        ▼
  postgres_schema  (private/schema.bzl)       ← ordered SQL migration files
        │
        ▼
  pg_seed_data     (private/seed.bzl)         ← optional seed data (.sql / .csv)
        │
        ├──────────────────────────────────────────────┐
        ▼                                              ▼
  pg_test macro    (private/test.bzl)          pg_server rule  (private/server.bzl)
    ├── <name>_inner  — real test binary         long-running service binary
    └── <name>        — _pg_launcher_test              │
              │                                        ▼
              └─────────────┐              pg_health_check rule (private/server.bzl)
                            │                file-exists health probe
                            ▼
                       launcher.py
                    ┌──────┴──────┐
              RULES_PG_MODE=test  RULES_PG_MODE=server
                    │                    │
              _pg_setup()          _pg_setup()
                    │                    │
              os.execve(test)      write env file
                                         │
                                   signal.pause()
                                   SIGTERM → stop
```

---

## Provider chain

Providers carry structured data between rules without forcing callers to know
internal file layouts:

```
PostgresBinaryInfo        paths to pg_ctl, initdb, psql, pg_isready, pg_dump;
  │                       lib/ directory; declared major version
  │
  └─► PostgresSchemaInfo  ordered migration depset + a PostgresBinaryInfo
        │
        └─► PostgresSeedInfo  seed file depset + a PostgresSchemaInfo
```

`pg_test` and `pg_server` both accept a `schema` or `seed` label; they get the
full binary and migration chain transitively without extra wiring.

Using `depset(order="preorder")` for migration and seed files preserves the
caller's declared order through the entire build graph without copying lists.

---

## Binary acquisition

Two modes share the same downstream interface (`PostgresBinaryInfo`):

### Downloaded tarballs (`pg.version()`)

`_pg_binary_repo` calls `http_archive` / `rctx.download_and_extract` to fetch
EnterpriseDB binary distributions. A BUILD template is injected that produces
`postgres_binary_files`, making the layout identical to the system mode.
SHA-256 checksums are stored in `_PG_VERSIONS`; placeholder values are
committed and must be replaced before `pg.version()` is used in production.

### System PostgreSQL (`pg.system()`)

`_pg_system_binary_repo` symlinks host-installed binaries into an external repo
with the same `bin/` + `lib/` layout as a downloaded tarball. Auto-detection
runs at `bazel fetch` time (not at test time):

1. `bin_dir` — `command -v pg_ctl`, then probes common paths.
2. `lib_dir` — `pg_config --libdir`, then searches multiarch paths for
   `libpq.so*`.

Both modes produce a repo named `pg_<version>_<platform>` (e.g.,
`pg_16_linux_amd64`), so `defs.bzl` can select the right repo with a single
`select()` keyed on platform constraints — no other rule needs to know which
mode was used.

---

## `pg_test` macro

The macro expands into two targets:

- **`<name>_inner`** — the bare test binary built by whatever `test_rule` the
  caller supplies (`sh_test`, `go_test`, `py_test`, …). Tagged `manual` so
  Bazel never runs it directly.
- **`<name>`** — a `_pg_launcher_test` rule that wraps the inner binary. This
  is the target users put in `bazel test`.

Keeping the inner binary as a real Bazel target means caching, RBE, and IDE
integrations all work normally on the test code. The launcher adds no build-time
cost; it only runs at test time.

### Manifest

The launcher rule writes a JSON file at build time (`<name>_pg_manifest.json`)
containing resolved short paths for all binaries, migration files, seed files,
and configuration. This avoids passing a long argument list through a shell
wrapper and makes the launcher's startup code straightforward to read and test.

### Wrapper shell script

A generated `<name>_pg_wrapper.sh` sets `RULES_PG_MANIFEST` and
`RULES_PG_TEST_BINARY` then `exec`s `launcher.py`. It derives the runfiles
root from `$TEST_SRCDIR` (set by Bazel for all test targets) rather than
`$0.runfiles` to avoid double-nesting inside the sandbox.

---

## `pg_server` rule

`pg_server` produces a long-running executable suitable for use as an
`itest_service` in `rules_itest` or as a `data` dependency in any custom
launcher that needs to manage the database lifecycle separately from the test.

It uses the same manifest mechanism as `pg_test` — the same JSON, the same
runfile resolution, the same `_pg_setup` logic — but generates a different
wrapper script that sets `RULES_PG_MODE=server` instead of providing a test
binary.

### Readiness protocol

`pg_server` writes connection details to `$TEST_TMPDIR/<name>.env` as the
**last step** of setup, after migrations and seeds have been applied:

```
PGHOST=127.0.0.1
PGPORT=54321
PGDATABASE=test
PGUSER=postgres
PGPASSWORD=postgres
```

The file is written atomically (written to `<name>.env.tmp` then renamed) so
readers never observe a partial write. Its presence is a reliable proxy for
"the cluster is fully initialized and ready for connections."

### Shutdown

`pg_server` registers handlers for `SIGTERM` (sent by `rules_itest`'s service
manager after the test) and `SIGINT` (for interactive `bazel run` sessions).
Both handlers call `pg_ctl stop -m fast` then `sys.exit(0)`. `signal.pause()`
is used for the blocking wait, consuming no CPU.

### `pg_health_check` rule

`pg_health_check` generates a companion health-check binary for a `pg_server`
target. When invoked by `rules_itest`'s service manager, it exits 0 if and only
if `$TEST_TMPDIR/<server-name>.env` exists. The env file name convention is
shared between the two rules by deriving it from `ctx.attr.server.label.name`.

---

## Launcher lifecycle (`private/launcher.py`)

`launcher.py` has two entry points, selected by `RULES_PG_MODE`:

### Shared setup phase (`_pg_setup`)

```
read manifest
  ↓
resolve runfile paths
  ↓
ensure execute bits on PG binaries
  ↓
detect actual binary version (pg_ctl --version)
  ↓
allocate TCP port (socket.bind → port 0)
  ↓
initdb  (--auth=scram-sha-256, UTF-8, no locale)
  ↓
append ephemeral postgresql.conf overrides
  ↓
pg_ctl start  [+--socket-fd on PG 14–17]
  ↓
pg_isready poll (15 s timeout)
  ↓
CREATE DATABASE
  ↓
apply migrations in order (psql -f)
  ↓
load seed files (.sql via psql; .csv via \copy)
  ↓
return _PgState
```

### Test mode (`RULES_PG_MODE=test`, default)

```
_pg_setup(manifest) → state
  ↓
atexit.register(_stop_cluster, state)   ← best-effort; does not fire after execve
  ↓
os.execve(test_binary, env={PGHOST, PGPORT, …})
```

Cleanup relies on Bazel removing `$TEST_TMPDIR` after each test run. The atexit
handler is registered but does not fire after `os.execve` because the Python
process image is replaced; this is the same behaviour as the original single
`main()` function.

### Server mode (`RULES_PG_MODE=server`)

```
_pg_setup(manifest) → state
  ↓
write $RULES_PG_OUTPUT_ENV_FILE atomically
  ↓
register SIGTERM + SIGINT → _stop_cluster + sys.exit(0)
  ↓
signal.pause() loop   ← zero CPU
```

### Port allocation and the TOCTOU problem

`socket.bind(('127.0.0.1', 0))` asks the kernel for a free port. The kernel
guarantees uniqueness within the host, so parallel tests never receive the same
port — that is the core of the parallelism guarantee.

The race is between binding the socket in Python and PostgreSQL binding the same
port after we hand it the number. PostgreSQL 14–17 accept `--socket-fd`, which
passes the already-bound file descriptor directly; PostgreSQL never has to
re-bind, so the race is eliminated entirely. PostgreSQL 18 removed `--socket-fd`
(it conflicted with multi-postmaster changes), so on PG 18+ the socket is closed
just before `pg_ctl` runs and up to five retries handle the rare collision.

The launcher detects the actual binary version at runtime rather than trusting
the manifest's declared version because a `pg.system()` host may have a
different major version than what `postgres_version =` requested.

### Configuration overrides

The launcher appends to (rather than replaces) `postgresql.conf` so it never
has to parse existing config. PostgreSQL's "last value wins" rule makes
appending safe for numeric and string settings. Key choices:

| Setting | Value | Reason |
|---|---|---|
| `fsync` | `off` | Ephemeral cluster; durability not needed. Eliminates sync I/O. |
| `synchronous_commit` | `off` | Reduces write latency in tests. |
| `full_page_writes` | `off` | Not needed without `fsync`. |
| `logging_collector` | `off` | Forces logs to stderr → captured by `pg_ctl -l`. PG ≥ 15 defaults to `on`. |
| `unix_socket_directories` | `''` | Bazel sandboxes mount `/var/run/postgresql` read-only; socket paths exceed the 107-byte OS limit. All connections use TCP. |

### Seed data dispatch

Seed files are loaded in declaration order. `.sql` files are piped through
`psql -f`; `.csv` files use `\copy <table> FROM … CSV HEADER` where the table
name is derived from the filename stem. The `\copy` form (client-side) is used
instead of server-side `COPY` so the file path is local to the launcher process,
not to the PostgreSQL server process.

---

## `rules_itest` integration

`rules_itest` models integration tests as a service manager that starts
declared services in dependency order, runs the test binary, then stops all
services. `pg_server` maps directly onto the `itest_service` primitive:

```
rules_itest service manager
  ├── starts :db_svc  (pg_server binary)
  │     polls :db_health until exit 0
  ├── starts :api_svc (your HTTP service binary)
  │     polls HTTP health endpoint
  └── runs test binary
        reads $TEST_TMPDIR/db.env for PG* vars
        hits HTTP API, asserts, benchmarks
  └── sends SIGTERM to all services
        pg_server: pg_ctl stop -m fast
```

`$TEST_TMPDIR` is set by Bazel on the test runner process and inherited by all
service subprocesses, so all parties share the same directory for the env file.

---

## Toolchain integration

`toolchain/toolchain.bzl` defines a `POSTGRES_TOOLCHAIN_TYPE` and
`pg_toolchain` rule so that advanced downstream rules can consume
`PostgresBinaryInfo` via Bazel's standard toolchain resolution rather than
taking an explicit `binary =` attribute. `register_pg_toolchains()` generates
one toolchain target per (version × platform) pair with appropriate
`target_compatible_with` constraints.

The toolchain layer is optional — `postgres_schema` and `pg_test` default to a
well-known `Label("//:pg_default")` target, which is enough for most users.

---

## Bzlmod and WORKSPACE compatibility

`extensions.bzl` implements the Bzlmod module extension (`pg`); `repositories.bzl`
provides an equivalent `pg_system_dependencies()` function for legacy WORKSPACE
users. Both produce identically-named external repos, so all downstream `.bzl`
code is shared.

The `system` tag / function takes precedence over `version`; specifying both for
the same version string is silently treated as system-only. This ordering avoids
surprising network fetches when a system install exists.

---

## Test coverage gaps

The following areas of the codebase have no automated test coverage. Each entry
notes why a test is difficult to write within the current test infrastructure
(shell-only, no mocking framework, no Python test runner).

| Area | Gap | Reason untested |
|---|---|---|
| `_is_port_conflict` + retry loop | Port conflict retry path in `_pg_setup` | Requires a deterministic race: binding a port externally before `pg_ctl` sees it. Not reproducible without timing control or mocking. |
| `_find_runfile` | `RUNFILES_MANIFEST_FILE` fallback (third resolution strategy) | Requires injecting a fake runfiles manifest and clearing `RUNFILES_DIR`; needs a Python unit test runner not present in the project. |
| `pg_test` macro | `test_rule = go_test / py_test / cc_test` paths | Requires language rules (`rules_go`, `rules_python`, etc.) not declared in `MODULE.bazel`. |
| `pg.version()` / `_pg_binary_repo` | conda-forge dependency-closure download + SHA-256-pinned extraction (v0.4+) | Live |

---

## v0.4: hermetic `pg.version()` via conda-forge closure

`pg.version()` fetches the full transitive PostgreSQL dependency closure (~15-25 conda packages per pg major × platform — postgresql + libpq + libxml2 + openssl + readline + krb5 + libgcc + …) and extracts every package into one merged tree at the repo root (`bin/` + `lib/` + `share/`). Conda binaries are built with `RPATH=$ORIGIN/../lib`, so once the trees are merged, each binary finds its deps relative to its own location — no `LD_LIBRARY_PATH` munging required.

### Why conda-forge

The realistic alternatives all had blockers when v0.4 was scoped:

| Source | Blocker |
|---|---|
| EnterpriseDB CDN | 403 on direct curl — TOS gate, not a UA filter |
| Zonky `embedded-postgres-binaries` (Maven Central) | Ships only `initdb` + `pg_ctl` + `postgres`; missing `psql` + `pg_isready` |
| PG Apt Repository (`.deb`) | Linux-only; not actually hermetic (apt cache state, not sha-pinned) |
| Build our own + GitHub Releases | Multi-day pipeline; ongoing maintenance for new pg patch releases |

conda-forge ships the full binary set, multi-platform, sha-pinned in `repodata.json`, license-clean (PostgreSQL License redistribution), and is actively maintained.

### Extraction pipeline (per package)

1. `rctx.download(url, sha256)` — fetches the `.conda`.
2. `sh -c "cd sandbox && unzip -q package.conda"` — `.conda` is a zip; produces `pkg-<name>-<ver>.tar.zst` + `info-<name>-<ver>.tar.zst`.
3. `tar --zstd -xf sandbox/pkg-*.tar.zst` (or fallback `zstd -d -c <pkg> | tar -xf -`) — extracts to the repo root, **merging** with previously-extracted packages.

GNU tar 1.31+ (Ubuntu 20.04+) and macOS BSD tar both support `--zstd`. The fallback shells out to the `zstd` CLI for older hosts. Both `unzip` and zstd-aware tar are preinstalled on `ubuntu-latest`.

### Closure pinning

`tools/conda_versions.bzl` is auto-generated by `tools/update_conda_versions.py 14 15 16` from conda-forge's `repodata.json` per platform. The script:

1. Picks the highest-stable postgres build matching each major version.
2. BFS-expands the `depends` list; picks the highest-version package satisfying each constraint.
3. Falls back to `noarch` repodata for architecture-independent deps (tzdata).
4. Emits a `CONDA_CLOSURES = {(version, platform): [{name, url, sha256, …}, ...]}` dict.

Skipped: virtual packages (`__glibc`, `__osx`, etc.) — these are system constraints, not real packages. The binaries link against the host's libc directly, which is portable across modern glibc versions.

Total today: ~225 pins across 14/15/16 × 4 platforms (linux-amd64, linux-arm64, darwin-amd64, darwin-arm64). linux-arm64 entries are in the pin file but not yet wired through `//:BUILD.bazel`'s platform select — that's a v0.4.1 plumbing pass.

### Coexistence with `pg.system()`

Both modes are valid per-version. The extension partitions tags: `pg.system()` wins if both are declared for the same version. rules_pg's own `MODULE.bazel` exercises `pg.system(["14", "15"]) + pg.version(["16"])` so CI covers both code paths.

---

## Non-goals and known limitations

- **Windows**: No `win-64` plumbing in `_PLATFORMS`. The conda closure data is available; PRs welcome.
- **linux-arm64**: Closure pins exist in `tools/conda_versions.bzl` but `//:BUILD.bazel`'s platform `select()` doesn't yet include the constraint mapping. v0.4.1 plumbing.
- **Shared-server mode**: Each `pg_test` pays ~0.5–1 s for `initdb`. A
  shared-server mode (one cluster per test suite run) would cut this overhead
  but requires a coordination mechanism incompatible with Bazel's hermetic
  execution model. Not implemented.
- **Automatic migration ordering**: Files are applied in the order listed by the
  caller. There is no dependency resolver; numeric prefixes (`001_`, `002_`, …)
  are the recommended convention.
- **Unique server names**: The `$TEST_TMPDIR/<name>.env` convention requires
  that all `pg_server` targets in a single test run have distinct target names.
  Targets in different packages with the same local name would collide.
