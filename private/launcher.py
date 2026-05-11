#!/usr/bin/env python3
"""
rules_pg launcher.

Two modes, selected by RULES_PG_MODE (default: "test"):

  test   — initdb → migrate → seed → exec test binary; atexit stop (best-effort)
  server — initdb → migrate → seed → write env file → block until SIGTERM/SIGINT → stop

Never imported; always exec'd by a wrapper shell script.
"""

import atexit
import dataclasses
import json
import os
import platform
import signal
import socket
import subprocess
import sys
import tempfile
import time

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _log(msg: str) -> None:
    print(f"[rules_pg] {msg}", file=sys.stderr, flush=True)


def _find_runfile(rel_path: str, workspace: str = "") -> str:
    """Resolve a runfile path relative to the runfiles root.

    Bazel uses two conventions for File.short_path:
      - External repo:  "../repo_name/path"  →  "<root>/repo_name/path"
      - Main workspace: "path/to/file"       →  "<root>/<workspace>/path/to/file"

    We try several candidates in order.
    """
    runfiles_dir = os.environ.get("RUNFILES_DIR") or (sys.argv[0] + ".runfiles")

    candidates = []
    if rel_path.startswith("../"):
        candidates.append(os.path.join(runfiles_dir, rel_path[3:]))
    else:
        if workspace:
            candidates.append(os.path.join(runfiles_dir, workspace, rel_path))
        candidates.append(os.path.join(runfiles_dir, rel_path))

    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate

    manifest_file = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_file and os.path.exists(manifest_file):
        with open(manifest_file) as f:
            for line in f:
                key, _, val = line.strip().partition(" ")
                if key == rel_path or (rel_path.startswith("../") and key == rel_path[3:]):
                    return val

    raise FileNotFoundError(f"Runfile not found: {rel_path} (tried: {candidates})")


def _allocate_port() -> tuple[int, socket.socket | None]:
    """
    Return (port, sock_or_None).

    On Python ≥ 3.9 and PG ≥ 14 we keep the socket open so the caller can
    pass --socket-fd to pg_ctl, eliminating the TOCTOU race.  On older
    combinations we close immediately and accept the (small) race.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    return port, s


def _is_port_conflict(log_path: str) -> bool:
    """Return True if the Postgres log shows a TCP port binding failure."""
    if not os.path.exists(log_path):
        return False
    try:
        with open(log_path) as f:
            content = f.read()
    except OSError:
        return False
    return "Address already in use" in content or "could not bind" in content


def _wait_ready(pg_isready: str, host: str, port: int, timeout: float = 15.0,
                lib_dir: str = "") -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            [pg_isready, "-h", host, "-p", str(port), "-q"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=_pg_env(lib_dir),
        )
        if result.returncode == 0:
            return
        time.sleep(0.2)
    raise TimeoutError(f"Postgres did not become ready within {timeout}s on port {port}")


def _pg_major_version(pg_ctl_bin: str, lib_dir: str = "") -> int:
    """Return the PostgreSQL major version by querying pg_ctl --version.

    Output is like "pg_ctl (PostgreSQL) 18.3"; we return 18.
    """
    result = subprocess.run(
        [pg_ctl_bin, "--version"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=_pg_env(lib_dir),
    )
    out = result.stdout.decode("utf-8", errors="replace").strip()
    for token in out.split():
        if token and token[0].isdigit():
            try:
                return int(token.split(".")[0])
            except ValueError:
                pass
    return 0


def _ensure_executable(path: str) -> None:
    """Ensure a file has the execute bit set for the owner."""
    st = os.stat(path)
    if not (st.st_mode & 0o100):
        os.chmod(path, st.st_mode | 0o111)


def _pg_env(lib_dir: str) -> dict:
    """
    Return a copy of os.environ with the PostgreSQL bundled lib dir prepended
    to the dynamic-linker search path so binaries find their shared libraries.
    """
    env = os.environ.copy()
    if not lib_dir or not os.path.isdir(lib_dir):
        return env
    if platform.system() == "Darwin":
        key = "DYLD_LIBRARY_PATH"
    else:
        key = "LD_LIBRARY_PATH"
    existing = env.get(key, "")
    env[key] = lib_dir + (":" + existing if existing else "")
    return env


def _psql(psql_bin: str, host: str, port: int, user: str, database: str,
          password: str, sql: str | None = None, file: str | None = None,
          lib_dir: str = "") -> None:
    env = _pg_env(lib_dir)
    env["PGPASSWORD"] = password
    cmd = [
        psql_bin,
        "-h", host,
        "-p", str(port),
        "-U", user,
        "-d", database,
        "--no-password",
        "-v", "ON_ERROR_STOP=1",
    ]
    if file:
        cmd += ["-f", file]
    elif sql:
        cmd += ["-c", sql]
    else:
        raise ValueError("Either sql= or file= must be provided")
    subprocess.run(cmd, check=True, env=env)


def _copy_csv(psql_bin: str, host: str, port: int, user: str, database: str,
              password: str, csv_path: str, lib_dir: str = "") -> None:
    table = os.path.splitext(os.path.basename(csv_path))[0]
    sql = rf"\copy {table} FROM '{csv_path}' CSV HEADER"
    _psql(psql_bin, host, port, user, database, password, sql=sql, lib_dir=lib_dir)


# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class _PgState:
    pgdata:      str
    pg_log:      str
    pg_ctl:      str
    pg_lib_dir:  str
    host:        str
    port:        int
    database:    str
    pg_user:     str
    pg_password: str
    psql:        str


# ---------------------------------------------------------------------------
# pg_setup: initdb → start → migrate → seed → return _PgState
# ---------------------------------------------------------------------------

def _pg_setup(m: dict) -> _PgState:
    """Spin up an ephemeral PostgreSQL cluster from a manifest dict.

    Performs initdb, tunes postgresql.conf, starts the server (with retry on
    port conflicts), creates the database, applies migrations in order, and
    loads seed data.  Returns a _PgState describing the running cluster.
    """
    workspace   = m.get("workspace", "")
    pg_ctl      = _find_runfile(m["pgctl"], workspace)
    initdb_bin  = _find_runfile(m["initdb"], workspace)
    psql_bin    = _find_runfile(m["psql"], workspace)
    pg_isready  = _find_runfile(m["pg_isready"], workspace)
    pg_version  = int(m.get("pg_version", "14"))
    migrations  = [_find_runfile(p, workspace) for p in m.get("migrations", [])]
    seed_files  = [_find_runfile(p, workspace) for p in m.get("seed_files", [])]
    database    = m.get("database", "test")
    pg_user     = m.get("pg_user", "postgres")
    pg_password = m.get("pg_password", "postgres")

    pg_lib_dir = os.path.join(os.path.dirname(os.path.dirname(pg_ctl)), "lib")

    for bin_path in (pg_ctl, initdb_bin, psql_bin, pg_isready):
        _ensure_executable(bin_path)

    actual_pg_version = _pg_major_version(pg_ctl, pg_lib_dir)
    if actual_pg_version == 0:
        actual_pg_version = pg_version
    _log(f"Detected PostgreSQL binary version: {actual_pg_version}")

    test_tmpdir = os.environ.get("TEST_TMPDIR") or tempfile.mkdtemp(prefix="rules_pg_")
    pgdata = os.path.join(test_tmpdir, "pgdata")
    pg_log = os.path.join(test_tmpdir, "pg.log")
    os.makedirs(pgdata, exist_ok=True)
    os.chmod(pgdata, 0o700)

    host = "127.0.0.1"
    port, reserved_sock = _allocate_port()
    # `--socket-fd` is a Debian-postgresql-common patch (NOT in
    # upstream postgres). Conda-forge's binaries — and any other
    # upstream-source build — reject it with `unrecognized
    # configuration parameter "socket_fd"`. Probe the binary's
    # help text once to decide whether to use the patched flag.
    postgres_bin = os.path.join(os.path.dirname(pg_ctl), "postgres")
    socket_fd_supported = False
    if 14 <= actual_pg_version <= 17 and os.path.exists(postgres_bin):
        help_result = subprocess.run(
            [postgres_bin, "--help"],
            capture_output=True, text=True,
            env=_pg_env(pg_lib_dir),
        )
        socket_fd_supported = "--socket-fd" in (help_result.stdout + help_result.stderr)
    use_socket_fd = (
        socket_fd_supported
        and reserved_sock is not None
        and os.environ.get("RULES_PG_DISABLE_SOCKET_FD") != "1"
    )

    _log(f"Running initdb in {pgdata}")
    subprocess.run(
        [
            initdb_bin,
            "-D", pgdata,
            "-U", pg_user,
            "--no-locale",
            "--encoding=UTF8",
            "--auth=scram-sha-256",
            "--pwfile=/dev/stdin",
        ],
        input=pg_password.encode(),
        check=True,
        stdout=subprocess.DEVNULL,
        env=_pg_env(pg_lib_dir),
    )

    conf_path = os.path.join(pgdata, "postgresql.conf")
    with open(conf_path, "a") as cf:
        cf.write("\n# rules_pg ephemeral overrides\n")
        cf.write(f"listen_addresses = '127.0.0.1'\n")
        cf.write(f"port = {port}\n")
        cf.write("fsync = off\n")
        cf.write("synchronous_commit = off\n")
        cf.write("full_page_writes = off\n")
        cf.write("log_min_messages = WARNING\n")
        cf.write("log_min_error_statement = ERROR\n")
        cf.write("logging_collector = off\n")
        cf.write("log_destination = 'stderr'\n")
        cf.write("unix_socket_directories = ''\n")

    start_cmd = [pg_ctl, "start", "-D", pgdata, "-l", pg_log, "-w"]
    if use_socket_fd:
        start_cmd += ["-o", f"--socket-fd={reserved_sock.fileno()}"]

    max_attempts = 5
    for attempt in range(1, max_attempts + 1):
        try:
            _log(f"Starting Postgres on 127.0.0.1:{port} (attempt {attempt})")
            pg_run_env = _pg_env(pg_lib_dir)
            if use_socket_fd:
                subprocess.run(start_cmd, check=True, pass_fds=(reserved_sock.fileno(),),
                               stdout=subprocess.DEVNULL, env=pg_run_env)
                reserved_sock.close()
            else:
                if reserved_sock:
                    reserved_sock.close()
                subprocess.run(start_cmd, check=True, stdout=subprocess.DEVNULL,
                               env=pg_run_env)

            _wait_ready(pg_isready, host, port, lib_dir=pg_lib_dir)
            _log("Postgres ready.")
            break
        except (subprocess.CalledProcessError, TimeoutError) as exc:
            _log(f"Attempt {attempt} failed: {exc}")
            log_content = ""
            if os.path.exists(pg_log):
                with open(pg_log) as lf:
                    log_content = lf.read()

            if attempt == max_attempts:
                if log_content:
                    _log("Server log:\n" + log_content)
                sys.exit(1)

            if log_content and not _is_port_conflict(pg_log):
                _log("Non-retriable error detected. Server log:\n" + log_content)
                sys.exit(1)

            port, reserved_sock = _allocate_port()
            use_socket_fd = (
                socket_fd_supported
                and reserved_sock is not None
                and os.environ.get("RULES_PG_DISABLE_SOCKET_FD") != "1"
            )
            with open(conf_path, "a") as cf:
                cf.write(f"port = {port}\n")

    _log(f"Creating database '{database}'")
    _psql(psql_bin, host, port, pg_user, "postgres", pg_password,
          sql=f"CREATE DATABASE \"{database}\";", lib_dir=pg_lib_dir)

    for migration in migrations:
        _log(f"Applying migration: {os.path.basename(migration)}")
        _psql(psql_bin, host, port, pg_user, database, pg_password,
              file=migration, lib_dir=pg_lib_dir)

    for seed_file in seed_files:
        ext = os.path.splitext(seed_file)[1].lower()
        _log(f"Loading seed: {os.path.basename(seed_file)}")
        if ext == ".sql":
            _psql(psql_bin, host, port, pg_user, database, pg_password,
                  file=seed_file, lib_dir=pg_lib_dir)
        elif ext == ".csv":
            _copy_csv(psql_bin, host, port, pg_user, database, pg_password,
                      seed_file, lib_dir=pg_lib_dir)
        else:
            _log(f"Warning: unknown seed file type '{ext}', skipping.")

    return _PgState(
        pgdata      = pgdata,
        pg_log      = pg_log,
        pg_ctl      = pg_ctl,
        pg_lib_dir  = pg_lib_dir,
        host        = host,
        port        = port,
        database    = database,
        pg_user     = pg_user,
        pg_password = pg_password,
        psql        = psql_bin,
    )


# ---------------------------------------------------------------------------
# _stop_cluster: shared teardown
# ---------------------------------------------------------------------------

def _stop_cluster(state: _PgState) -> None:
    _log("Stopping Postgres …")
    subprocess.run(
        [state.pg_ctl, "stop", "-D", state.pgdata, "-m", "fast", "-w"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


# ---------------------------------------------------------------------------
# main_test: pg_setup → exec test binary
#
# atexit is registered as a best-effort stop.  os.execve replaces the process
# image so Python's atexit handlers do not fire after the execve'd binary
# exits; the cluster is cleaned up when Bazel removes TEST_TMPDIR.
# ---------------------------------------------------------------------------

def main_test(m: dict) -> None:
    state = _pg_setup(m)
    atexit.register(_stop_cluster, state)

    test_binary = os.environ.get("RULES_PG_TEST_BINARY")
    if not test_binary:
        sys.exit("[rules_pg] RULES_PG_TEST_BINARY not set")
    workspace = m.get("workspace", "")
    if not os.path.isabs(test_binary):
        test_binary = _find_runfile(test_binary, workspace)

    env = _pg_env(state.pg_lib_dir)
    env["PGHOST"]     = state.host
    env["PGPORT"]     = str(state.port)
    env["PGDATABASE"] = state.database
    env["PGUSER"]     = state.pg_user
    env["PGPASSWORD"] = state.pg_password

    _log(f"Executing test binary: {test_binary}")
    os.execve(test_binary, [test_binary] + sys.argv[1:], env)


# ---------------------------------------------------------------------------
# main_server: pg_setup → write env file → block until SIGTERM/SIGINT
#
# The env file is written only after _pg_setup returns (cluster fully ready,
# all migrations and seeds applied).  Its existence is the readiness signal
# consumed by pg_health_check.
# ---------------------------------------------------------------------------

def main_server(m: dict) -> None:
    output_env_file = os.environ.get("RULES_PG_OUTPUT_ENV_FILE")
    if not output_env_file:
        sys.exit("[rules_pg] RULES_PG_OUTPUT_ENV_FILE not set")

    state = _pg_setup(m)

    # Write connection details for consumers.  Written atomically (to a temp
    # file then renamed) so readers never observe a partial write.
    tmp = output_env_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"PGHOST={state.host}\n")
        f.write(f"PGPORT={state.port}\n")
        f.write(f"PGDATABASE={state.database}\n")
        f.write(f"PGUSER={state.pg_user}\n")
        f.write(f"PGPASSWORD={state.pg_password}\n")
    os.replace(tmp, output_env_file)
    _log(f"Connection details written to {output_env_file}")

    def _handle_shutdown(signum, frame):
        _stop_cluster(state)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _handle_shutdown)
    signal.signal(signal.SIGINT, _handle_shutdown)

    _log("PostgreSQL server ready. Waiting for shutdown signal.")
    while True:
        signal.pause()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    manifest_path = os.environ.get("RULES_PG_MANIFEST")
    if not manifest_path:
        sys.exit("[rules_pg] RULES_PG_MANIFEST not set")
    with open(manifest_path) as f:
        m = json.load(f)

    mode = os.environ.get("RULES_PG_MODE", "test")
    if mode == "server":
        main_server(m)
    else:
        main_test(m)


if __name__ == "__main__":
    main()
