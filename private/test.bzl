"pg_test macro: wraps any *_test rule with a hermetic PostgreSQL cluster."

load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("//private:binary.bzl", "PostgresBinaryInfo")
load("//private:schema.bzl", "PostgresSchemaInfo")
load("//private:seed.bzl", "PostgresSeedInfo")

# ---------------------------------------------------------------------------
# Internal rule: builds the launcher + collects runfiles
# ---------------------------------------------------------------------------

def _pg_launcher_impl(ctx):
    schema_info = ctx.attr.schema[PostgresSchemaInfo]
    binary_info = schema_info.binary

    # Collect all files the launcher needs at runtime.
    pg_runfiles = binary_info.all_files

    migration_files = schema_info.migrations
    seed_files = depset()
    if ctx.attr.seed:
        seed_info = ctx.attr.seed[PostgresSeedInfo]
        seed_files = seed_info.seed_files

    # Write a small JSON manifest so the launcher doesn't need to parse argv.
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

    # The launcher script itself is a source file; we just make it available.
    launcher_src = ctx.file.launcher

    # Produce a wrapper script that sets RULES_PG_MANIFEST and execs the
    # real launcher, which in turn execs the test binary.
    wrapper = ctx.actions.declare_file(ctx.label.name + "_pg_wrapper.sh")
    ctx.actions.write(
        output    = wrapper,
        content   = """\
#!/usr/bin/env bash
set -euo pipefail
# Bazel sets TEST_SRCDIR to the runfiles root for all test targets.
# Do not use $0.runfiles — in sandboxed execution $0 resolves to the
# symlink inside the runfiles tree, which would double-nest the path.
RUNFILES_ROOT="${{TEST_SRCDIR:-${{RUNFILES_DIR:-}}}}"
if [[ -z "$RUNFILES_ROOT" ]]; then
  echo "[rules_pg] Neither TEST_SRCDIR nor RUNFILES_DIR is set" >&2
  exit 1
fi
export RULES_PG_MANIFEST="$RUNFILES_ROOT/{workspace}/{manifest}"
export RULES_PG_TEST_BINARY="$RUNFILES_ROOT/{workspace}/{test_bin}"
exec "$RUNFILES_ROOT/{workspace}/{launcher}" "$@"
""".format(
            workspace = ctx.workspace_name,
            manifest  = manifest.short_path,
            launcher  = launcher_src.short_path,
            test_bin  = ctx.attr.test_binary.files_to_run.executable.short_path,
        ),
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [manifest, launcher_src, wrapper],
        transitive_files = depset(transitive = [pg_runfiles, migration_files, seed_files]),
    ).merge(ctx.attr.test_binary.default_runfiles)

    return [
        DefaultInfo(
            executable = wrapper,
            runfiles   = runfiles,
        ),
    ]

_pg_launcher_test = rule(
    implementation = _pg_launcher_impl,
    test = True,
    doc = "Internal rule. Use the pg_test macro instead.",
    attrs = {
        "schema": attr.label(
            mandatory = True,
            providers = [PostgresSchemaInfo],
        ),
        "seed": attr.label(
            mandatory = False,
            providers = [PostgresSeedInfo],
        ),
        "test_binary": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
        ),
        "launcher": attr.label(
            default = Label("//private:launcher.py"),
            allow_single_file = True,
            executable = False,
        ),
        "database":    attr.string(default = "test"),
        "pg_user":     attr.string(default = "postgres"),
        "pg_password": attr.string(default = "postgres"),
    },
)

# ---------------------------------------------------------------------------
# pg_test macro
# ---------------------------------------------------------------------------

def pg_test(
        name,
        schema,
        srcs = None,
        deps = None,
        seed = None,
        postgres_version = "16",
        database = "test",
        pg_user = "postgres",
        pg_password = "postgres",
        size = "medium",
        timeout = None,
        tags = None,
        test_rule = None,
        **kwargs):
    """Macro: runs a test with an ephemeral PostgreSQL cluster.

    Wraps any *_test rule (default: sh_test; pass test_rule= for others) with
    a launcher that:
      1. initdb's a fresh cluster in $TEST_TMPDIR
      2. Starts postgres on a random free port
      3. Applies schema migrations in order
      4. Optionally loads seed data
      5. Exports PGHOST / PGPORT / PGDATABASE / PGUSER / PGPASSWORD
      6. exec's the wrapped test binary
      7. Tears down the cluster on exit

    Args:
        name:             Target name.
        schema:           Label of a postgres_schema target (required).
        srcs:             Test source files (forwarded to test_rule).
        deps:             Test dependencies (forwarded to test_rule).
        seed:             Optional label of a pg_seed_data target.
        postgres_version: "14", "15", or "16". Default "16".
        database:         Database name created for the test. Default "test".
        pg_user:          Superuser name. Default "postgres".
        pg_password:      Superuser password. Default "postgres".
        size:             Bazel test size. Default "medium".
        timeout:          Bazel test timeout override.
        tags:             Extra tags. "requires-network" is NOT added automatically.
        test_rule:        The *_test rule to use for the inner test binary.
                          Defaults to native.sh_test.  Pass e.g. go_test,
                          py_test, cc_test, etc.
        **kwargs:         Remaining kwargs forwarded to test_rule.
    """

    srcs  = srcs  or []
    deps  = deps  or []
    tags  = tags  or []
    # Bazel 8+ removed `native.sh_test`, so the default has to load
    # from rules_shell. Consumers can override `test_rule = ...` to
    # point at another *_test rule (py_test, go_test, etc.) if they
    # don't want rules_shell as a transitive dep.
    _test_rule = test_rule or sh_test

    # 1. Build the inner test binary (no pg awareness).
    inner_name = name + "_inner"
    _test_rule(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        tags = tags + ["manual"],  # not run directly
        **kwargs
    )

    # 2. Wrap it with the pg launcher.
    _pg_launcher_test(
        name    = name,
        schema  = schema,
        seed    = seed,
        test_binary = ":" + inner_name,
        database    = database,
        pg_user     = pg_user,
        pg_password = pg_password,
        size    = size,
        timeout = timeout,
        tags    = tags,
    )
