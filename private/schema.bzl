"postgres_schema rule and PostgresSchemaInfo provider."

load("//private:binary.bzl", "PostgresBinaryInfo")

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

PostgresSchemaInfo = provider(
    doc = """\
Carries an ordered set of SQL migration files and a reference to the
PostgresBinaryInfo needed to apply them.
""",
    fields = {
        "migrations": "depset: SQL files in application order (leaves-first = correct order)",
        "binary":     "PostgresBinaryInfo: the server binaries to use",
    },
)

# ---------------------------------------------------------------------------
# Rule
# ---------------------------------------------------------------------------

def _postgres_schema_impl(ctx):
    binary_info = ctx.attr.binary[PostgresBinaryInfo]

    # ctx.files.srcs already respects label-list ordering.  We wrap in a
    # depset with order="preorder" so downstream depset().to_list() preserves
    # the user-declared order.
    migrations = depset(
        ctx.files.srcs,
        order = "preorder",
    )

    return [
        DefaultInfo(files = migrations),
        PostgresSchemaInfo(
            migrations = migrations,
            binary     = binary_info,
        ),
    ]

postgres_schema = rule(
    implementation = _postgres_schema_impl,
    doc = """\
Declares an ordered set of SQL migration files that define a database schema.

Files are applied to the test database in the order they appear in `srcs`.
Use numeric prefixes to make ordering explicit and stable with glob():

    postgres_schema(
        name = "schema",
        srcs = glob(["migrations/*.sql"]),  # 001_init.sql, 002_users.sql …
    )

The `binary` attribute is usually left at its default, which resolves to the
platform-appropriate Postgres installation registered by the module extension.
""",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".sql"],
            doc = "SQL migration files in application order. May be empty " +
                  "(a database with no migrations, e.g. one the code under " +
                  "test migrates itself).",
        ),
        "binary": attr.label(
            default = Label("//:pg_default"),
            providers = [PostgresBinaryInfo],
            doc = "postgres_binary target to use when applying migrations.",
        ),
    },
)
