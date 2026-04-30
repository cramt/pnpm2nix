"""Parse pnpm-lock.yaml v9 and emit a JSON description suitable for IFD.

Output shape:

{
  "lockfileVersion": "9.0",
  "packages": {                      # one entry per name@version, used for fetching
    "<name>@<version>": { name, version, url, integrity, os, cpu }
  },
  "snapshots": {                     # one entry per peer-resolved key, used for
    "<key>": {                       # building the .pnpm/<key>/node_modules layout
      "name": "...",
      "version": "...",
      "package": "<name>@<version>", # which packages-entry to install
      "deps": { "<name>": "<key>" }, # resolved deps (incl. optional & peers)
      "hasBin": false,
      "optional": false
    }
  },
  "importers": {                     # one entry per workspace project (incl. ".")
    "<path>": {
      "deps":         { "<name>": "<key>" },
      "devDeps":      { "<name>": "<key>" },
      "optionalDeps": { "<name>": "<key>" }
    }
  },
  "workspacePackages": [ "packages/foo", ... ],    # snapshot keys whose source
                                                   # is a workspace path, not a
                                                   # tarball (link:/file:/workspace:)
  "patchedDependencies": {             # pnpm patches to apply after extraction
    "<name>@<version>": {
      "path": "patches/foo@1.0.0.patch",
      "hash": "abc123..."
    }
  }
}

The split between `packages` and `snapshots` mirrors the lockfile itself in v9:
- `packages` is keyed by name@version and holds the fetch info (one tarball regardless
  of how many peer combinations are used).
- `snapshots` is keyed by name@version + optional peer-resolution suffix, which becomes
  the directory name inside node_modules/.pnpm/. Two snapshots that share a `package`
  share the same fetched tarball but have different dep graphs.

This split is what makes per-dep caching possible: change a peer dep, and only the
affected snapshot derivations rebuild. The fetched tarball is untouched.
"""

import json
import re
import sys
from pathlib import Path

import yaml

# Match a snapshot/dep-spec key like "react-dom@18.2.0(react@18.2.0)(scheduler@0.23.0)".
# Groups: (name, version, peer-suffix-or-empty).
KEY_RE = re.compile(r"^(?P<name>(?:@[^/]+/)?[^@()]+)@(?P<version>[^()]+)(?P<peers>\(.*\))?$")


def parse_key(key: str) -> tuple[str, str, str] | None:
    m = KEY_RE.match(key)
    if not m:
        return None
    return m["name"], m["version"], m["peers"] or ""


def tarball_url(name: str, version: str) -> str:
    basename = name.split("/")[-1]
    return f"https://registry.npmjs.org/{name}/-/{basename}-{version}.tgz"


def is_workspace_ref(spec: str) -> bool:
    """A snapshot whose `version` field looks like link:/file:/workspace:.

    These refer to local workspace packages, not registry tarballs.
    """
    return spec.startswith(("link:", "file:", "workspace:"))


def is_alias_dep(dep_name: str, dep_value: str) -> bool:
    """Detect npm aliases: the dep name differs from the resolved package name.

    Normal deps:   { "react": "18.2.0" }          → key = react@18.2.0
    Alias deps:    { "h3-v2": "h3@2.0.1-rc.20" }  → key = h3@2.0.1-rc.20

    In the lockfile, resolved version strings always start with a digit (semver).
    Alias values start with a package name (letter or @), making them already a
    full snapshot key reference.

    Workspace protocols (link:, file:, workspace:) also start with a letter but
    are NOT aliases — they reference local paths and need dep_name@ prepended.
    """
    if not dep_value:
        return False
    if dep_value[0].isdigit():
        return False
    if dep_value.startswith(("link:", "file:", "workspace:")):
        return False
    return True


def resolve_dep_key(dep_name: str, dep_value: object) -> tuple[str, str]:
    """Resolve a snapshot dependency to (import_name, snapshot_key).

    Returns the name used in `node_modules/` (may differ from the snapshot key's
    package name for aliases) and the snapshot key to look up.
    """
    v = str(dep_value)
    if is_alias_dep(dep_name, v):
        # Alias: value is already the full key (e.g. "h3@2.0.1-rc.20").
        # The dep is installed as dep_name in node_modules/ but resolves
        # to a different package.
        return dep_name, v
    else:
        # Normal: form key as dep_name@version.
        return dep_name, f"{dep_name}@{v}"


def main(lockfile_path: str) -> None:
    data = yaml.safe_load(Path(lockfile_path).read_text())
    if not isinstance(data, dict):
        raise SystemExit("pnpm-lock.yaml: expected a mapping at root")

    lockfile_version = str(data.get("lockfileVersion", ""))
    if not lockfile_version.startswith("9"):
        print(
            f"warning: lockfileVersion={lockfile_version!r}, parser targets v9",
            file=sys.stderr,
        )

    raw_packages = data.get("packages") or {}
    raw_snapshots = data.get("snapshots") or {}
    raw_importers = data.get("importers") or {}

    packages: dict[str, dict] = {}
    for key, meta in raw_packages.items():
        parsed = parse_key(key)
        if parsed is None:
            print(f"skip packages key (unparseable): {key!r}", file=sys.stderr)
            continue
        name, version, _peer = parsed
        resolution = (meta or {}).get("resolution") or {}
        integrity = resolution.get("integrity")
        if not integrity:
            # tarball-by-path or git resolutions live in `resolution.tarball`
            # without integrity; out of scope for v0.
            continue
        url = resolution.get("tarball") or tarball_url(name, version)
        packages[f"{name}@{version}"] = {
            "name": name,
            "version": version,
            "url": url,
            "integrity": integrity,
            "hasBin": bool((meta or {}).get("hasBin", False)),
            "os": (meta or {}).get("os"),    # e.g. ["linux"] or None
            "cpu": (meta or {}).get("cpu"),   # e.g. ["x64"] or None
        }

    snapshots: dict[str, dict] = {}
    workspace_packages: list[str] = []
    for key, meta in raw_snapshots.items():
        parsed = parse_key(key)
        if parsed is None:
            print(f"skip snapshots key (unparseable): {key!r}", file=sys.stderr)
            continue
        name, version, _peer = parsed

        if is_workspace_ref(version):
            # workspace package — caller resolves to a path on disk.
            workspace_packages.append(key)
            snapshots[key] = {
                "name": name,
                "version": version,
                "package": None,
                "workspace": True,
                "deps": {},
                "optional": bool((meta or {}).get("optional", False)),
            }
            continue

        package_id = f"{name}@{version}"
        deps_combined: dict[str, str] = {}
        for k in ("dependencies", "optionalDependencies"):
            for dep_name, dep_value in ((meta or {}).get(k) or {}).items():
                import_name, snapshot_key = resolve_dep_key(dep_name, dep_value)
                deps_combined[import_name] = snapshot_key

        snapshots[key] = {
            "name": name,
            "version": version,
            "package": package_id,
            "workspace": False,
            "deps": deps_combined,
            "optional": bool((meta or {}).get("optional", False)),
        }

    importers: dict[str, dict] = {}
    for path, meta in raw_importers.items():
        importer_entry: dict[str, dict[str, str]] = {
            "deps": {},
            "devDeps": {},
            "optionalDeps": {},
        }
        for src, dst in (
            ("dependencies", "deps"),
            ("devDependencies", "devDeps"),
            ("optionalDependencies", "optionalDeps"),
        ):
            for dep_name, dep_meta in ((meta or {}).get(src) or {}).items():
                version_field = (dep_meta or {}).get("version")
                if not version_field:
                    continue
                _import_name, snapshot_key = resolve_dep_key(
                    dep_name, version_field
                )
                importer_entry[dst][dep_name] = snapshot_key
        importers[path] = importer_entry

    # --- patchedDependencies --------------------------------------------------
    # pnpm patches: the lockfile records which packages have patches and the
    # relative path to each patch file. We emit this so the extract layer can
    # apply them after tarball extraction.
    #
    # Lockfile shape:
    #   patchedDependencies:
    #     astro@6.1.10:
    #       hash: 0ade1ff...
    #       path: patches/astro@6.1.10.patch
    raw_patched = data.get("patchedDependencies") or {}
    patched_dependencies: dict[str, dict] = {}
    for pkg_key, patch_meta in raw_patched.items():
        if not patch_meta or not isinstance(patch_meta, dict):
            continue
        patch_path = patch_meta.get("path")
        patch_hash = patch_meta.get("hash", "")
        if patch_path:
            patched_dependencies[pkg_key] = {
                "path": patch_path,
                "hash": patch_hash,
            }

    out = {
        "lockfileVersion": lockfile_version,
        "packages": packages,
        "snapshots": snapshots,
        "importers": importers,
        "workspacePackages": sorted(set(workspace_packages)),
        "patchedDependencies": patched_dependencies,
    }
    print(json.dumps(out, sort_keys=True, indent=2))
    print(
        f"// packages={len(packages)} "
        f"snapshots={len(snapshots)} "
        f"importers={len(importers)} "
        f"workspaceRefs={len(workspace_packages)}"
        f"{f' patches={len(patched_dependencies)}' if patched_dependencies else ''}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "pnpm-lock.yaml")
