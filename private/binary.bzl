"postgres_binary rule and PostgresBinaryInfo provider."

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

PostgresBinaryInfo = provider(
    doc = "Carries the paths to PostgreSQL server binaries.",
    fields = {
        "pgctl":      "File: pg_ctl binary",
        "initdb":     "File: initdb binary",
        "psql":       "File: psql binary",
        "pg_isready": "File: pg_isready binary",
        "pg_dump":    "File: pg_dump binary",
        "version":    "string: major version, e.g. '16'",
        "lib_dir":    "File: lib/ directory (needed for shared libraries on Linux)",
        "all_files":  "depset: every bin/ file and the libraries (a test's " +
                      "PG_BIN is the runfiles bin/ directory, so all clients are there)",
    },
)

# ---------------------------------------------------------------------------
# Helper called from the downloaded binary repo's BUILD
# ---------------------------------------------------------------------------

def _postgres_binary_files_impl(ctx):
    # The downloaded archive is already extracted into the repo.  We just
    # collect the files and forward them via the provider.
    bins = {f.basename: f for f in ctx.files.bins}

    def _require(name):
        if name not in bins:
            fail("Expected binary '{}' not found in downloaded PostgreSQL archive. " +
                 "Contents: {}".format(name, bins.keys()))
        return bins[name]

    pg_ctl      = _require("pg_ctl")
    initdb      = _require("initdb")
    psql        = _require("psql")
    pg_isready  = _require("pg_isready")
    pg_dump     = _require("pg_dump")

    # Every bin/ file, not just the five above: a pg_test's PATH starts
    # with this bin/ directory in its runfiles (rules_pg#7).
    lib_files = ctx.files.libs
    all_files = depset(ctx.files.bins + lib_files)

    return [
        DefaultInfo(files = all_files),
        PostgresBinaryInfo(
            pgctl      = pg_ctl,
            initdb     = initdb,
            psql       = psql,
            pg_isready = pg_isready,
            pg_dump    = pg_dump,
            version    = ctx.attr.version,
            lib_dir    = ctx.files.libs[0] if lib_files else None,
            all_files  = all_files,
        ),
    ]

postgres_binary_files = rule(
    implementation = _postgres_binary_files_impl,
    doc = "Injected into each downloaded binary repo. Wraps extracted files into a provider.",
    attrs = {
        "version": attr.string(mandatory = True, doc = "PostgreSQL major version string"),
        "bins": attr.label_list(
            default = [":all_bin_files"],
            allow_files = True,
            doc = "The bin/ filegroup from the downloaded archive",
        ),
        "libs": attr.label_list(
            default = [":all_lib_files"],
            allow_files = True,
            doc = "The lib/ filegroup from the downloaded archive",
        ),
    },
)

# ---------------------------------------------------------------------------
# postgres_binary — user-facing rule that selects the right repo
# ---------------------------------------------------------------------------

def _postgres_binary_impl(ctx):
    # Forward the provider from whichever platform repo was selected.
    bin_info = ctx.attr.binary[PostgresBinaryInfo]
    return [
        DefaultInfo(files = bin_info.all_files),
        bin_info,
    ]

postgres_binary = rule(
    implementation = _postgres_binary_impl,
    doc = """\
Selects the correct pre-built PostgreSQL binary for the current platform.

Typically you do not use this rule directly; it is consumed by postgres_schema
and pg_test.  If you need the binaries for a custom rule, depend on a target
produced by this rule and access PostgresBinaryInfo.
""",
    attrs = {
        "binary": attr.label(
            mandatory = True,
            providers = [PostgresBinaryInfo],
            doc = "The platform-specific binary target (set via select() in defs.bzl)",
        ),
        "version": attr.string(
            default = "14",
            doc = "PostgreSQL major version. Must match the version in the binary repo.",
        ),
    },
)
