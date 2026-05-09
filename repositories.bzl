"""
Legacy WORKSPACE support.

Bzlmod users (MODULE.bazel) do not need this file.
"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# Mirrors _PG_VERSIONS from extensions.bzl for WORKSPACE users.
# Keep in sync.
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

_BUILD_TMPL = """
load("@rules_pg//private:binary.bzl", "postgres_binary_files")

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

# `allow_empty` is on because the system-mode repo impl symlinks only
# the bin/lib/share files that actually exist on the host — `share/`
# may be empty on a libpq-only install. Bazel 8+ defaults
# --incompatible_disallow_empty_glob to True.
filegroup(
    name = "all_files",
    srcs = glob(["bin/**", "lib/**", "share/**"], allow_empty = True),
    visibility = ["//visibility:public"],
)
"""

def _pg_system_binary_repo_impl(rctx):
    """Symlinks a system-installed PostgreSQL into an external repo."""
    bin_dir = rctx.attr.bin_dir
    lib_dir = rctx.attr.lib_dir
    pg_version = rctx.attr.pg_version

    # Auto-detect bin_dir if not provided.
    if not bin_dir:
        res = rctx.execute(["sh", "-c", "command -v pg_ctl 2>/dev/null || true"])
        path = res.stdout.strip()
        if path:
            bin_dir = path.rsplit("/", 1)[0]
        else:
            for candidate in ["/usr/bin", "/usr/local/bin", "/usr/local/pgsql/bin",
                               "/opt/homebrew/bin", "/opt/local/bin"]:
                res = rctx.execute(["test", "-x", candidate + "/pg_ctl"])
                if res.return_code == 0:
                    bin_dir = candidate
                    break

    if not bin_dir:
        fail(
            "\nrules_pg: pg_system_dependencies() — could not locate pg_ctl.\n" +
            "Either install PostgreSQL or pass bin_dir = '/path/to/pg/bin'.\n"
        )

    # Verify required binaries exist and are executable.
    required = ["pg_ctl", "initdb", "psql", "pg_isready"]
    missing = []
    for b in required:
        res = rctx.execute(["test", "-x", bin_dir + "/" + b])
        if res.return_code != 0:
            missing.append(bin_dir + "/" + b)
    if missing:
        fail(
            "\nrules_pg: pg_system_dependencies() — required binaries missing:\n  " +
            "\n  ".join(missing) + "\n"
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

    rctx.execute(["mkdir", "-p", "bin", "lib"])
    for b in ["pg_ctl", "initdb", "psql", "pg_isready", "pg_dump", "postgres"]:
        src = bin_dir + "/" + b
        result = rctx.execute(["test", "-f", src])
        if result.return_code == 0:
            rctx.symlink(src, "bin/" + b)

    if lib_dir:
        result = rctx.execute(["sh", "-c",
            "find " + lib_dir + " -maxdepth 1 -name 'libpq*.so*' 2>/dev/null"])
        for lib_path in result.stdout.splitlines():
            lib_path = lib_path.strip()
            if lib_path:
                rctx.symlink(lib_path, "lib/" + lib_path.split("/")[-1])

    # Symlink share/ from the system install if `pg_config --sharedir`
    # resolves. Allows the all_files glob to pick up share/** files.
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
        "bin_dir":    attr.string(default = ""),
        "lib_dir":    attr.string(default = ""),
    },
)

def pg_system_dependencies(versions = None, bin_dir = "", lib_dir = ""):
    """Create external repos backed by a system-installed PostgreSQL.

    Use this instead of rules_pg_dependencies() when the EnterpriseDB CDN is
    unreachable (air-gapped CI, sandboxes, …).

    Args:
        versions: list of version strings. Default ["14"].
        bin_dir:  directory containing pg_ctl, initdb, psql, … Default "/usr/bin".
        lib_dir:  directory containing libpq shared libraries. Default "".
    """
    versions = versions or ["14"]
    for version in versions:
        for platform in _PLATFORMS:
            name = "pg_{}_{}".format(version, platform)
            if not native.existing_rule(name):
                _pg_system_binary_repo(
                    name = name,
                    pg_version = version,
                    bin_dir = bin_dir,
                    lib_dir = lib_dir,
                )

def rules_pg_dependencies(versions = None):
    """Download pre-built PostgreSQL tarballs.

    Args:
        versions: list of version strings to download. Default ["14"].
    """
    versions = versions or ["14"]
    for version in versions:
        for platform in _PLATFORMS:
            spec = _PG_VERSIONS[version][platform]
            name = "pg_{}_{}".format(version, platform)
            if not native.existing_rule(name):
                http_archive(
                    name         = name,
                    urls         = [spec.url],
                    sha256       = spec.sha256,
                    strip_prefix = spec.strip_prefix,
                    build_file_content = _BUILD_TMPL.format(version = version),
                )

def rules_pg_register_toolchains(versions = None):
    """Register pg toolchains for the given versions.

    Args:
        versions: list of version strings. Default ["14"].
    """
    versions = versions or ["14"]
    for version in versions:
        for platform in ["linux_amd64", "darwin_arm64", "darwin_amd64"]:
            native.register_toolchains(
                "@rules_pg//toolchain:pg_{}_{}_toolchain".format(version, platform),
            )
