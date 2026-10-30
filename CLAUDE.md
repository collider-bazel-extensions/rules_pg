# rules_pg

Bazel rules for running PostgreSQL in tests. Provides hermetic, parallel-safe
PostgreSQL clusters for `*_test` targets with zero external dependencies at
runtime (uses the host-installed PostgreSQL; no CDN downloads required in CI).

## Repo layout

```
rules_pg/
├── MODULE.bazel              # Bzlmod module definition
├── WORKSPACE                 # Legacy workspace (compatibility shim)
├── defs.bzl                  # Public API re-exports
├── extensions.bzl            # Module extension: pg binary repos (download or system)
├── repositories.bzl          # Legacy WORKSPACE equivalents of extensions.bzl
├── private/
│   ├── binary.bzl            # postgres_binary rule + PostgresBinaryInfo provider
│   ├── schema.bzl            # postgres_schema rule + PostgresSchemaInfo provider
│   ├── seed.bzl              # pg_seed_data rule + PostgresSeedInfo provider
│   ├── test.bzl              # pg_test macro + _pg_launcher_test rule
│   ├── server.bzl            # pg_server rule + pg_health_check rule
│   └── launcher.py           # Shared launcher: initdb → migrate → seed → (exec test | serve)
├── toolchain/
│   └── toolchain.bzl         # Toolchain type + register helpers
└── tests/
    ├── BUILD.bazel
    ├── schema/               # Example migration SQL files (001_init.sql, 002_seed.sql)
    └── seed/                 # Example seed files (seed.sql, tags.csv)
```

## Key concepts

### Providers (chain)

```
PostgresBinaryInfo
  └─ PostgresSchemaInfo   (carries a PostgresBinaryInfo)
       └─ PostgresSeedInfo  (carries a PostgresSchemaInfo)
            └─ consumed by pg_test and pg_server
```

### `pg_test` isolation model

Every `pg_test` target gets:
- Its own `initdb`'d cluster under `$TEST_TMPDIR/pgdata`
- A randomly assigned free TCP port (TOCTOU-safe on PG 14–17; retried on PG 18+)
- Env vars injected: `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`

No shared state between tests → full `--jobs` parallelism is safe.

### Port allocation

The launcher uses Python's `socket.bind(('127.0.0.1', 0))` to get a free port.
On PostgreSQL 14–17 it passes the open socket fd directly to `pg_ctl` via
`--socket-fd`, eliminating the TOCTOU race. PostgreSQL 18 removed `--socket-fd`,
so on PG 18+ the socket is closed just before `pg_ctl` starts; up to 5 retries
handle the rare race.

Retries are only attempted on TCP port-binding conflicts (detected by scanning
the server log for "Address already in use"). Any other fatal error (config
problem, missing file, permission error) causes immediate failure with the
full server log printed.

Unix-domain sockets are disabled (`unix_socket_directories = ''`). Bazel
sandboxes mount `/var/run/postgresql` read-only, and the sandbox path is too
long for the 107-byte Unix socket path limit. All connections use TCP via
`PGHOST=127.0.0.1`.

### Binary source (distribution-independent)

`extensions.bzl` (Bzlmod) and `repositories.bzl` (WORKSPACE) both support two
modes, selected per version:

| Tag / function         | Behavior                                               |
|------------------------|--------------------------------------------------------|
| `pg.version()`         | Downloads a pre-built tarball from the EnterpriseDB CDN |
| `pg.system()`          | Symlinks the host-installed PostgreSQL binaries        |
| `pg_system_dependencies()` | WORKSPACE equivalent of `pg.system()`            |

**Auto-detection** — when `bin_dir` and `lib_dir` are omitted (the default),
the repository rule resolves them automatically:

1. `bin_dir`: runs `command -v pg_ctl`; falls back to probing
   `/usr/bin`, `/usr/local/bin`, `/usr/local/pgsql/bin`, `/opt/homebrew/bin`.
2. `lib_dir`: queries `pg_config --libdir`; falls back to searching
   `/usr/lib64`, `/usr/lib`, `/usr/local/lib`, and Debian/Ubuntu multiarch paths
   for `libpq.so*`.

If `pg_ctl` cannot be found, the build fails immediately with a clear error
message pointing to the missing binary and suggested install commands.

Platforms supported for downloaded tarballs: `linux_amd64`, `darwin_arm64`,
`darwin_amd64`.

## Supported PostgreSQL versions

- 14 (default)
- 15
- 16

The launcher detects the actual installed binary version at runtime via
`pg_ctl --version`, so it works correctly even when the host has a different
PostgreSQL version than what was declared in `postgres_version =`.

## Public API

```python
load("@rules_pg//defs.bzl",
    "pg_test",
    "pg_server",
    "pg_health_check",
    "postgres_schema",
    "pg_seed_data",
)

postgres_schema(
    name = "my_schema",
    srcs = glob(["migrations/*.sql"]),
    # Files are applied in the order listed. Use numeric prefixes: 001_init.sql
)

pg_seed_data(
    name = "my_seed",
    schema = ":my_schema",
    srcs = ["seed.sql"],          # .sql or .csv files; mixed lists are fine
)

# Single-binary test (schema + seed applied, test binary exec'd directly):
pg_test(
    name = "my_test",
    srcs = ["my_test.go"],
    schema = ":my_schema",          # required
    seed = ":my_seed",              # optional
    postgres_version = "16",        # optional; "14"…"18". Default: the schema's binary (16)
    database = "testdb",            # optional, default "test"
    pg_user = "postgres",           # optional
    pg_password = "postgres",       # optional
    test_rule = go_test,            # optional; default native.sh_test
    deps = [...],
)

# Long-running service (for rules_itest and multi-service orchestration):
pg_server(
    name = "my_db",
    schema = ":my_schema",          # required
    seed = ":my_seed",              # optional
    database = "testdb",            # optional, default "test"
    pg_user = "postgres",           # optional
    pg_password = "postgres",       # optional
)

# Health-check binary for rules_itest (exits 0 when my_db is fully ready):
pg_health_check(
    name = "my_db_health",
    server = ":my_db",
)
```

### `pg_server` readiness protocol

`pg_server` writes `$TEST_TMPDIR/<name>.env` atomically once the cluster is
fully ready — after initdb, server start, migrations, and seed data. The file
contains the standard `PG*` variables, one per line:

```
PGHOST=127.0.0.1
PGPORT=54321
PGDATABASE=testdb
PGUSER=postgres
PGPASSWORD=postgres
```

Tests that depend on the server source this file:

```bash
source "$TEST_TMPDIR/my_db.env"
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT 1"
```

`pg_server` stops the cluster cleanly on SIGTERM (sent by rules_itest after the
test) or SIGINT (Ctrl-C during `bazel run`).

### MODULE.bazel (Bzlmod)

```python
bazel_dep(name = "rules_pg", version = "0.1.0")

pg = use_extension("@rules_pg//:extensions.bzl", "pg")

# Use the host-installed PostgreSQL (auto-detects bin_dir and lib_dir):
pg.system(versions = ["14", "15", "16"])

# Or specify paths explicitly when auto-detection is unavailable:
# pg.system(versions = ["16"], bin_dir = "/usr/pgsql-16/bin", lib_dir = "/usr/pgsql-16/lib")

# Or download pre-built tarballs (requires CDN access + real SHA-256 sums):
# pg.version(versions = ["14"])

use_repo(pg, "pg_14_linux_amd64", "pg_14_darwin_arm64", "pg_14_darwin_amd64")
```

### WORKSPACE (legacy)

```python
load("@rules_pg//:repositories.bzl", "pg_system_dependencies")

# Auto-detect; or pass bin_dir/lib_dir for explicit paths:
pg_system_dependencies(versions = ["14", "15", "16"])
```

## Integration with rules_itest

`pg_server` and `pg_health_check` are designed to slot directly into
[rules_itest](https://github.com/dzbarsky/rules_itest) for multi-service
integration tests — e.g., testing an HTTP API that requires a database.

### Example: HTTP API integration test

```
myapp/
├── BUILD.bazel
├── migrations/
│   ├── 001_init.sql
│   └── 002_users.sql
├── seed/
│   └── test_users.sql
└── api_test.sh
```

```python
# myapp/BUILD.bazel
load("@rules_pg//defs.bzl", "postgres_schema", "pg_seed_data", "pg_server", "pg_health_check")
load("@rules_itest//:defs.bzl", "itest_service", "service_test")

postgres_schema(
    name = "schema",
    srcs = glob(["migrations/*.sql"]),
)

pg_seed_data(
    name = "seed",
    schema = ":schema",
    srcs = ["seed/test_users.sql"],
)

pg_server(
    name = "db",
    schema = ":schema",
    seed = ":seed",
)

pg_health_check(
    name = "db_health",
    server = ":db",
)

itest_service(
    name = "db_svc",
    exe          = ":db",
    health_check = ":db_health",
)

itest_service(
    name = "api_svc",
    exe  = "//myapp/server:bin",
    # Your server reads PG* env vars or sources $TEST_TMPDIR/db.env on startup.
    # Declare a dep so rules_itest starts the database before the API server:
    deps = [":db_svc"],
    http_health_check_address = "http://127.0.0.1:${PORT}/healthz",
    autoassign_port = True,
)

service_test(
    name     = "api_test",
    test     = ":api_test_bin",
    services = [":db_svc", ":api_svc"],
)

sh_test(
    name = "api_test_bin",
    srcs = ["api_test.sh"],
    data = ["@curl//:bin"],
    tags = ["manual"],
)
```

```bash
# myapp/api_test.sh
set -euo pipefail

# Source database connection details written by pg_server.
source "$TEST_TMPDIR/db.env"

# rules_itest exposes service ports via ASSIGNED_PORTS.
API_PORT=$(echo "$ASSIGNED_PORTS" | python3 -c "
import json, sys
ports = json.load(sys.stdin)
print(ports['//myapp:api_svc'])
")
API_URL="http://127.0.0.1:${API_PORT}"

# Verify the API can query the seeded database.
result=$(curl -sf "${API_URL}/users")
echo "$result" | grep -q "alice"

echo "PASS"
```

### Lifecycle under rules_itest

```
rules_itest service manager
  ├── starts :db_svc         (pg_server: initdb → migrate → seed → write env file)
  │     polls :db_health     (exits 0 when $TEST_TMPDIR/db.env exists)
  ├── starts :api_svc        (your HTTP service, reads PG* from env file or its own init)
  │     polls /healthz
  └── runs :api_test_bin     (sources env file, hits HTTP API)
  └── sends SIGTERM to all services
        :db_svc → pg_ctl stop -m fast
```

## Development

### Running the self-tests

```sh
bazel test //tests/...
```

All tests must pass before any commit with code changes.

All documentation (`README.md`, `DESIGN.md`, `CLAUDE.md`) must be updated to reflect any code changes before committing. This includes new rules, changed attributes, new public API surface, and behaviour changes.

### Test results (last full run: 2026-10-30)

All 12 tests pass on Linux x86_64 with the hermetic conda-forge binaries
(`pg.version()`; 14.24, 15.19, 16.15, 17.11, 18.6). Each `pg<N>_smoke_test`
checks `server_version_num` against the major in its target name.

| Test target                    | What it verifies                                                        | Result |
|--------------------------------|-------------------------------------------------------------------------|--------|
| `//tests:schema_smoke_test`    | Schema migrations applied; DDL/DML round-trip                           | PASSED |
| `//tests:seed_smoke_test`      | SQL seed data loaded; referential integrity join                        | PASSED |
| `//tests:pg14_smoke_test`      | pg_test macro with `postgres_version = "14"`                            | PASSED |
| `//tests:pg15_smoke_test`      | pg_test macro with `postgres_version = "15"`                            | PASSED |
| `//tests:pg16_smoke_test`      | pg_test macro with `postgres_version = "16"`                            | PASSED |
| `//tests:pg17_smoke_test`      | pg_test macro with `postgres_version = "17"`                            | PASSED |
| `//tests:pg18_smoke_test`      | pg_test macro with `postgres_version = "18"` (no `--socket-fd` path)    | PASSED |
| `//tests:pg_binary_test`       | PG binary present, version ≥ 14, DDL/DML, ROLLBACK                     | PASSED |
| `//tests:csv_seed_test`        | CSV seed loading via `\copy`; exact row counts                          | PASSED |
| `//tests:custom_db_test`       | Custom `database =` and `pg_user =` attributes                          | PASSED |
| `//tests:pg_server_test`       | pg_server start, env file, schema+seed, SIGTERM clean shutdown          | PASSED |
| `//tests:pg_health_check_test` | pg_health_check exits non-zero without env file, 0 when file is present | PASSED |

### Adding a new Postgres version

1. Find the tarball URLs and sha256 sums for `linux_amd64`, `darwin_arm64`, `darwin_amd64`.
2. Add entries to the `_PG_VERSIONS` dict in both `extensions.bzl` and `repositories.bzl`.
3. Add a smoke test target in `tests/BUILD.bazel` with `postgres_version = "<new>"`.
4. Run `bazel test //tests/...`.

### Launcher script

`private/launcher.py` is the heart of both `pg_test` and `pg_server`. The mode
is selected by the `RULES_PG_MODE` environment variable (set by the generated
wrapper script):

| Mode | Set by | Behaviour |
|---|---|---|
| `test` (default) | `pg_test` wrapper | `_pg_setup` → `os.execve(test_binary)` |
| `server` | `pg_server` wrapper | `_pg_setup` → write env file → `signal.pause()` until SIGTERM/SIGINT |

Both modes share `_pg_setup`, which:

1. Reads the JSON manifest written by the Bazel rule (`RULES_PG_MANIFEST`).
2. Resolves all runfile paths (external repos use `../repo/path`; workspace files use `<workspace>/path`).
3. Ensures all PostgreSQL binaries have the execute bit set.
4. Detects the actual binary version via `pg_ctl --version` (needed for `--socket-fd` gating).
5. Creates `$TEST_TMPDIR/pgdata` (mode 0700) and runs `initdb --auth=scram-sha-256`.
6. Writes ephemeral `postgresql.conf` overrides: port, `fsync=off`, `logging_collector=off`, `unix_socket_directories=''`.
7. Starts `pg_ctl`, passing `--socket-fd` on PG 14–17 (eliminated in PG 18).
8. Polls `pg_isready` until the server accepts connections (max 15 s).
9. Retries startup on port conflicts only; fails immediately on all other errors.
10. Creates the test database, applies migrations in order, loads seed data.
11. Returns a `_PgState` dataclass with connection details.

After `_pg_setup`, test mode calls `os.execve` with `PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD`
set; server mode writes `$TEST_TMPDIR/<name>.env` and blocks.

### Test script requirements

All test shell scripts must:
- Begin with `set -euo pipefail`.
- Use a `require_env VAR` guard for every `PG*` variable before first use.
- Use `command psql` (not bare `psql`) to avoid alias expansion.
- Pass `-v ON_ERROR_STOP=1` so SQL errors terminate the script immediately.

### Style

- All `.bzl` files use 4-space indentation.
- Provider fields are documented with inline comments.
- Public rules/macros have docstrings.
- `private/` contains implementation details; only `defs.bzl` is the stable API.

## Known limitations

- Windows is not supported (no pre-built binary source; PRs welcome).
- `pg_test` adds ~0.5–1 s overhead per test for `initdb`. For very large test
  suites, consider a shared-server mode (not yet implemented).
- Schema migration ordering relies on the caller listing files explicitly or
  using `glob()` with numeric prefixes. There is no automatic dependency solver.
- **PostgreSQL 14 reaches upstream end of life on 2026-11-12.** It is still
  offered (14.24) but should be dropped in a later release.
- **Legacy WORKSPACE downloads are broken on Linux.** `repositories.bzl` and
  `tools/update_checksums.sh` still point at EnterpriseDB tarballs (14.11 /
  15.6 / 16.2); the Linux one returns 403. Bzlmod's `pg.version()` (conda-forge)
  is unaffected. WORKSPACE has no 17/18 entries.
- The launcher doesn't put the hermetic `bin/` on the test's `PATH`, so tests
  that call `psql` use the host's client (any version can talk to the server).
- `pg_server` target names must be unique within a test run. Two `pg_server`
  targets with the same local name in different packages would write to the same
  `$TEST_TMPDIR/<name>.env` path.
