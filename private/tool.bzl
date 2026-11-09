"postgres_tool rule: one PostgreSQL client from a postgres_binary, as a runnable target."

load(":binary.bzl", "PostgresBinaryInfo")

_WRAPPER = """\
#!/usr/bin/env bash
set -euo pipefail
# {tool} at the pinned version: found in runfiles, run from the caller's directory.
if [[ -d "$0.runfiles" ]]; then r="$0.runfiles"
elif [[ -n "${{RUNFILES_DIR:-}}" ]]; then r="$RUNFILES_DIR"
else echo "{label}: cannot find runfiles" >&2; exit 1; fi
bin="$r/{rlocation}"
if [[ -n "${{BUILD_WORKING_DIRECTORY:-}}" ]]; then cd "$BUILD_WORKING_DIRECTORY"; fi
exec "$bin" "$@"
"""

def _rlocation(ctx, f):
    if f.short_path.startswith("../"):
        return f.short_path[len("../"):]
    return ctx.workspace_name + "/" + f.short_path

def _postgres_tool_impl(ctx):
    info = ctx.attr.binary[PostgresBinaryInfo]
    files = info.all_files.to_list()
    matches = [f for f in files if f.basename == ctx.attr.tool and f.dirname.endswith("/bin")]
    if not matches:
        fail(("{}: '{}' is not in the PostgreSQL {} install (pg.system links a client " +
              "only when the host has it). Clients there: {}").format(
            ctx.label,
            ctx.attr.tool,
            info.version,
            sorted([f.basename for f in files if f.dirname.endswith("/bin")]),
        ))
    tool = matches[0]
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        out,
        _WRAPPER.format(tool = ctx.attr.tool, label = str(ctx.label), rlocation = _rlocation(ctx, tool)),
        is_executable = True,
    )

    # The whole install, so the binary's RPATH ($ORIGIN/../lib) resolves in
    # the runfiles; no LD_LIBRARY_PATH (rules_pg#7).
    return [DefaultInfo(
        executable = out,
        runfiles = ctx.runfiles(files = [out], transitive_files = info.all_files),
    )]

postgres_tool = rule(
    implementation = _postgres_tool_impl,
    doc = """\
A runnable PostgreSQL client (psql, pg_dump, ...) from a postgres_binary.

`bazel run` runs it from the directory `bazel run` was invoked in, so
relative paths in its arguments resolve there. It also works as `data` of
another target (it finds its runfiles through $0.runfiles or RUNFILES_DIR).
""",
    executable = True,
    attrs = {
        "binary": attr.label(
            mandatory = True,
            providers = [PostgresBinaryInfo],
            doc = "A postgres_binary target, e.g. @rules_pg//:pg_16.",
        ),
        "tool": attr.string(mandatory = True, doc = "The bin/ file to run, e.g. \"psql\"."),
    },
)
