# pnpm2nix Architecture

Pure-Nix reconstruction of pnpm's `node_modules/.pnpm` layout from a
`pnpm-lock.yaml` v9 lockfile. Produces per-app build derivations for
monorepo workspaces without running `pnpm install` at build time.

## Pipeline Overview

```
pnpm-lock.yaml
      │
      ▼
┌──────────┐   IFD (Python/PyYAML) — also computes dep-graph SCCs
│ lockfile  │   YAML → JSON → Nix attrset
└────┬─────┘
     │  parsed: { packages, snapshots, importers, cycles, ... }
     ▼
┌──────────┐   one fetchurl per name@version
│  fetch    │   ~2,800 derivations (after platform filtering)
└────┬─────┘
     │  fetched: { "react@18.2.0" = /nix/store/...-react-18.2.0.tgz; ... }
     ▼
┌──────────┐   one runCommand per package (tar + patchShebangs)
│ extract   │   ~2,800 derivations
└────┬─────┘
     │  extracted: { "react@18.2.0" = /nix/store/...-pnpm-pkg-react-18.2.0/; ... }
     ▼
┌──────────┐   ★ one derivation per snapshot ("cell"), grouped by SCC
│  cells    │   package files + dep symlinks; absolute links between cells
└────┬─────┘
     │  cells: { "react@18.2.0" = /nix/store/...-pnpm-cell-react-18.2.0/; ... }
     ▼
┌──────────┐   pure-symlink layers: .pnpm/<key> → <cell>/<key>
│ compose   │   one per importer (pruned to its closure) + one full farm
└────┬─────┘
     │  builds in ~1s; the only layer that rebuilds on every lockfile change
     ▼
┌──────────────┐   one tiny derivation per importer (symlinks only)
│ nodeModules   │   ~29 derivations (root + apps + packages)
└────┬─────────┘
     ▼
┌──────────┐   one stdenv.mkDerivation per app
│ workspace │   12 derivations (example monorepo)
└──────────┘
```

## Cells: Per-Snapshot Derivations

Each snapshot gets its own derivation with the layout:

```
/nix/store/...-pnpm-cell-react-18.2.0/
├── react@18.2.0/
│   └── node_modules/
│       ├── react/            ← package files, copied from extract
│       └── scheduler → /nix/store/...-pnpm-cell-scheduler-0.23.0/scheduler@0.23.0/node_modules/scheduler
└── node_modules → /build/.p2n-hoist          (hoist fallback, see below)
```

### Why absolute symlinks between cells work

Node resolves modules by `realpath()`ing a file, then walking **up** from
that location looking for `node_modules/` directories. A file in cell A
realpaths to `/nix/store/…-cell-A/<enc>/node_modules/<pkg>/…`; the walk-up
finds cell A's own `node_modules/`, whose dep symlinks point (absolutely) at
other cells' store paths. Following one lands in the dep's cell, where the
same invariant holds recursively.

*Relative* links across cells would instead resolve against `/nix/store/`
and dangle — that constraint is what previously forced a monolithic farm
(one derivation copying every package into a shared tree, fully rebuilt on
any lockfile change).

### Cycles: SCC condensation

npm allows circular dependencies (`browserslist ↔ update-browserslist-db`);
Nix derivations can't reference each other cyclically. The parser computes
the strongly connected components of the snapshot dep graph (iterative
Tarjan) and emits the non-trivial ones as `parsed.cycles`. All members of a
cycle share one cell and link to each other *relatively* (they're physically
co-located, so relative links resolve within the cell). The SCC condensation
is a DAG, so absolute inter-cell references always terminate.

Real lockfiles have a handful of tiny cycles — the profiled monorepo has 10,
sized 2–6 members (babel core/helpers, es-abstract cluster, pg ↔ pg-pool).

### Caching behavior

Bumping a dependency rebuilds:
- its fetch + extract + cell (one small package copy each),
- the cells of its reverse-dependency ancestors (their symlink targets
  changed, so their hashes changed),
- the compose layers whose closure contains it (pure symlinks, ~1s).

Everything else stays cached forever. Cells rebuild in parallel and each
copies exactly one package, so even a worst-case bump (a package like
`tslib` with ~340 transitive dependents) moves a few hundred MB, not the
whole farm.

## Compose Layers

A compose layer is a derivation of nothing but symlinks:

```
$out/.pnpm/
├── react@18.2.0 → /nix/store/...-pnpm-cell-react-18.2.0/react@18.2.0
├── ...one per snapshot in scope...
└── node_modules/                 ← hoist: one symlink per unique package name
    └── react → ../react@18.2.0/node_modules/react
```

**Each importer gets its own compose layer, pruned to the transitive closure
of its top-level deps** (computed with `builtins.genericClosure`). This is
what makes caching *per-app*: a lockfile change that doesn't touch an app's
closure leaves that app's compose — and therefore its node_modules and its
build — fully cached. In the profiled monorepo, ~45% of snapshots are
exclusive to a single app.

The classic full farm (every snapshot) is still exposed as `pnpmStore`.

## The Hoist Fallback

pnpm's default `hoistPattern: ['*']` gives every package a last-resort
lookup at `.pnpm/node_modules/` for dependencies it uses but never declared.
This is load-bearing in the wild: `nitro-opentelemetry` requires
`nitropack/kit` at runtime without declaring it, TypeScript resolves
`@types/*` for transitive deps by ancestor-walking, etc. In the monolithic
farm this worked by physical co-location; a cell's walk-up can't reach any
compose layer.

Instead, every cell root carries a **dangling symlink**:

```
<cell>/node_modules → /build/.p2n-hoist
```

Node's walk-up from `<cell>/<enc>/node_modules/<pkg>/…` consults
`<cell>/node_modules/` right after the snapshot's declared deps. Inside an
app build sandbox, `workspace.nix` materializes `/build/.p2n-hoist` as a
symlink to that app's hoist compose (`.pnpm/node_modules/` over everything
reachable from every importer set up in the sandbox).

Properties:
- The link contains **no store path**, so cells stay byte-identical across
  lockfile changes — no rebuild cascade through the fallback.
- Each app resolves hoisted names against its own closure — pnpm's
  global-hoist semantics, scoped per app.
- Outside a sandbox the link dangles, which means "no hoist" — the same as
  pnpm with hoisting disabled.
- Assumes the standard sandbox build dir `/build` (Nix's default
  `build-dir`/`sandbox-build-dir`). Non-sandboxed builds degrade to
  "no hoist".

## Importer Node Modules

Each workspace importer (root, apps, packages) gets a tiny derivation
containing only symlinks:

```
node_modules/
├── .pnpm → /nix/store/...-pnpm-farm-<importer>/.pnpm   (its pruned compose)
├── react → .pnpm/<key>/node_modules/react              (relative, through .pnpm)
└── .bin/
    └── vite → /nix/store/...-pnpm-farm-<importer>/.pnpm/<key>/.../vite  (absolute)
```

Workspace deps (`link:`/`file:`/`workspace:`) are wired up as relative
symlinks to the source tree during the app build, not here.

## App Build Flow

Each app's `stdenv.mkDerivation`:

1. **Source isolation**: `lib.fileset.difference` excludes other apps'
   directories from the source tree — touching app B doesn't invalidate
   app A's build — and `pnpm-lock.yaml` itself, which is consumed at eval
   time only. Without that exclusion every lockfile change would rebuild
   every app through `src`, defeating per-app dependency caching. Custom
   `appSrc` filters must exclude the lockfile themselves to get the same
   benefit.

2. **Configure phase**:
   - Points `/build/.p2n-hoist` at the app's hoist compose
   - Injects `.npmrc` with sandbox-required settings
   - For each importer (root + packages + this app):
     - `cp -aT` the importer node_modules (copies symlinks, not data)
     - Creates workspace dep symlinks (relative to source tree)

3. **Build phase**: `pnpm --filter ./<app> run build`

4. **Install phase**: copies `<app>/<distDir>/` to `$out/`

## Lockfile Schema

The Python parser (`lib/parser.py`) converts `pnpm-lock.yaml` v9 into:

```json
{
  "packages": {
    "<name>@<version>": {
      "name": "react", "version": "18.2.0",
      "url": "https://registry.npmjs.org/react/-/react-18.2.0.tgz",
      "integrity": "sha512-...", "hasBin": false,
      "os": ["linux"], "cpu": ["x64"]
    }
  },
  "snapshots": {
    "<name>@<version>(<peers>)": {
      "name": "react", "version": "18.2.0", "package": "react@18.2.0",
      "workspace": false, "deps": { "<depName>": "<depKey>" },
      "optional": false
    }
  },
  "importers": {
    ".": { "deps": {}, "devDeps": {}, "optionalDeps": {} }
  },
  "workspacePackages": ["@repo/utils@link:../../packages/utils"],
  "cycles": [ ["browserslist@4.28.4", "update-browserslist-db@1.2.3(...)"] ],
  "patchedDependencies": { "<name>@<version>": { "path": "...", "hash": "..." } }
}
```

**packages vs. snapshots**: A package is `react@18.2.0` — one tarball.
A snapshot is `react@18.2.0(react-dom@18.2.0)` — a specific peer
resolution. Two snapshots can share the same package (tarball) but have
different dependency graphs.

## Key Encoding

Snapshot keys can be very long (e.g., 953 chars for deck.gl with deep
peer nesting). `lib/encode.nix` mirrors pnpm's `depPathToFilename`:

- Replace path-illegal characters (`/ : * ? " < > | \`) with `+`
- If result exceeds 120 chars: truncate to 93 chars + `_` + 26-char
  sha256 prefix

This encoding is used as the directory name under `.pnpm/` and inside cells.

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
  pnpm = pkgs.pnpm;              # optional; defaults from packageManager field
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
  pnpmStore = <derivation>;   # full compose farm over every snapshot
  pnpm = <derivation>;        # the resolved pnpm
  passthru = { parsed; fetched; extracted; farmLib; importerNodeModules; farm; };
}
```

### Lower-Level Handles

For non-workspace use or debugging:

```nix
pnpm2nix.lockfile  # pnpmLockYaml → parsed
pnpm2nix.fetch     # parsed → fetched
pnpm2nix.extract   # parsed → fetched → workspaceSrc → extracted
pnpm2nix.farm      # parsed → extracted → { cells, compose, composeFor, closureFor, ... }
pnpm2nix.nodeModules  # parsed → farmLib → { mkImporterNodeModules, ... }
```

## Known Limitations

1. **Lifecycle scripts**: Packages with `postinstall` scripts (esbuild,
   sharp, workerd) are extracted but their lifecycle scripts are NOT run.
   The `onlyBuiltDependencies` field in `pnpm-workspace.yaml` is not yet
   honored. Packages that need native binaries from postinstall will have
   broken binaries.

2. **Reverse-dependency cascade**: bumping a package rebuilds the cells of
   everything that transitively depends on it (absolute symlinks embed the
   dep cell's hash). Each rebuild is one small package copy and they run in
   parallel, but a very popular leaf (tslib, ms, debug) touches a few
   hundred cells.

3. **IFD cold start**: The lockfile parser uses Import From Derivation
   (Python + PyYAML). On a fresh machine, the first `nix eval` must build
   the Python environment before evaluation can proceed.

4. **Git/tarball-by-path dependencies**: Only registry tarballs with
   `integrity` hashes are supported. Git dependencies and `tarball:`
   resolutions without integrity have no hash to fetch content-addressed;
   the parser fails loudly with a clear error rather than silently dropping
   them.

5. **Node bumps rebuild the farm**: `patchShebangs` bakes the concrete Node
   store path into every extracted package with a shebang bin, so a `nodejs`
   change invalidates those extracts and cascades through cells, composes,
   and apps. Lockfile-only changes don't.

6. **Hoist fallback needs the sandbox**: the `/build/.p2n-hoist` mechanism
   assumes builds run in the standard Nix sandbox (build dir `/build`).
