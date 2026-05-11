# rules_pg

Hermetic PostgreSQL clusters for Bazel tests. Each `pg_test` target gets its
own isolated `initdb`'d cluster on a random port, spun up and torn down by the
test launcher. No system Postgres installation required. Full `--jobs`
parallelism is safe.

**Supported platforms:** Linux (x86\_64), macOS (arm64, x86\_64)  
**Supported PostgreSQL versions:** 14, 15, 16

---

## Contents

- [Installation](#installation)
  - [Bzlmod (MODULE.bazel)](#bzlmod-modulebazelbzlmod)
  - [Legacy WORKSPACE](#legacy-workspace)
- [Quickstart](#quickstart)
- [Rules](#rules)
  - [postgres\_schema](#postgres_schema)
  - [pg\_seed\_data](#pg_seed_data)
  - [pg\_test](#pg_test)
  - [pg\_server](#pg_server)
  - [pg\_health\_check](#pg_health_check)
  - [postgres\_binary](#postgres_binary)
- [rules\_itest integration](#rules_itest-integration)
- [Providers](#providers)
  - [PostgresBinaryInfo](#postgresbinaryinfo)
  - [PostgresSchemaInfo](#postgresschemainfo)
  - [PostgresSeedInfo](#postgresseedinfo)
- [Environment variables injected by pg\_test](#environment-variables-injected-by-pg_test)
- [Migration file ordering](#migration-file-ordering)
- [Seed data](#seed-data)
- [Using pg\_test with Go, Python, or C++](#using-pg_test-with-go-python-or-c)
- [Selecting a PostgreSQL version](#selecting-a-postgresql-version)
- [Parallelism and isolation](#parallelism-and-isolation)
- [Toolchain integration](#toolchain-integration)
- [FAQ](#faq)
- [Maintainers](#maintainers)

---

## Installation

### Bzlmod (MODULE.bazel)

Add to your `MODULE.bazel`:

```python
bazel_dep(name = "rules_pg", version = "0.3.0")

pg = use_extension("@rules_pg//:extensions.bzl", "pg")

# Declare which PostgreSQL versions your workspace needs.
# At least one version is required.
pg.version(versions = ["14"])

# Bring the downloaded repositories into scope.
use_repo(pg, "pg_14_linux_amd64", "pg_14_darwin_arm64", "pg_14_darwin_amd64")
```

To use multiple versions:

```python
pg.version(versions = ["14", "15", "16"])

use_repo(pg,
    "pg_14_linux_amd64", "pg_14_darwin_arm64", "pg_14_darwin_amd64",
    "pg_15_linux_amd64", "pg_15_darwin_arm64", "pg_15_darwin_amd64",
    "pg_16_linux_amd64", "pg_16_darwin_arm64", "pg_16_darwin_amd64",
)
```

### Legacy WORKSPACE

```python
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "rules_pg",
    urls = ["https://github.com/example/rules_pg/archive/v0.1.0.tar.gz"],
    sha256 = "...",
    strip_prefix = "rules_pg-0.1.0",
)

load("@rules_pg//:repositories.bzl", "rules_pg_dependencies", "rules_pg_register_toolchains")

# Download pre-built PostgreSQL binaries.
rules_pg_dependencies(versions = ["14"])

# Register toolchains so Bazel can resolve the right binary per platform.
rules_pg_register_toolchains(versions = ["14"])
```

---

### CI setup (GitHub Actions)

`pg.system()` requires `pg_ctl` and friends on a discoverable path. On Ubuntu's GitHub runner the postgres binaries live under `/usr/lib/postgresql/<ver>/bin/`, not `/usr/bin/` (only thin wrappers for `psql` + `pg_isready` ship there). Add this step before `bazel build`:

```yaml
- name: Install PostgreSQL and put bin on PATH
  run: |
    set -euo pipefail
    sudo apt-get install -y postgresql
    pg_bin=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
    echo "$pg_bin" >> "$GITHUB_PATH"
```

Without this, `pg.system()`'s repository-rule fetch fails with `could not locate pg_ctl` (the error message includes the same snippet inline, but consumers usually copy from the README first). A fully hermetic binary toolchain — `pg.version()` that downloads + verifies — is tracked for v0.4; for now `pg.system()` is the only mode.

---

## Quickstart

**1.** Write your migrations. Use numeric prefixes so `glob()` ordering is
stable:

```
myapp/
  db/
    migrations/
      001_init.sql
      002_add_users.sql
      003_add_posts.sql
```

**2.** Declare the schema and a test in your `BUILD.bazel`:

```python
load("@rules_pg//:defs.bzl", "pg_test", "postgres_schema")

postgres_schema(
    name = "schema",
    srcs = glob(["db/migrations/*.sql"]),
)

pg_test(
    name = "db_test",
    srcs = ["db_test.sh"],
    schema = ":schema",
)
```

**3.** Read the injected environment variables from your test:

```bash
#!/usr/bin/env bash
# db_test.sh
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
     -c "SELECT COUNT(*) FROM users;"
```

**4.** Run:

```
bazel test //myapp:db_test
```

---

## Rules

### `postgres_schema`

```python
load("@rules_pg//:defs.bzl", "postgres_schema")

postgres_schema(
    name = "schema",
    srcs = [...],
    binary = None,        # optional; see postgres_binary
)
```

Declares an ordered set of SQL migration files that define the database schema
for a test. Files are applied to the test database via `psql` in the order
they appear in `srcs`.

**Attributes:**

| Attribute | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Target name. |
| `srcs` | `label_list` | required | `.sql` migration files, applied in listed order. |
| `binary` | `label` | `//:pg_default` | `postgres_binary` target supplying the server executables. Override to pin a specific version. |

**Example — explicit ordering:**

```python
postgres_schema(
    name = "schema",
    srcs = [
        "migrations/001_init.sql",
        "migrations/002_users.sql",
        "migrations/003_posts.sql",
    ],
)
```

**Example — glob with numeric prefixes:**

```python
postgres_schema(
    name = "schema",
    srcs = glob(["migrations/*.sql"]),
)
```

> **Warning:** `glob()` returns files in alphabetical order. If your filenames
> do not sort into the correct application order, list them explicitly.

---

### `pg_seed_data`

```python
load("@rules_pg//:defs.bzl", "pg_seed_data")

pg_seed_data(
    name = "seed",
    schema = ":schema",
    srcs = [...],
)
```

Declares seed data to be loaded into the test database after schema migrations
have been applied. Accepts `.sql` files (executed via `psql`) and `.csv` files
(loaded via `COPY ... CSV HEADER`). For `.csv` files the table name is inferred
from the filename: `users.csv` → `COPY users FROM ... CSV HEADER`.

**Attributes:**

| Attribute | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Target name. |
| `schema` | `label` | required | The `postgres_schema` target whose migrations run before seeding. |
| `srcs` | `label_list` | required | `.sql` or `.csv` seed files, applied in listed order. |

**Example:**

```python
pg_seed_data(
    name = "test_fixtures",
    schema = ":schema",
    srcs = [
        "fixtures/users.sql",
        "fixtures/products.csv",   # table name inferred as "products"
        "fixtures/orders.sql",
    ],
)
```

---

### `pg_test`

```python
load("@rules_pg//:defs.bzl", "pg_test")

pg_test(
    name = "...",
    schema = ":schema",
    srcs = [...],
    deps = [...],
    seed = None,
    postgres_version = "14",
    database = "test",
    pg_user = "postgres",
    pg_password = "postgres",
    size = "medium",
    timeout = None,
    tags = [],
    test_rule = None,
    **kwargs,
)
```

Wraps any `*_test` rule with an ephemeral PostgreSQL cluster. The launcher:

1. Runs `initdb` in `$TEST_TMPDIR/pgdata`
2. Binds a free TCP port and starts the server (using `--socket-fd` on PG ≥ 14
   to eliminate port-allocation races)
3. Polls `pg_isready` until the server accepts connections
4. Creates the test database
5. Applies schema migrations in order
6. Applies seed data (if provided)
7. Injects `PG*` environment variables and `exec`s the test binary
8. Stops the cluster on exit via an `atexit` handler

`pg_test` is a macro. It generates two targets: `<name>_inner` (the raw test
binary, tagged `manual`) and `<name>` (the launcher wrapper that you actually
run).

**Attributes:**

| Attribute | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Target name. |
| `schema` | `label` | required | `postgres_schema` target to apply before the test. |
| `srcs` | `label_list` | `[]` | Test source files, forwarded to `test_rule`. |
| `deps` | `label_list` | `[]` | Test dependencies, forwarded to `test_rule`. |
| `seed` | `label` | `None` | Optional `pg_seed_data` target loaded after migrations. |
| `postgres_version` | `string` | `"14"` | PostgreSQL major version: `"14"`, `"15"`, or `"16"`. |
| `database` | `string` | `"test"` | Name of the database created for the test. |
| `pg_user` | `string` | `"postgres"` | Database superuser name. |
| `pg_password` | `string` | `"postgres"` | Database superuser password. |
| `size` | `string` | `"medium"` | Bazel test size. |
| `timeout` | `string` | `None` | Bazel test timeout override. |
| `tags` | `string_list` | `[]` | Additional Bazel tags. |
| `test_rule` | `rule` | `native.sh_test` | The `*_test` rule used for the inner binary. Pass `go_test`, `py_test`, `cc_test`, etc. |
| `**kwargs` | | | All remaining attributes are forwarded to `test_rule`. |

**Minimal example:**

```python
pg_test(
    name = "smoke_test",
    srcs = ["smoke_test.sh"],
    schema = ":schema",
)
```

**Full example:**

```python
pg_test(
    name = "integration_test",
    srcs = ["integration_test.sh"],
    schema = ":schema",
    seed = ":test_fixtures",
    postgres_version = "16",
    database = "myapp_test",
    pg_user = "myapp",
    pg_password = "s3cr3t",
    size = "large",
    timeout = "120s",
    tags = ["pg", "integration"],
)
```

---

### `pg_server`

```python
load("@rules_pg//:defs.bzl", "pg_server")

pg_server(
    name = "...",
    schema = ":schema",
    seed = None,
    postgres_version = "14",
    database = "test",
    pg_user = "postgres",
    pg_password = "postgres",
)
```

Produces a long-running executable that starts an ephemeral PostgreSQL cluster,
waits until it is fully initialized (schema and seed applied), and then blocks
until it receives `SIGTERM` or `SIGINT`. Designed for use with
[`rules_itest`](https://github.com/dzbarsky/rules_itest) or any other service
manager that runs services alongside integration tests.

**Readiness protocol.** After the cluster is ready, `pg_server` writes
`$TEST_TMPDIR/<name>.env` containing the `PGHOST`, `PGPORT`, `PGDATABASE`,
`PGUSER`, and `PGPASSWORD` variables. The file is written atomically (via a
`.tmp` rename) so readers never observe a partial write. Its mere existence
signals that the cluster is fully up and ready to accept connections.

**Shutdown.** `SIGTERM` (sent by `rules_itest` after the test) and `SIGINT`
(for interactive `bazel run` sessions) both call `pg_ctl stop -m fast` then
exit 0.

**Attributes:** same as `pg_test` except `srcs`, `deps`, `size`, `timeout`,
`tags`, and `test_rule` are absent (it is not a test target).

| Attribute | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Target name. Also used as the env file stem: `$TEST_TMPDIR/<name>.env`. |
| `schema` | `label` | required | `postgres_schema` target to apply on startup. |
| `seed` | `label` | `None` | Optional `pg_seed_data` target loaded after migrations. |
| `postgres_version` | `string` | `"14"` | PostgreSQL major version. |
| `database` | `string` | `"test"` | Name of the database to create. |
| `pg_user` | `string` | `"postgres"` | Database superuser name. |
| `pg_password` | `string` | `"postgres"` | Database superuser password. |

---

### `pg_health_check`

```python
load("@rules_pg//:defs.bzl", "pg_health_check")

pg_health_check(
    name = "...",
    server = ":my_server",
)
```

Generates a companion health-check binary for a `pg_server` target. When
invoked it exits `0` if and only if `$TEST_TMPDIR/<server-name>.env` exists,
and exits non-zero otherwise. This matches the contract expected by
`rules_itest`'s `health_check` attribute.

**Attributes:**

| Attribute | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Target name. |
| `server` | `label` | required | The `pg_server` target this check monitors. |

---

### `postgres_binary`

```python
load("@rules_pg//:defs.bzl", "postgres_binary")

postgres_binary(
    name = "...",
    binary = select({...}),
    version = "14",
)
```

Selects the correct pre-built PostgreSQL binary for the current platform and
wraps it in a `PostgresBinaryInfo` provider. You typically do not use this rule
directly — `postgres_schema` and `pg_test` resolve the binary automatically via
`//:pg_default`. Use this rule only when you need to pin a specific version in a
`postgres_schema` or when writing custom rules that consume `PostgresBinaryInfo`.

**Attributes:**

| Attribute | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Target name. |
| `binary` | `label` | required | A `select()` expression resolving to the platform-appropriate binary repo. |
| `version` | `string` | `"14"` | PostgreSQL major version string. Must match the version in the referenced binary repo. |

The root `BUILD.bazel` of this repository pre-declares `pg_14`, `pg_15`, and
`pg_16` targets using the correct `select()` expressions. Reference them
directly rather than writing your own:

```python
postgres_schema(
    name = "schema_pg16",
    srcs = glob(["migrations/*.sql"]),
    binary = "@rules_pg//:pg_16",
)
```

---

## `rules_itest` integration

[`rules_itest`](https://github.com/dzbarsky/rules_itest) is a Bazel extension
for integration tests that models the test run as: start services in dependency
order → run test → stop services. `pg_server` and `pg_health_check` map
directly onto this model.

### Installation

Add `rules_itest` to your `MODULE.bazel`:

```python
bazel_dep(name = "rules_itest", version = "0.0.21")
```

### Example

The following example starts a PostgreSQL service, waits until it is healthy,
then runs an integration test that connects to it.

**`BUILD.bazel`:**

```python
load("@rules_pg//:defs.bzl", "pg_health_check", "pg_server", "postgres_schema", "pg_seed_data")
load("@rules_itest//:itest.bzl", "itest_service", "service_test")

postgres_schema(
    name = "schema",
    srcs = glob(["migrations/*.sql"]),
)

pg_seed_data(
    name = "fixtures",
    schema = ":schema",
    srcs = ["fixtures/users.sql"],
)

# Long-running service: starts pg, writes $TEST_TMPDIR/db.env when ready.
pg_server(
    name = "db",
    schema = ":schema",
    seed = ":fixtures",
)

# Health probe: exits 0 once $TEST_TMPDIR/db.env exists.
pg_health_check(
    name = "db_health",
    server = ":db",
)

# rules_itest service wrapper with health check.
itest_service(
    name = "db_svc",
    exe = ":db",
    health_check = ":db_health",
)

# Integration test that runs after db_svc is healthy.
service_test(
    name = "integration_test",
    services = [":db_svc"],
    test = ":integration_test_bin",
)

sh_test(
    name = "integration_test_bin",
    srcs = ["integration_test.sh"],
    tags = ["manual"],
)
```

**`integration_test.sh`:**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Source the connection details written by pg_server.
# shellcheck disable=SC1090
source "$TEST_TMPDIR/db.env"

# The standard PG* variables are now set; connect with any client.
PGPASSWORD="$PGPASSWORD" psql \
    -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
    --no-password -v ON_ERROR_STOP=1 \
    -c "SELECT COUNT(*) FROM users;"

echo "PASS"
```

Run with:

```
bazel test //:integration_test
```

`rules_itest` starts `db_svc`, polls `db_health` until it returns 0, runs
`integration_test_bin`, then sends `SIGTERM` to `db_svc`. `pg_server` handles
`SIGTERM` by calling `pg_ctl stop -m fast` and exiting 0.

### Connection details

The `$TEST_TMPDIR/<server-name>.env` file contains standard `libpq` variables:

```
PGHOST=127.0.0.1
PGPORT=54321
PGDATABASE=test
PGUSER=postgres
PGPASSWORD=postgres
```

Any client that respects `libpq` environment variables — `psql`, `pgx`,
`psycopg2`, `database/sql` with a `pgx` driver — connects without any
additional configuration after sourcing this file.

---

## Providers

These providers are exported from `defs.bzl` for use in downstream rules.

### `PostgresBinaryInfo`

| Field | Type | Description |
|---|---|---|
| `pgctl` | `File` | `pg_ctl` binary |
| `initdb` | `File` | `initdb` binary |
| `psql` | `File` | `psql` binary |
| `pg_isready` | `File` | `pg_isready` binary |
| `pg_dump` | `File` | `pg_dump` binary |
| `version` | `string` | Major version, e.g. `"16"` |
| `lib_dir` | `File` | `lib/` directory (shared libraries, Linux) |
| `all_files` | `depset` | All files required at runtime |

### `PostgresSchemaInfo`

| Field | Type | Description |
|---|---|---|
| `migrations` | `depset` | SQL files in application order |
| `binary` | `PostgresBinaryInfo` | Server binaries to use |

### `PostgresSeedInfo`

| Field | Type | Description |
|---|---|---|
| `seed_files` | `depset` | `.sql` or `.csv` files applied after migrations |
| `schema` | `PostgresSchemaInfo` | The schema that must exist before seeding |

---

## Environment variables injected by `pg_test`

The launcher sets these variables in the test process environment:

| Variable | Example | Description |
|---|---|---|
| `PGHOST` | `127.0.0.1` | Hostname of the ephemeral server |
| `PGPORT` | `54321` | TCP port of the ephemeral server |
| `PGDATABASE` | `test` | Name of the created database |
| `PGUSER` | `postgres` | Database superuser |
| `PGPASSWORD` | `postgres` | Database superuser password |

These are the standard `libpq` environment variables, so any client that
respects them — `psql`, `pgx`, `psycopg2`, `libpq`, `database/sql` with a
`pgx` or `pq` driver — will connect without any additional configuration.

---

## Migration file ordering

SQL files in `postgres_schema.srcs` are applied in the exact order listed. Two
patterns are common:

**Explicit list** — clearest, immune to filesystem ordering differences:

```python
postgres_schema(
    name = "schema",
    srcs = [
        "migrations/001_create_tables.sql",
        "migrations/002_add_indexes.sql",
        "migrations/003_add_constraints.sql",
    ],
)
```

**`glob()` with numeric prefixes** — convenient for large migration sets, but
requires that filenames sort into the correct order alphabetically:

```python
postgres_schema(
    name = "schema",
    srcs = glob(["migrations/*.sql"]),
)
```

Recommended prefix format: `NNN_description.sql` where `NNN` is zero-padded to
the same width across all files (`001`, `002`, …, `099`, `100`). Mixing widths
(`1_init.sql`, `10_add_index.sql`) will cause `glob()` to return files in an
incorrect order.

There is no automatic dependency solver. If migration B depends on migration A,
A must appear before B in `srcs`.

---

## Seed data

`pg_seed_data` loads test fixture data after all migrations have been applied.

**SQL files** are executed via `psql -f`. Any valid SQL is accepted:

```sql
-- fixtures/users.sql
INSERT INTO users (email, name) VALUES
    ('alice@example.com', 'Alice'),
    ('bob@example.com',   'Bob');
```

**CSV files** are loaded via `\copy ... CSV HEADER`. The table name is taken
from the filename (without extension):

```
fixtures/
  products.csv    →  COPY products FROM '.../products.csv' CSV HEADER
  order_lines.csv →  COPY order_lines FROM '.../order_lines.csv' CSV HEADER
```

The CSV must have a header row whose column names exactly match the target
table's column names. Columns not present in the CSV retain their default
values.

Seed files are applied in the order they appear in `srcs`. If a seed SQL file
references data loaded by an earlier seed file (e.g. foreign keys), list the
dependency first.

---

## Using `pg_test` with Go, Python, or C++

Pass the language-specific test rule via `test_rule`. All remaining attributes
are forwarded to that rule.

**Go** (using `rules_go`):

```python
load("@rules_go//go:def.bzl", "go_test")
load("@rules_pg//:defs.bzl", "pg_test", "postgres_schema")

postgres_schema(
    name = "schema",
    srcs = glob(["migrations/*.sql"]),
)

pg_test(
    name = "repo_test",
    schema = ":schema",
    test_rule = go_test,
    srcs = ["repo_test.go"],
    deps = [
        "//internal/repo",
        "@com_github_jackc_pgx_v5//:pgx",
    ],
    importpath = "github.com/example/myapp/internal/repo_test",
)
```

In `repo_test.go`, read the connection string from the environment:

```go
func TestMain(m *testing.M) {
    dsn := fmt.Sprintf("host=%s port=%s dbname=%s user=%s password=%s sslmode=disable",
        os.Getenv("PGHOST"),
        os.Getenv("PGPORT"),
        os.Getenv("PGDATABASE"),
        os.Getenv("PGUSER"),
        os.Getenv("PGPASSWORD"),
    )
    // open pool, run migrations if needed, etc.
    os.Exit(m.Run())
}
```

**Python** (using `rules_python`):

```python
load("@rules_python//python:defs.bzl", "py_test")
load("@rules_pg//:defs.bzl", "pg_test", "postgres_schema")

postgres_schema(
    name = "schema",
    srcs = glob(["migrations/*.sql"]),
)

pg_test(
    name = "models_test",
    schema = ":schema",
    test_rule = py_test,
    srcs = ["models_test.py"],
    deps = [
        "//myapp:models",
        requirement("psycopg2-binary"),
    ],
    main = "models_test.py",
)
```

In `models_test.py`:

```python
import os, psycopg2, unittest

def get_conn():
    return psycopg2.connect(
        host=os.environ["PGHOST"],
        port=os.environ["PGPORT"],
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
    )
```

**C++** (using `cc_test`):

```python
load("@rules_pg//:defs.bzl", "pg_test", "postgres_schema")

postgres_schema(
    name = "schema",
    srcs = glob(["migrations/*.sql"]),
)

pg_test(
    name = "dao_test",
    schema = ":schema",
    test_rule = native.cc_test,
    srcs = ["dao_test.cc"],
    deps = [
        "//myapp:dao",
        "@libpqxx//:pqxx",
        "@googletest//:gtest_main",
    ],
)
```

---

## Selecting a PostgreSQL version

The `postgres_version` attribute on `pg_test` controls which pre-built binary
is used. The version must have been declared in your `MODULE.bazel` (or fetched
by `rules_pg_dependencies` in WORKSPACE).

```python
# Default: PostgreSQL 14
pg_test(
    name = "test_pg14",
    schema = ":schema",
    srcs = ["my_test.sh"],
)

# Pin to PostgreSQL 16
pg_test(
    name = "test_pg16",
    schema = ":schema",
    srcs = ["my_test.sh"],
    postgres_version = "16",
)
```

To test the same code against multiple versions, define one `pg_test` target
per version and group them in a `test_suite`:

```python
[
    pg_test(
        name = "compat_test_pg" + version,
        schema = ":schema",
        srcs = ["compat_test.sh"],
        postgres_version = version,
        tags = ["pg_compat"],
    )
    for version in ["14", "15", "16"]
]

test_suite(
    name = "pg_compat_suite",
    tags = ["pg_compat"],
)
```

```
bazel test //:pg_compat_suite
```

---

## Parallelism and isolation

Every `pg_test` invocation is fully isolated:

- **Separate data directory.** `initdb` writes to `$TEST_TMPDIR/pgdata`, which
  Bazel makes unique per test target invocation. Two simultaneous tests never
  share a data directory.
- **Random port.** The launcher uses `socket.bind(('', 0))` to obtain a free
  port from the OS. On PostgreSQL ≥ 14 the bound socket fd is passed directly
  to `pg_ctl` via `--socket-fd`, so the OS never releases the port before
  Postgres claims it. On PostgreSQL < 14 the launcher falls back to a
  close-then-retry strategy with up to five attempts.
- **No shared state.** There is no shared Postgres instance, no shared socket
  file, and no shared `PGDATA`. Tests do not interfere with each other
  regardless of how many run concurrently.

By default, Bazel runs as many tests in parallel as `--jobs` allows. No
special tags or `shard_count` settings are needed for `pg_test` to run safely
in parallel.

The practical concurrency ceiling is memory: each idle cluster uses roughly
5–15 MB of shared memory. On a standard CI machine with 8 GB RAM, running 100
concurrent `pg_test` targets is well within budget.

---

## Toolchain integration

For advanced use cases where you need the PostgreSQL binaries in a custom rule,
`rules_pg` exposes a Bazel toolchain type at `//toolchain:postgres`.

**Declare a toolchain target** (this is already done for you in the pre-built
binary repos):

```python
load("@rules_pg//toolchain:toolchain.bzl", "pg_toolchain")

pg_toolchain(
    name = "my_pg_toolchain",
    binary = "@rules_pg//:pg_16",
)

toolchain(
    name = "my_pg_toolchain_registered",
    toolchain_type = "@rules_pg//toolchain:postgres",
    toolchain = ":my_pg_toolchain",
    target_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
)
```

**Use the toolchain in a custom rule:**

```python
load("@rules_pg//toolchain:toolchain.bzl", "POSTGRES_TOOLCHAIN_TYPE")

def _my_rule_impl(ctx):
    pg = ctx.toolchains[str(POSTGRES_TOOLCHAIN_TYPE)].pg
    # pg is a PostgresBinaryInfo
    ...

my_rule = rule(
    implementation = _my_rule_impl,
    toolchains = [str(POSTGRES_TOOLCHAIN_TYPE)],
)
```

**Register via `MODULE.bazel`:**

```python
register_toolchains("//my_toolchains:my_pg_toolchain_registered")
```

---

## FAQ

**Q: Can I run `pg_test` targets on CI without a system Postgres installation?**

Yes. All required binaries — `pg_ctl`, `initdb`, `psql`, `pg_isready` — are
downloaded as part of the Bazel fetch phase and are available as runfiles.
Nothing from the host system's `PATH` is used.

---

**Q: My test takes longer than expected. Where is the time going?**

The dominant cost is `initdb`, which typically takes 0.3–1 s depending on the
host. This is a fixed per-test overhead. If you have many fast tests that share
an identical schema, consider grouping them under a single `pg_test` target
(one cluster, multiple test functions) rather than one target per test.

---

**Q: Can I use `pg_test` with `bazel coverage`?**

The inner test binary (the `<name>_inner` target) participates in coverage
collection normally, since it is a regular `*_test` target wrapped by
`pg_test`. Coverage instrumentation is applied by the underlying `test_rule`
(e.g. `go_test`, `py_test`). The `pg_test` launcher itself is not instrumented.

---

**Q: How do I pass extra `psql` flags or run arbitrary setup SQL?**

Put the setup in a migration file. `postgres_schema.srcs` accepts any valid
SQL, including `SET` commands, extension installation (`CREATE EXTENSION
"uuid-ossp"`), and role creation. If the setup is test-specific rather than
schema-wide, put it in a `pg_seed_data` target.

---

**Q: Can I share a `postgres_schema` target between multiple `pg_test` targets?**

Yes, and this is the recommended pattern. Define the schema once and reference
it from as many `pg_test` targets as needed. Each test still gets its own
cluster; the schema target is just a declarative description of which files to
apply.

```python
postgres_schema(
    name = "schema",
    srcs = glob(["migrations/*.sql"]),
    visibility = ["//..."],
)
```

---

**Q: Windows support?**

Not currently. Pre-built binary tarballs are only fetched for Linux and macOS.
Contributions adding Windows support are welcome; the launcher script would
need to be ported to a `.bat` or Python-only implementation.

---

**Q: How do I update checksums when a new PostgreSQL patch release is published?**

Run the helper script:

```
bash tools/update_checksums.sh 16
```

It downloads each platform's tarball, prints the `sha256` values, and you
paste them into the `_PG_VERSIONS` dict in both `extensions.bzl` and
`repositories.bzl`.

---

## Maintainers

Contributions via pull request are welcome. Please include a test in
`tests/BUILD.bazel` for any new feature or bug fix.
