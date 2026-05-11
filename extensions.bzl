"Module extension: registers PostgreSQL binary toolchains per (version, platform)."

load("//tools:conda_versions.bzl", "CONDA_CLOSURES")

_PLATFORMS = ["linux_amd64", "darwin_arm64", "darwin_amd64"]

# Supported pg majors. Mirror the keys in CONDA_CLOSURES.
_SUPPORTED_VERSIONS = ["14", "15", "16"]

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
# Repository rule: hermetic PostgreSQL via conda-forge closure
#
# `pg.version()` fetches the full transitive dependency closure for
# postgresql=<major> from conda-forge — postgresql + libpq + libxml2 +
# openssl + readline + krb5 + libgcc + … — and extracts every package
# into one merged tree (bin/, lib/, share/). Conda binaries embed
# RPATH=$ORIGIN/../lib, so each binary finds its deps relative to its
# own location with no LD_LIBRARY_PATH munging required.
#
# Each .conda file is a zip containing two zstd-compressed tarballs:
#   - pkg-<name>-<ver>.tar.zst  (the actual binaries + libs + share)
#   - info-<name>-<ver>.tar.zst (recipe metadata — discarded)
# Extraction: unzip → tar --zstd -xf pkg-*.tar.zst. Modern GNU tar
# (1.31+) and BSD tar both support --zstd; the fallback path shells
# out to `zstd -d | tar -xf -` for older hosts.
# ---------------------------------------------------------------------------

def _pg_binary_repo_impl(rctx):
    version = rctx.attr.pg_version
    platform = rctx.attr.platform
    closure = CONDA_CLOSURES.get((version, platform))
    if not closure:
        fail("rules_pg: no conda closure for postgres {} on {}".format(version, platform))

    # Check for required host tools (unzip + tar with zstd support).
    # Both are present on every supported runner (ubuntu-latest, macOS
    # 13+, Fedora 38+). If missing, fail with an actionable error
    # rather than producing a half-extracted tree.
    res = rctx.execute(["sh", "-c", "command -v unzip >/dev/null"])
    if res.return_code != 0:
        fail(
            "rules_pg: pg.version() requires `unzip` on PATH " +
            "(install via `apt install unzip` / `brew install unzip`).",
        )
    has_tar_zstd = rctx.execute(["sh", "-c", "tar --zstd --version >/dev/null 2>&1"]).return_code == 0
    has_zstd_cli = rctx.execute(["sh", "-c", "command -v zstd >/dev/null"]).return_code == 0
    if not (has_tar_zstd or has_zstd_cli):
        fail(
            "rules_pg: pg.version() requires either GNU tar 1.31+ " +
            "(with --zstd support) or the `zstd` CLI. Install via " +
            "`apt install zstd` / `brew install zstd`.",
        )

    # Extract every package in the closure into the repo root,
    # merging trees. Each package lives under a `_dl/<name>/` sandbox
    # during its own extraction; the inner tar then materializes its
    # contents at the repo root.
    for i, entry in enumerate(closure):
        # Use the package index in the path to avoid collisions if two
        # packages happened to share the same basename (none do today,
        # but cheap to guard against).
        sandbox = "_dl/{}_{}".format(i, entry["name"])
        conda_file = "{}/package.conda".format(sandbox)
        rctx.download(
            url = entry["url"],
            output = conda_file,
            sha256 = entry["sha256"],
        )
        res = rctx.execute(["sh", "-c", "cd {} && unzip -q package.conda".format(sandbox)])
        if res.return_code != 0:
            fail("rules_pg: failed to unzip {}: {}".format(entry["name"], res.stderr))
        # Find the pkg-*.tar.zst inside (info-*.tar.zst is metadata
        # and not extracted).
        res = rctx.execute(["sh", "-c", "ls {}/pkg-*.tar.zst 2>/dev/null | head -1".format(sandbox)])
        pkg_tar = res.stdout.strip()
        if not pkg_tar:
            fail("rules_pg: .conda package missing pkg-*.tar.zst: {}".format(entry["name"]))
        # Extract pkg tarball to the repo root (cwd), merging.
        if has_tar_zstd:
            cmd = "tar --zstd -xf {}".format(pkg_tar)
        else:
            cmd = "zstd -d -c {} | tar -xf -".format(pkg_tar)
        res = rctx.execute(["sh", "-c", cmd])
        if res.return_code != 0:
            fail("rules_pg: tar extract failed for {}: {}".format(entry["name"], res.stderr))

    # Drop the download sandbox now that everything's merged.
    rctx.execute(["rm", "-rf", "_dl"])

    rctx.file(
        "BUILD.bazel",
        _BUILD_TMPL.format(version = version),
    )

_pg_binary_repo = repository_rule(
    implementation = _pg_binary_repo_impl,
    attrs = {
        "pg_version": attr.string(mandatory = True),
        "platform":   attr.string(mandatory = True),
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
    "versions": attr.string_list(default = ["16"]),
})

_system_tag = tag_class(attrs = {
    "versions": attr.string_list(default = ["16"]),
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

    # Validate all versions against the supported set.
    for version in list(system_cfg.keys()) + list(download_versions.keys()):
        if version not in _SUPPORTED_VERSIONS:
            fail("Unsupported PostgreSQL version: {}. Supported: {}".format(
                version,
                ", ".join(_SUPPORTED_VERSIONS),
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

    # Create hermetic (conda-closure-backed) repos.
    for version in download_versions.keys():
        for platform in _PLATFORMS:
            _pg_binary_repo(
                name = "pg_{}_{}".format(version, platform),
                pg_version = version,
                platform = platform,
            )

pg = module_extension(
    implementation = _pg_extension_impl,
    tag_classes = {
        "version": _version_tag,
        "system":  _system_tag,
    },
)
