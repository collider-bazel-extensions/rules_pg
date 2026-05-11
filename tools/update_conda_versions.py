#!/usr/bin/env python3
"""Resolve the full conda-forge dependency closure for postgresql and
emit a Bazel-loadable pin file for rules_pg's hermetic toolchain.

Maintainer usage:
    python3 tools/update_conda_versions.py 14 15 16 > tools/conda_versions.bzl

For each (postgres major version, supported platform) the script:
  1. Fetches conda-forge's repodata for that platform.
  2. Picks the highest-stable postgresql build matching the major.
  3. BFS-expands the transitive `depends` list, picking the
     highest-version package on conda-forge for each named dep that
     matches the version constraint.
  4. Resolves each chosen package to (url, sha256, size).
  5. Emits a CONDA_CLOSURES dict keyed by (version, platform) →
     list of pin entries.

Virtual packages (names starting with `__`, like `__glibc`) are
skipped — they represent system constraints, not real packages.

The repodata cache lives in `~/.cache/rules_pg_conda_cache/`; bust by
deleting the dir.
"""

import argparse
import functools
import hashlib
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

CACHE_DIR = Path.home() / ".cache" / "rules_pg_conda_cache"
CONDA_FORGE_BASE = "https://conda.anaconda.org/conda-forge"

PLATFORMS = {
    "linux_amd64":  "linux-64",
    "linux_arm64":  "linux-aarch64",
    "darwin_amd64": "osx-64",
    "darwin_arm64": "osx-arm64",
}


def _http_get(url: str, binary: bool = False) -> bytes | str:
    req = urllib.request.Request(url, headers={"User-Agent": "rules_pg-update_conda_versions/1.0"})
    with urllib.request.urlopen(req) as resp:
        data = resp.read()
    return data if binary else data.decode("utf-8")


@functools.lru_cache(maxsize=None)
def _fetch_repodata(conda_platform: str) -> dict:
    """Fetch conda-forge's repodata.json for one platform. Cached on disk."""
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_path = CACHE_DIR / f"repodata_{conda_platform}.json"
    if cache_path.exists():
        return json.loads(cache_path.read_text())
    print(f"[fetch] repodata for {conda_platform} (one-time, ~50-200MB)…", file=sys.stderr)
    body = _http_get(f"{CONDA_FORGE_BASE}/{conda_platform}/repodata.json")
    data = json.loads(body)
    cache_path.write_text(body)
    return data


def _parse_version(v: str) -> tuple:
    """A loose semver-ish key for sorting conda version strings.

    Conda versions are a superset of semver (`16.13`, `1.2.13rc1`,
    `3.0.7+deb`, …). For our purposes, take the leading dotted-int
    segments and ignore the rest.
    """
    parts = []
    for chunk in re.split(r"[.+-]", v):
        m = re.match(r"^(\d+)", chunk)
        if m:
            parts.append(int(m.group(1)))
        else:
            break
    return tuple(parts) or (0,)


def _matches_constraint(v: str, constraint: str) -> bool:
    """Check `v` against a conda-style version constraint, e.g.
    ">=1.19.3,<1.20.0a0". Returns True on match.

    Constraints support: ==, !=, >=, <=, >, <, =, and comma-separated
    AND. Wildcards (`*`) supported in `==1.2.*` form. Anything fancier
    (`(== or >=)`) falls back to True; that's a known loose match —
    the maintainer reviews the emitted pin set.
    """
    if not constraint:
        return True
    v_parts = _parse_version(v)
    for term in [t.strip() for t in constraint.split(",")]:
        if not term:
            continue
        m = re.match(r"^(==|!=|>=|<=|>|<|=)?\s*(.+)$", term)
        if not m:
            continue
        op = m.group(1) or "=="
        bound_raw = m.group(2).strip()
        if "*" in bound_raw:
            prefix = bound_raw.rstrip(".*")
            if op in ("==", "="):
                if not v.startswith(prefix):
                    return False
            continue
        b_parts = _parse_version(bound_raw)
        # Pad to equal length for comparison.
        n = max(len(v_parts), len(b_parts))
        a = v_parts + (0,) * (n - len(v_parts))
        b = b_parts + (0,) * (n - len(b_parts))
        if op == "==" or op == "=":
            if a != b:
                return False
        elif op == "!=":
            if a == b:
                return False
        elif op == ">=":
            if a < b:
                return False
        elif op == "<=":
            if a > b:
                return False
        elif op == ">":
            if a <= b:
                return False
        elif op == "<":
            if a >= b:
                return False
    return True


def _pick_best(repodata: dict, name: str, constraint: str) -> tuple[str, dict] | None:
    """Find the highest-version package on conda-forge that matches
    name + constraint. Returns (filename, package_info) or None.
    """
    candidates = []
    # repodata has two payload buckets: `packages` (legacy .tar.bz2)
    # and `packages.conda` (newer zstd-compressed .conda). Prefer
    # the latter — that's what we extract.
    for fname, info in repodata.get("packages.conda", {}).items():
        if info.get("name") != name:
            continue
        if not _matches_constraint(info.get("version", ""), constraint):
            continue
        candidates.append((fname, info))
    if not candidates:
        for fname, info in repodata.get("packages", {}).items():
            if info.get("name") != name:
                continue
            if not _matches_constraint(info.get("version", ""), constraint):
                continue
            candidates.append((fname, info))
    if not candidates:
        return None
    # Sort by (version, build_number, timestamp) descending.
    candidates.sort(
        key=lambda c: (
            _parse_version(c[1].get("version", "0")),
            c[1].get("build_number", 0),
            c[1].get("timestamp", 0),
        ),
        reverse=True,
    )
    return candidates[0]


def _resolve_closure(conda_platform: str, pg_major: str) -> list[dict]:
    """BFS the dependency closure for postgresql=<pg_major>.* on
    conda_platform. Returns a list of {name, version, build, url,
    sha256, size} dicts.

    Conda has two relevant repodata sources per resolution:
    `<platform>/repodata.json` (platform-specific packages) and
    `noarch/repodata.json` (architecture-independent, like tzdata).
    Try platform first, fall back to noarch.
    """
    repodata = _fetch_repodata(conda_platform)
    noarch_repodata = _fetch_repodata("noarch")

    def best(name: str, constraint: str):
        pick = _pick_best(repodata, name, constraint)
        if pick is not None:
            return pick, conda_platform
        pick = _pick_best(noarch_repodata, name, constraint)
        if pick is not None:
            return pick, "noarch"
        return None, None

    root, root_subdir = best("postgresql", f">={pg_major},<{int(pg_major)+1}")
    if not root:
        raise RuntimeError(f"no postgresql {pg_major}.* found on conda-forge/{conda_platform}")

    chosen: dict[str, tuple[tuple, str]] = {}  # name -> ((filename, info), subdir)
    chosen["postgresql"] = (root, root_subdir)
    queue = [root]

    while queue:
        _fname, info = queue.pop(0)
        for dep in info.get("depends", []):
            # Strip channel prefix if any ("conda-forge::libpq >=...").
            d = dep.split("::", 1)[-1].strip()
            parts = d.split(None, 1)
            name = parts[0]
            constraint = parts[1] if len(parts) > 1 else ""
            if name.startswith("__"):
                # Virtual package (system constraint). Skip.
                continue
            if name in chosen:
                continue
            pick, subdir = best(name, constraint)
            if not pick:
                print(f"[warn] {conda_platform}/{pg_major}: no candidate for {name} {constraint!r}", file=sys.stderr)
                continue
            chosen[name] = (pick, subdir)
            queue.append(pick)

    out = []
    for name, ((fname, info), subdir) in chosen.items():
        sha = info.get("sha256")
        if not sha:
            sha = _compute_sha256(f"{CONDA_FORGE_BASE}/{subdir}/{fname}")
        out.append({
            "name":    name,
            "version": info.get("version", ""),
            "build":   info.get("build", ""),
            "url":     f"{CONDA_FORGE_BASE}/{subdir}/{fname}",
            "sha256":  sha,
            "size":    info.get("size", 0),
        })
    out.sort(key=lambda e: e["name"])
    return out


def _compute_sha256(url: str) -> str:
    body = _http_get(url, binary=True)
    return hashlib.sha256(body).hexdigest()


def _emit_bzl(closures: dict, majors: list[str]) -> str:
    lines = [
        '"""Auto-generated conda-forge dependency closures for hermetic PostgreSQL.',
        '',
        'Generated by `python3 tools/update_conda_versions.py 14 15 16` against',
        'conda-forge\'s repodata.json. Each closure is the full transitive',
        'dependency set for `postgresql=<major>` on the given platform — every',
        'shared library the postgres binaries link against (libpq, libxml2,',
        'openssl, readline, krb5, libgcc, …) so the binaries run without any',
        'host system libraries beyond glibc + basic OS bits.',
        '',
        'Conda binaries are built with RPATH=$ORIGIN/../lib, so merging every',
        'package\'s `bin/` + `lib/` + `share/` into one tree at extract time',
        'lets the binaries find their deps relative to their own location.',
        '',
        'Maintainer flow:',
        '    python3 tools/update_conda_versions.py 14 15 16 \\',
        '        > tools/conda_versions.bzl',
        '"""',
        '',
        '# (version, platform) -> list of {name, version, build, url, sha256}',
        'CONDA_CLOSURES = {',
    ]
    for major in majors:
        for plat in PLATFORMS.keys():
            key = (major, plat)
            entries = closures.get(key)
            if not entries:
                continue
            lines.append(f'    ("{major}", "{plat}"): [')
            for e in entries:
                lines.append('        {')
                lines.append(f'            "name":    "{e["name"]}",')
                lines.append(f'            "version": "{e["version"]}",')
                lines.append(f'            "build":   "{e["build"]}",')
                lines.append(f'            "url":     "{e["url"]}",')
                lines.append(f'            "sha256":  "{e["sha256"]}",')
                lines.append('        },')
            lines.append('    ],')
    lines.append('}')
    lines.append('')
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("majors", nargs="+", help="postgres major versions, e.g. 14 15 16")
    args = parser.parse_args()

    closures = {}
    for major in args.majors:
        for plat_key, conda_plat in PLATFORMS.items():
            print(f"[resolve] postgres {major} {plat_key} ({conda_plat})", file=sys.stderr)
            closure = _resolve_closure(conda_plat, major)
            print(f"          → {len(closure)} packages", file=sys.stderr)
            closures[(major, plat_key)] = closure

    sys.stdout.write(_emit_bzl(closures, args.majors))


if __name__ == "__main__":
    main()
