"Shared by pg_server and pg_test: target labels and postgresql.conf `config` checks."

# Settings the launcher sets and depends on (keep in sync with launcher.py's
# _RESERVED): connectivity, the log it reads, and where the cluster lives.
RESERVED_SETTINGS = [
    "port",
    "listen_addresses",
    "unix_socket_directories",
    "logging_collector",
    "log_destination",
    "data_directory",
    "config_file",
    "hba_file",
    "ident_file",
    "external_pid_file",
]

_NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_."

def label_string(label):
    """`//pkg:name` in the main repo, `@repo//pkg:name` elsewhere."""
    repo = "@" + label.repo_name if label.repo_name else ""
    return "{}//{}:{}".format(repo, label.package, label.name)

def check_config(where, config):
    """Fails analysis on a `config` entry rules_pg can't or won't write.

    Args:
        where: "<rule> <label>", the prefix of the error.
        config: the `config` string_dict.
    """
    for key, value in config.items():
        name = key.lower()
        ok = name != "" and not name[0].isdigit() and name[0] != "."
        for c in name.elems():
            if c not in _NAME_CHARS:
                ok = False
        if not ok:
            fail("{}: config: {} is not a setting name".format(where, json.encode(key)))
        if name in RESERVED_SETTINGS:
            fail("{}: config: {} is set by rules_pg".format(where, name))
        if "\n" in value or "\r" in value:
            fail("{}: config: the value of {} must be one line".format(where, key))

CONFIG_DOC = """\
postgresql.conf settings, `{"name": "value"}`, written after rules_pg's own
(so they override its defaults, e.g. `fsync` or `dynamic_shared_memory_type`).
Each value is written quoted, so pass every type as a string: `"work_mem":
"64MB"`, `"max_connections": "200"`. A setting PostgreSQL doesn't know fails
the server start, with its log. `port`, `listen_addresses`,
`unix_socket_directories`, `logging_collector`, `log_destination`,
`data_directory`, `config_file`, `hba_file`, `ident_file` and
`external_pid_file` are rules_pg's and fail analysis."""
