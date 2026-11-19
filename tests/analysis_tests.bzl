"""Analysis-time tests: an empty postgres_schema, and the analysis errors for
bad `config` entries on pg_server and pg_test."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_pg//:defs.bzl", "PostgresSchemaInfo", "pg_server", "pg_test", "postgres_schema")

def _empty_schema_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[PostgresSchemaInfo]
    asserts.equals(env, [], info.migrations.to_list())
    asserts.equals(env, "16", info.binary.version)
    return analysistest.end(env)

_empty_schema_test = analysistest.make(_empty_schema_impl)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_fails_test = analysistest.make(
    _fails_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

def analysis_test_suite(name):
    s = name + "_subject"
    postgres_schema(name = s + "_empty_schema", tags = ["manual"])
    pg_server(name = s + "_reserved", config = {"port": "5432"}, tags = ["manual"])
    pg_server(name = s + "_socket", config = {"unix_socket_directories": "/tmp"}, tags = ["manual"])
    pg_server(name = s + "_bad_name", config = {"work mem": "4MB"}, tags = ["manual"])
    pg_server(name = s + "_multiline", config = {"work_mem": "4MB\nport = 1"}, tags = ["manual"])
    pg_test(
        name = s + "_test_reserved",
        srcs = ["empty_schema_test.sh"],
        config = {"data_directory": "/var/lib/pgsql"},
        tags = ["manual"],
    )

    tests = {
        "_empty_schema": (_empty_schema_test, s + "_empty_schema", None),
        "_reserved": (_fails_test, s + "_reserved", "config: port is set by rules_pg"),
        "_socket": (_fails_test, s + "_socket", "config: unix_socket_directories is set by rules_pg"),
        "_bad_name": (_fails_test, s + "_bad_name", "config: \"work mem\" is not a setting name"),
        "_multiline": (_fails_test, s + "_multiline", "config: the value of work_mem must be one line"),
        "_test_reserved": (_fails_test, s + "_test_reserved", "config: data_directory is set by rules_pg"),
    }
    for suffix, (rule, target, message) in tests.items():
        if message:
            rule(name = name + suffix, target_under_test = ":" + target, message = message)
        else:
            rule(name = name + suffix, target_under_test = ":" + target)
    native.test_suite(name = name, tests = [":" + name + t for t in tests])
