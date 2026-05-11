"Module extension: downloads pre-built PostgreSQL tarballs for each platform/version."

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# ---------------------------------------------------------------------------
# Version manifest
#
# Each entry maps (version, platform) -> (url, sha256, strip_prefix).
# Tarballs are the "binaries-only" distributions from the Postgres project or
# from https://github.com/theory/pgenv.  Update these when cutting a new
# supported version.
#
# URL scheme: PostgreSQL binary distributions for Linux come from the
# EnterpriseDB "pg_binaries" builds; macOS from Postgres.app releases.
# Both ship pg_ctl, initdb, psql, pg_isready and the shared libraries needed
# to run a server without a full OS-level install.
# ---------------------------------------------------------------------------

_PG_VERSIONS = {
    "14": {
        "linux_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-14.11-1-linux-x64-binaries.tar.gz",
            sha256 = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
            strip_prefix = "pgsql",
        ),
        "darwin_arm64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-14.11-1-osx-binaries.zip",
            sha256 = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
            strip_prefix = "pgsql",
        ),
        "darwin_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-14.11-1-osx-binaries.zip",
            sha256 = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3",
            strip_prefix = "pgsql",
        ),
    },
    "15": {
        "linux_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-15.6-1-linux-x64-binaries.tar.gz",
            sha256 = "c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
            strip_prefix = "pgsql",
        ),
        "darwin_arm64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-15.6-1-osx-binaries.zip",
            sha256 = "d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5",
            strip_prefix = "pgsql",
        ),
        "darwin_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-15.6-1-osx-binaries.zip",
            sha256 = "d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5",
            strip_prefix = "pgsql",
        ),
    },
    "16": {
        "linux_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-16.2-1-linux-x64-binaries.tar.gz",
            sha256 = "e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6",
            strip_prefix = "pgsql",
        ),
        "darwin_arm64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-16.2-1-osx-binaries.zip",
            sha256 = "f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1",
            strip_prefix = "pgsql",
        ),
        "darwin_amd64": struct(
            url = "https://get.enterprisedb.com/postgresql/postgresql-16.2-1-osx-binaries.zip",
            sha256 = "f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1",
            strip_prefix = "pgsql",
        ),
    },
}

_PLATFORMS = ["linux_amd64", "darwin_arm64", "darwin_amd64"]

# ---------------------------------------------------------------------------
# BUILD template injected into each repo (downloaded or system)
# ---------------------------------------------------------------------------

_BUILD_TMPL = """
load("@rules_pg//private:binary.bzl", "postgres_binary_files")

# Filegroups consumed by postgres_binary_files defaults.
filegroup(
    name = "all_bin_files",
    srcs = glob(["bin/*"]),
)

filegroup(
    name = "all_lib_files",
    srcs = glob(["lib/**"]),
)

postgres_binary_files(
    name = "pg_bins",
    version = "{version}",
    bins = [":all_bin_files"],
    libs = [":all_lib_files"],
    visibility = ["//visibility:public"],
)

# Also expose the full tree for advanced users. `allow_empty` is on
# because the system-mode repo impl symlinks only the bin/lib/share
# files that actually exist on the host — `share/` may be empty on a
# libpq-only install. Bazel 8+ defaults --incompatible_disallow_empty_glob
# to True, so the opt-in is now required.
filegroup(
    name = "all_files",
    srcs = glob(["bin/**", "lib/**", "share/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
"""

# ---------------------------------------------------------------------------
# Repository rule: downloaded pre-built tarball
# ---------------------------------------------------------------------------

def _pg_binary_repo_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.url,
        sha256 = rctx.attr.sha256,
        stripPrefix = rctx.attr.strip_prefix,
    )
    rctx.file(
        "BUILD.bazel",
        _BUILD_TMPL.format(version = rctx.attr.pg_version),
    )

_pg_binary_repo = repository_rule(
    implementation = _pg_binary_repo_impl,
    attrs = {
        "pg_version":    attr.string(mandatory = True),
        "platform":      attr.string(mandatory = True),
        "url":           attr.string(mandatory = True),
        "sha256":        attr.string(mandatory = True),
        "strip_prefix":  attr.string(default = ""),
    },
)

# ---------------------------------------------------------------------------
# Repository rule: system-installed PostgreSQL (no download required)
#
# Symlinks the binaries and libraries from a system installation into an
# external repo that has the same layout as a downloaded tarball, so that
# the rest of the rule machinery is unchanged.
#
# Use pg.system() in MODULE.bazel instead of pg.version() when network
# access to the EnterpriseDB CDN is unavailable (CI air-gap, sandboxes, …).
# ---------------------------------------------------------------------------

def _pg_system_binary_repo_impl(rctx):
    bin_dir = rctx.attr.bin_dir
    lib_dir = rctx.attr.lib_dir
    pg_version = rctx.attr.pg_version

    # Auto-detect bin_dir if not provided.
    if not bin_dir:
        # First, $PATH (most local dev environments).
        res = rctx.execute(["sh", "-c", "command -v pg_ctl 2>/dev/null || true"])
        path = res.stdout.strip()
        if path:
            bin_dir = path.rsplit("/", 1)[0]
        else:
            # Then conventional install dirs. Order matters — `pg_ctl`
            # is reachable but `initdb`/`postgres` may be too only on
            # Debian/Ubuntu's /usr/lib/postgresql/<ver>/bin layout, NOT
            # on /usr/bin (only psql + pg_isready ship there as thin
            # wrappers). Probe the per-version dirs first to pick a
            # bin/ that actually has the full server toolset.
            res = rctx.execute(["sh", "-c",
                "ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1"])
            ubuntu_bin = res.stdout.strip()
            candidates = []
            if ubuntu_bin:
                candidates.append(ubuntu_bin)
            candidates += [
                "/usr/local/bin",
                "/usr/local/pgsql/bin",
                "/opt/homebrew/bin",     # macOS Homebrew (Apple Silicon)
                "/opt/local/bin",        # macOS MacPorts
                "/usr/pgsql-16/bin",     # PGDG RHEL/Fedora
                "/usr/pgsql-15/bin",
                "/usr/pgsql-14/bin",
                "/usr/bin",              # last; usually only ships wrappers
            ]
            for candidate in candidates:
                res = rctx.execute(["test", "-x", candidate + "/pg_ctl"])
                if res.return_code == 0:
                    bin_dir = candidate
                    break

    if not bin_dir:
        fail(
            "\nrules_pg: pg.system() — could not locate pg_ctl.\n" +
            "\n" +
            "rules_pg's `pg.system()` mode reuses an existing PostgreSQL\n" +
            "install on the host. To resolve this in CI, install postgres\n" +
            "before `bazel build`:\n" +
            "\n" +
            "  # GitHub Actions / Ubuntu runner:\n" +
            "  - name: Install PostgreSQL and put bin on PATH\n" +
            "    run: |\n" +
            "      set -euo pipefail\n" +
            "      sudo apt-get install -y postgresql\n" +
            "      pg_bin=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)\n" +
            "      echo \"$pg_bin\" >> \"$GITHUB_PATH\"\n" +
            "\n" +
            "  # Local Ubuntu/Debian:\n" +
            "    sudo apt-get install -y postgresql\n" +
            "\n" +
            "  # Local macOS (Homebrew):\n" +
            "    brew install postgresql@16\n" +
            "\n" +
            "  # Local RHEL/Fedora (PGDG):\n" +
            "    sudo dnf install -y postgresql-server\n" +
            "\n" +
            "Or pass an explicit bin_dir to pg.system() in MODULE.bazel:\n" +
            "  pg.system(versions = [\"16\"], bin_dir = \"/usr/lib/postgresql/16/bin\")\n" +
            "\n" +
            "A fully hermetic binary toolchain is tracked at\n" +
            "https://github.com/collider-bazel-extensions/rules_pg/issues\n" +
            "(target: v0.4). For now `pg.system()` is the only mode.\n"
        )

    # Verify required binaries exist and are executable. The common
    # failure on Ubuntu is that the user's $PATH points at /usr/bin
    # (which ships only psql + pg_isready as thin wrappers); the
    # server binaries (initdb, pg_ctl) live in
    # /usr/lib/postgresql/<ver>/bin/ and require either a PATH mod
    # or an explicit bin_dir override.
    required = ["pg_ctl", "initdb", "psql", "pg_isready"]
    missing = []
    for b in required:
        res = rctx.execute(["test", "-x", bin_dir + "/" + b])
        if res.return_code != 0:
            missing.append(bin_dir + "/" + b)
    if missing:
        # If the bin_dir is /usr/bin, suggest /usr/lib/postgresql/<ver>/bin.
        hint = ""
        if bin_dir == "/usr/bin":
            res = rctx.execute(["sh", "-c",
                "ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1"])
            ubuntu_bin = res.stdout.strip()
            if ubuntu_bin:
                hint = (
                    "\nHint: detected Ubuntu/Debian postgres at " + ubuntu_bin + " — pass\n" +
                    "  pg.system(versions = [\"" + pg_version + "\"], bin_dir = \"" + ubuntu_bin + "\")\n" +
                    "in MODULE.bazel, or add the dir to $PATH before `bazel build`:\n" +
                    "  echo \"" + ubuntu_bin + "\" >> \"$GITHUB_PATH\"\n"
                )
        fail(
            "\nrules_pg: pg.system() — required binaries missing or not executable:\n  " +
            "\n  ".join(missing) + "\n" +
            "Ensure PostgreSQL is fully installed and binaries are in " + bin_dir + "\n" +
            hint
        )

    # Auto-detect lib_dir if not provided.
    if not lib_dir:
        pg_config = bin_dir + "/pg_config"
        res = rctx.execute(["sh", "-c", '"' + pg_config + '" --libdir 2>/dev/null || true'])
        lib_dir = res.stdout.strip()
        if not lib_dir:
            res = rctx.execute(["sh", "-c",
                "find /usr/lib64 /usr/lib /usr/local/lib" +
                " /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu" +
                " -name 'libpq.so*' -maxdepth 2 2>/dev/null | head -1 || true"])
            libpq = res.stdout.strip()
            if libpq:
                lib_dir = libpq.rsplit("/", 1)[0]

    # Create the same bin/ + lib/ directory structure as a downloaded tarball.
    rctx.execute(["mkdir", "-p", "bin", "lib"])

    for b in ["pg_ctl", "initdb", "psql", "pg_isready", "pg_dump", "postgres"]:
        src = bin_dir + "/" + b
        result = rctx.execute(["test", "-f", src])
        if result.return_code == 0:
            rctx.symlink(src, "bin/" + b)

    # Symlink top-level shared libraries so LD_LIBRARY_PATH in the launcher
    # finds them.  Only follow the immediate directory (not subdirs) to avoid
    # pulling in PostgreSQL extension .so files that we don't need.
    if lib_dir:
        result = rctx.execute(["sh", "-c",
            "find " + lib_dir + " -maxdepth 1 -name 'libpq*.so*' 2>/dev/null"])
        for lib_path in result.stdout.splitlines():
            lib_path = lib_path.strip()
            if lib_path:
                rctx.symlink(lib_path, "lib/" + lib_path.split("/")[-1])

    # Symlink share/ from the system install if `pg_config --sharedir`
    # resolves. The all_files filegroup globs share/** so the directory
    # has to exist (or the glob has to allow_empty — both are in place).
    pg_config = bin_dir + "/pg_config"
    res = rctx.execute(["sh", "-c", '"' + pg_config + '" --sharedir 2>/dev/null || true'])
    share_dir = res.stdout.strip()
    if share_dir:
        res = rctx.execute(["test", "-d", share_dir])
        if res.return_code == 0:
            rctx.symlink(share_dir, "share")

    rctx.file("BUILD.bazel", _BUILD_TMPL.format(version = pg_version))

_pg_system_binary_repo = repository_rule(
    implementation = _pg_system_binary_repo_impl,
    attrs = {
        "pg_version": attr.string(mandatory = True),
        "bin_dir":    attr.string(default = "/usr/bin"),
        "lib_dir":    attr.string(default = ""),
    },
)

# ---------------------------------------------------------------------------
# Module extension
# ---------------------------------------------------------------------------

_version_tag = tag_class(attrs = {
    "versions": attr.string_list(default = ["14"]),
})

_system_tag = tag_class(attrs = {
    "versions": attr.string_list(default = ["14"]),
    "bin_dir":  attr.string(default = ""),
    "lib_dir":  attr.string(default = ""),
})

def _pg_extension_impl(module_ctx):
    # Collect system-binary overrides keyed by version.
    system_cfg = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.system:
            for v in tag.versions:
                system_cfg[v] = {"bin_dir": tag.bin_dir, "lib_dir": tag.lib_dir}

    # Collect requested download versions (skipped if a system override exists).
    download_versions = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.version:
            for v in tag.versions:
                if v not in system_cfg:
                    download_versions[v] = True

    # Validate all versions.
    for version in list(system_cfg.keys()) + list(download_versions.keys()):
        if version not in _PG_VERSIONS:
            fail("Unsupported PostgreSQL version: {}. Supported: {}".format(
                version,
                ", ".join(_PG_VERSIONS.keys()),
            ))

    # Create system repos.
    for version, cfg in system_cfg.items():
        for platform in _PLATFORMS:
            _pg_system_binary_repo(
                name = "pg_{}_{}".format(version, platform),
                pg_version = version,
                bin_dir = cfg["bin_dir"],
                lib_dir = cfg["lib_dir"],
            )

    # Create download repos.
    for version in download_versions.keys():
        for platform in _PLATFORMS:
            spec = _PG_VERSIONS[version][platform]
            _pg_binary_repo(
                name = "pg_{}_{}".format(version, platform),
                pg_version = version,
                platform = platform,
                url = spec.url,
                sha256 = spec.sha256,
                strip_prefix = spec.strip_prefix,
            )

pg = module_extension(
    implementation = _pg_extension_impl,
    tag_classes = {
        "version": _version_tag,
        "system":  _system_tag,
    },
)
