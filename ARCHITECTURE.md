# pnpm2nix Architecture

Pure-Nix reconstruction of pnpm's `node_modules/.pnpm` layout from a
`pnpm-lock.yaml` v9 lockfile. Produces per-app build derivations for
monorepo workspaces without running `pnpm install` at build time.

## Pipeline Overview

```
pnpm-lock.yaml
      │
      ▼
┌──────────┐   IFD (Python/PyYAML)
│ lockfile  │   YAML → JSON → Nix attrset
└────┬─────┘
     │  parsed: { packages, snapshots, importers, workspacePackages }
     ▼
┌──────────┐   one fetchurl per name@version
│  fetch    │   ~2,042 derivations (after platform filtering)
└────┬─────┘
     │  fetched: { "react@18.2.0" = /nix/store/...-react-18.2.0.tgz; ... }
     ▼
┌──────────┐   one runCommand per package (tar + patchShebangs)
│ extract   │   ~2,042 derivations
└────┬─────┘
     │  extracted: { "react@18.2.0" = /nix/store/...-pnpm-pkg-react-18.2.0/; ... }
     ▼
┌──────────┐   ★ SINGLE derivation — the key optimization
│   farm    │   platform filter → hardlink staging → relative dep symlinks
└────┬─────┘
     │  farm: /nix/store/...-pnpm-farm/.pnpm/<key>/node_modules/<pkg>/
     ▼
┌──────────────┐   one tiny derivation per importer (symlinks only)
│ nodeModules   │   20 derivations (root + apps + packages)
└────┬─────────┘
     │  importerNodeModules: { "." = ...; "apps/foo" = ...; }
     ▼
┌──────────┐   one stdenv.mkDerivation per app
│ workspace │   8 derivations (example monorepo)
└──────────┘
     │  { apps.foo = /nix/store/...-foo/; ... }
```

## The Farm: Platform Filtering + Hardlink Staging

The farm is the core innovation. Previous versions used two intermediate
stages (snapshot + shared farm), each copying all package files — resulting
in ~3× the total package data written to disk. The new farm collapses this
into a single derivation with ~1× writes.

### Platform Filtering

Many npm packages ship platform-specific native binaries (esbuild, rollup,
sharp, workerd, turbo, etc.). A typical lockfile contains variants for every
platform: linux-x64, linux-arm64, darwin-x64, darwin-arm64, windows-x64, etc.

The lockfile's `packages` section carries `os` and `cpu` arrays on these
entries. The farm maps `stdenv.hostPlatform.system` to npm's os/cpu names
and filters out snapshots whose package doesn't match.

For a monorepo with 2,334 packages, building on linux-x64:
- 320 packages have os/cpu restrictions
- 292 are for other platforms (darwin, windows, android, etc.)
- After filtering: 2,042 packages, 2,066 snapshots
- Farm size drops from ~5.9 GB to ~2.5 GB (~58% reduction)

Nix laziness handles the rest: since `fetch` and `extract` produce attrsets
of derivations, any packages not referenced by the filtered farm are simply
never built. No changes needed to the fetch/extract layers.

### Why We Can't Just Symlink

Node.js uses `realpath()` to resolve the actual filesystem location of a
module, then walks **up** from that location looking for `node_modules/`
directories. If we symlinked package directories to Nix store paths,
`realpath()` would jump into `/nix/store/xxx-extracted/`, and walk-up
resolution would look for `node_modules/` inside the store — failing to
find the dep symlinks that sit alongside the package in `.pnpm/`.

The package files must physically exist at their position within the
`.pnpm/<key>/node_modules/<name>/` tree. Hardlinks achieve this without
duplicating data.

### The Three Stages

```
$out/
├── .p/                          ← staging area (temporary)
│   ├── react@18.2.0/           ← real copy from store
│   ├── @babel+core@7.24.0/     ← real copy from store
│   └── ...                     ← 2,334 packages
│
└── .pnpm/                       ← final layout
    ├── react@18.2.0/
    │   └── node_modules/
    │       ├── react/           ← hardlinks to .p/react@18.2.0/*
    │       └── scheduler → ../../scheduler@0.23.0/node_modules/scheduler
    │
    └── react@18.2.0(react-dom@18.2.0)/
        └── node_modules/
            ├── react/           ← hardlinks to SAME inodes as above
            └── react-dom → ../../react-dom@18.2.0(...)/node_modules/react-dom
```

**Stage 1** — Copy each unique package from the Nix store into `$out/.p/`.
This is the only real file copy. We `chmod -R u+w` so the staging area
is writable (needed for cleanup in stage 3).

**Stage 2** — For each snapshot, `cp -al` (hardlink) from the staging area
into `$out/.pnpm/<key>/node_modules/<name>/`. Since both source and target
are under `$out`, they're on the same filesystem — hardlinks work. Then
create the relative dep symlinks.

**Stage 3** — `rm -rf $out/.p`. The file inodes persist because the
hardlinks in `.pnpm/` still reference them. Only directory entries are freed.

### Disk I/O Comparison

| Approach | Real file copies | Derivation count |
|----------|-----------------|-----------------|
| Old (snapshot + farm) | ~3× package data | 2,358 snapshots + 1 farm |
| New (hardlink farm) | ~1× package data | 1 farm |

For a monorepo with ~2,300 packages totaling ~1.5 GB of extracted data,
this saves ~3 GB of disk writes and eliminates 2,358 derivation builds
(each with Nix sandbox setup overhead).

## Relative Symlinks: Avoiding Hash Cycles

Dependency links between snapshots use **relative** paths:

```
.pnpm/<keyA>/node_modules/<depB> → ../../<keyB>/node_modules/<depB>
```

This is critical. If we used absolute Nix store paths, snapshot A's output
would contain snapshot B's hash, and B might contain A's hash (circular
deps like `browserslist ↔ update-browserslist-db`). This creates an
infinite recursion during Nix evaluation.

Relative paths break the cycle: snapshot A's content doesn't reference B's
hash at all. The paths only resolve correctly when all snapshots are
co-located under a shared `.pnpm/` directory — which is exactly what the
farm provides.

### Scoped Package Depth

Unscoped packages sit at `.pnpm/<key>/node_modules/<name>`, so the
symlink needs `../../<depKey>/...` (two levels up: past `<name>`, past
`node_modules`).

Scoped packages sit at `.pnpm/<key>/node_modules/@scope/<name>`, one
level deeper, so the symlink needs `../../../<depKey>/...`.

## Importer Node Modules

Each workspace importer (root, apps, packages) gets a tiny derivation
containing only symlinks:

```
node_modules/
├── .pnpm → /nix/store/...-pnpm-farm/.pnpm     (into the shared farm)
├── react → .pnpm/<key>/node_modules/react       (relative, through .pnpm)
├── @repo/utils → ../packages/utils              (workspace dep, relative)
└── .bin/
    ├── tsc → /nix/store/...-pnpm-farm/.pnpm/<key>/.../tsc   (absolute)
    └── vite → /nix/store/...-pnpm-farm/.pnpm/<key>/.../vite  (absolute)
```

- **`.pnpm`**: symlink to the farm. Walk-up resolution from inside
  `.pnpm/` works because Node follows the symlink into the farm.
- **Top-level deps**: relative symlinks through `.pnpm/` into snapshot
  directories.
- **Workspace deps**: relative symlinks to the source tree (wired up
  during the app build, not in the importer derivation). Scoped workspace
  deps (e.g. `@repo/logging`) need an extra `..` because the symlink sits
  one directory deeper (`node_modules/@scope/name` vs `node_modules/name`).
- **`.bin/`**: absolute symlinks into the farm. Bin scripts need absolute
  paths so `realpath` stays within the farm's `.pnpm/` tree for correct
  walk-up resolution.

## App Build Flow

Each app's `stdenv.mkDerivation`:

1. **Source isolation**: `lib.fileset.difference` excludes other apps'
   directories from the source tree. Touching app B doesn't invalidate
   app A's build.

2. **Configure phase**:
   - Injects `.npmrc` with sandbox-required settings
   - For each importer (root + packages + this app):
     - `cp -aT` the importer node_modules (copies symlinks, not data)
     - `chmod -R u+w` (only affects directory entries, not farm)
     - Creates workspace dep symlinks (relative to source tree)

3. **Build phase**: `pnpm --filter ./<app> run build`

4. **Install phase**: copies `<app>/<distDir>/` to `$out/`

## Lockfile Schema

The Python parser (`lib/parser.py`) converts `pnpm-lock.yaml` v9 into:

```json
{
  "packages": {
    "<name>@<version>": {
      "name": "react",
      "version": "18.2.0",
      "url": "https://registry.npmjs.org/react/-/react-18.2.0.tgz",
      "integrity": "sha512-...",
      "hasBin": false,
      "os": ["linux"],
      "cpu": ["x64"]
    }
  },
  "snapshots": {
    "<name>@<version>(<peers>)": {
      "name": "react",
      "version": "18.2.0",
      "package": "react@18.2.0",
      "workspace": false,
      "deps": { "<depName>": "<depKey>" },
      "optional": false
    }
  },
  "importers": {
    ".": { "deps": {}, "devDeps": {}, "optionalDeps": {} },
    "apps/foo": { "deps": {}, "devDeps": {}, "optionalDeps": {} }
  },
  "workspacePackages": ["@repo/utils@link:../../packages/utils"]
}
```

**packages vs. snapshots**: A package is `react@18.2.0` — one tarball.
A snapshot is `react@18.2.0(react-dom@18.2.0)` — a specific peer
resolution. Two snapshots can share the same package (tarball) but have
different dependency graphs. This split means a peer-dep change only
rebuilds the affected snapshots, not the fetch/extract layers.

## Key Encoding

Snapshot keys can be very long (e.g., 953 chars for deck.gl with deep
peer nesting). `lib/encode.nix` mirrors pnpm's `depPathToFilename`:

- Replace path-illegal characters (`/ : * ? " < > | \`) with `+`
- If result exceeds 120 chars: truncate to 93 chars + `_` + 26-char
  sha256 prefix

This encoding is used as the directory name under `.pnpm/`.

## API

### `mkPnpmWorkspace`

```nix
pnpm2nix.mkPnpmWorkspace {
  workspace = ./.;               # path to monorepo root
  apps = [                       # list of apps to build
    { name = "foo"; path = "apps/foo"; }
    { name = "bar"; path = "apps/bar";
      extraNativeBuildInputs = [ pkgs.wrangler ]; }
  ];
  packages = [ "packages/utils" "packages/ui" ];  # shared workspace packages
  nodejs = pkgs.nodejs_22;
  pnpm = pkgs.pnpm;
  buildEnv = { API_KEY = "..."; };                 # env vars for all builds
  extraNodeModuleSources = [                       # injected files
    { name = ".npmrc"; value = pkgs.writeText "npmrc" "..."; }
  ];
  noDevDependencies = false;     # exclude devDependencies from importers
}
```

Returns:

```nix
{
  apps = { foo = <derivation>; bar = <derivation>; };
  nodeModules = { "." = <derivation>; "apps/foo" = <derivation>; ... };
  pnpmStore = <derivation>;   # the farm
  passthru = { parsed; fetched; extracted; farm; importerNodeModules; };
}
```

### Lower-Level Handles

For non-workspace use or debugging:

```nix
pnpm2nix.lockfile  # pnpmLockYaml → parsed
pnpm2nix.fetch     # parsed → fetched
pnpm2nix.extract   # parsed → fetched → extracted
pnpm2nix.farm      # parsed → extracted → farm
pnpm2nix.nodeModules  # parsed → farm → { mkImporterNodeModules, ... }
```

## Known Limitations

1. **Lifecycle scripts**: Packages with `postinstall` scripts (esbuild,
   sharp, workerd) are extracted but their lifecycle scripts are NOT run.
   The `onlyBuiltDependencies` field in `pnpm-workspace.yaml` is not yet
   honored. Packages that need native binaries from postinstall will have
   broken binaries.

2. **Monolithic farm rebuild**: Any lockfile change that adds, removes, or
   modifies a package rebuilds the entire farm derivation. Individual
   fetch/extract derivations are cached, but the farm is all-or-nothing.

3. **IFD cold start**: The lockfile parser uses Import From Derivation
   (Python + PyYAML). On a fresh machine, the first `nix eval` must build
   the Python environment before evaluation can proceed.

4. **Git/tarball-by-path dependencies**: Only registry tarballs with
   `integrity` hashes are supported. Git dependencies and `tarball:`
   resolutions without integrity are skipped.
