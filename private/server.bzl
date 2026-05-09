"pg_server rule and pg_health_check rule."

load("//private:schema.bzl", "PostgresSchemaInfo")
load("//private:seed.bzl", "PostgresSeedInfo")

# ---------------------------------------------------------------------------
# pg_server rule
# ---------------------------------------------------------------------------

def _pg_server_impl(ctx):
    schema_info = ctx.attr.schema[PostgresSchemaInfo]
    binary_info = schema_info.binary

    pg_runfiles     = binary_info.all_files
    migration_files = schema_info.migrations
    seed_files      = depset()
    if ctx.attr.seed:
        seed_info  = ctx.attr.seed[PostgresSeedInfo]
        seed_files = seed_info.seed_files

    manifest_content = struct(
        workspace   = ctx.workspace_name,
        pgctl       = binary_info.pgctl.short_path,
        initdb      = binary_info.initdb.short_path,
        psql        = binary_info.psql.short_path,
        pg_isready  = binary_info.pg_isready.short_path,
        pg_version  = binary_info.version,
        migrations  = [f.short_path for f in migration_files.to_list()],
        seed_files  = [f.short_path for f in seed_files.to_list()],
        database    = ctx.attr.database,
        pg_user     = ctx.attr.pg_user,
        pg_password = ctx.attr.pg_password,
    )
    manifest = ctx.actions.declare_file(ctx.label.name + "_pg_manifest.json")
    ctx.actions.write(
        output  = manifest,
        content = json.encode(manifest_content),
    )

    launcher_src  = ctx.file.launcher
    # Env file name: $TEST_TMPDIR/<target-name>.env
    # pg_health_check derives the same name from the server label, so this
    # string must stay in sync with _pg_health_check_impl below.
    env_file_name = ctx.label.name + ".env"

    wrapper = ctx.actions.declare_file(ctx.label.name + "_pg_server.sh")
    ctx.actions.write(
        output    = wrapper,
        content   = """\
#!/usr/bin/env bash
set -euo pipefail
# TEST_SRCDIR is set by Bazel for test targets and inherited by subprocesses
# (e.g. rules_itest services).  RUNFILES_DIR is set for `bazel run`.
RUNFILES_ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$RUNFILES_ROOT" ]]; then
  echo "[rules_pg] Neither TEST_SRCDIR nor RUNFILES_DIR is set" >&2
  exit 1
fi
export RULES_PG_MANIFEST="$RUNFILES_ROOT/{workspace}/{manifest}"
export RULES_PG_MODE=server
export RULES_PG_OUTPUT_ENV_FILE="${{TEST_TMPDIR:-/tmp}}/{env_file_name}"
exec "$RUNFILES_ROOT/{workspace}/{launcher}" "$@"
""".format(
            workspace     = ctx.workspace_name,
            manifest      = manifest.short_path,
            launcher      = launcher_src.short_path,
            env_file_name = env_file_name,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files            = [manifest, launcher_src, wrapper],
        transitive_files = depset(transitive = [pg_runfiles, migration_files, seed_files]),
    )

    return [
        DefaultInfo(
            executable = wrapper,
            runfiles   = runfiles,
        ),
    ]

pg_server = rule(
    implementation = _pg_server_impl,
    executable     = True,
    doc            = """\
Produces a long-running PostgreSQL server binary.

When executed, pg_server:
  1. Runs initdb, starts an ephemeral cluster, applies schema migrations, and
     loads seed data.
  2. Writes PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD to
     $TEST_TMPDIR/<name>.env once the cluster is fully ready.
  3. Blocks until SIGTERM or SIGINT, then stops the cluster cleanly.

The env file is written only after all setup steps complete, so its presence
is a reliable readiness signal.  Use pg_health_check to expose that signal to
rules_itest's service manager.

Typical use (rules_itest):

    pg_server(
        name   = "db",
        schema = ":schema",
        seed   = ":seed",
    )

    pg_health_check(
        name   = "db_health",
        server = ":db",
    )

    itest_service(
        name         = "db_svc",
        exe          = ":db",
        health_check = ":db_health",
    )

The wrapped test reads connection details from $TEST_TMPDIR/db.env:

    source "$TEST_TMPDIR/db.env"
""",
    attrs = {
        "schema": attr.label(
            mandatory = True,
            providers = [PostgresSchemaInfo],
            doc       = "postgres_schema target to apply before serving.",
        ),
        "seed": attr.label(
            mandatory = False,
            providers = [PostgresSeedInfo],
            doc       = "Optional pg_seed_data target to load after migrations.",
        ),
        "launcher": attr.label(
            default          = Label("//private:launcher.py"),
            allow_single_file = True,
            executable       = False,
            doc              = "Internal: the launcher.py source file.",
        ),
        "database":    attr.string(default = "test",     doc = "Database name to create."),
        "pg_user":     attr.string(default = "postgres", doc = "Superuser name."),
        "pg_password": attr.string(default = "postgres", doc = "Superuser password."),
    },
)

# ---------------------------------------------------------------------------
# pg_health_check rule
# ---------------------------------------------------------------------------

def _pg_health_check_impl(ctx):
    # Derive the env file name from the companion pg_server's target name.
    # This mirrors the convention in _pg_server_impl: $TEST_TMPDIR/<name>.env.
    server_name   = ctx.attr.server.label.name
    env_file_name = server_name + ".env"

    script = ctx.actions.declare_file(ctx.label.name + "_health_check.sh")
    ctx.actions.write(
        output  = script,
        content = """\
#!/usr/bin/env bash
set -euo pipefail
env_file="${{TEST_TMPDIR}}/{env_file}"
if [[ -f "$env_file" ]]; then
  exit 0
fi
echo "[rules_pg] pg_server env file not yet present: $env_file" >&2
exit 1
""".format(env_file = env_file_name),
        is_executable = True,
    )
    return [DefaultInfo(executable = script, runfiles = ctx.runfiles(files = [script]))]

pg_health_check = rule(
    implementation = _pg_health_check_impl,
    executable     = True,
    doc            = """\
Generates a health-check binary for a pg_server target.

Exits 0 when the server's env file ($TEST_TMPDIR/<server-name>.env) exists,
which pg_server writes only after PostgreSQL is fully up and all migrations
and seed data have been applied.

Pass to itest_service's health_check attribute:

    pg_health_check(name = "db_health", server = ":db")

    itest_service(
        name         = "db_svc",
        exe          = ":db",
        health_check = ":db_health",
    )
""",
    attrs = {
        "server": attr.label(
            mandatory = True,
            doc       = "The pg_server target to health-check.",
        ),
    },
)
