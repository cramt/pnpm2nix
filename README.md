# pnpm2nix

Pure-Nix builder for pnpm v9 monorepos. Turns `pnpm-lock.yaml` into
per-app Nix derivations without running `pnpm install` at build time.

## Why

`pnpm install` inside a Nix sandbox is fragile — it wants network, a
global store, and lifecycle scripts. This project reconstructs pnpm's
`node_modules/.pnpm` layout directly from the lockfile using only Nix
primitives (`fetchurl`, `runCommand`, hardlinks, symlinks).

### Key properties

- **No pnpm install at build time.** Packages are fetched individually
  via `fetchurl` with integrity hashes from the lockfile, then assembled
  into pnpm's virtual store layout.
- **Platform filtering.** Native binaries for foreign platforms (e.g.
  `@esbuild/win32-x64` on a linux build) are automatically excluded.
  Cuts the store size roughly in half for typical monorepos.
- **Hardlink staging.** When multiple snapshots share a package (peer
  resolution variants), files are hardlinked rather than copied. The
  entire `.pnpm/` tree is a single derivation — no per-snapshot
  intermediates.
- **Granular caching.** Fetch and extract derivations are keyed by
  `name@version`. Changing a peer dep rebuilds only the farm layout,
  not the download/extraction layers.
- **Source isolation.** Each app build only sees its own source tree.
  Touching app B doesn't invalidate app A's cache.

## Quick Start

### Flake input

```nix
{
  inputs = {
    pnpm2nix.url = "github:cramt/pnpm2nix";
    pnpm2nix.inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

### Basic usage

```nix
let
  pnpm2nix = inputs.pnpm2nix.lib.${system};

  workspace = pnpm2nix.mkPnpmWorkspace {
    workspace = ./.;
    apps = [
      { name = "web"; path = "apps/web"; }
      { name = "api"; path = "apps/api"; }
    ];
    packages = [ "packages/ui" "packages/utils" ];
    nodejs = pkgs.nodejs_22;
    pnpm = pkgs.pnpm;
  };
in {
  packages.web = workspace.apps.web;
  packages.api = workspace.apps.api;
}
```

## API

### `mkPnpmWorkspace`

The main entry point. Takes a workspace config and returns built apps.

```nix
pnpm2nix.mkPnpmWorkspace {
  # Required
  workspace = ./.;                    # Path to monorepo root
  apps = [                           # Apps to build
    {
      name = "my-app";               # Derivation name
      path = "apps/my-app";          # Relative path from workspace root
      # Optional per-app overrides:
      version = "1.0.0";             # Default: "0.0.0"
      script = "build";              # pnpm script to run (default: "build")
      distDir = "dist";              # Output directory (default: "dist")
      buildEnv = {};                 # Extra env vars for this app
      extraNativeBuildInputs = [];   # Extra build inputs for this app
    }
  ];
  nodejs = pkgs.nodejs_22;           # Node.js to use
  pnpm = pkgs.pnpm;                  # pnpm to use

  # Optional
  packages = [];                     # Shared workspace package paths
  pnpmLockYaml = workspace + "/pnpm-lock.yaml";
  buildEnv = {};                     # Env vars for all builds
  extraNativeBuildInputs = [];       # Extra inputs for all builds
  extraNodeModuleSources = [];       # Files to inject (e.g. .npmrc)
  noDevDependencies = false;         # Exclude devDependencies
}
```

**Returns:**

```nix
{
  apps = {
    my-app = <derivation>;   # Built app output
  };
  nodeModules = {
    "." = <derivation>;           # Root node_modules
    "apps/my-app" = <derivation>; # Per-importer node_modules
  };
  pnpmStore = <derivation>;  # The shared .pnpm farm
  passthru = {
    parsed; fetched; extracted; farm; importerNodeModules;
  };
}
```

### Lower-level API

Each pipeline stage is exposed for advanced use or debugging:

```nix
pnpm2nix.lockfile    # path → parsed attrset (IFD)
pnpm2nix.fetch       # parsed → { "pkg@ver" = <tarball>; ... }
pnpm2nix.extract     # parsed → fetched → { "pkg@ver" = <extracted>; ... }
pnpm2nix.farm        # parsed → extracted → <farm derivation>
pnpm2nix.nodeModules # parsed → farm → { mkImporterNodeModules, ... }
```

## Pipeline

```
pnpm-lock.yaml
      |
      v
 [lockfile]     IFD: Python/PyYAML parses YAML to JSON to Nix attrset
      |
      v
  [fetch]       One fetchurl per unique package (content-addressed)
      |
      v
 [extract]      Untar + patchShebangs per package
      |
      v
   [farm]       Single derivation: platform filter, hardlink staging,
      |         relative dep symlinks. This IS the .pnpm/ virtual store.
      v
[nodeModules]   Per-importer symlink layers (tiny, cheap to rebuild)
      |
      v
 [workspace]    Per-app stdenv.mkDerivation (pnpm run build)
```

## Platform Filtering

Packages with `os`/`cpu` fields in the lockfile (esbuild, rollup, sharp,
workerd, turbo, etc.) are automatically filtered by the build platform.
On linux-x64, darwin/windows/android/aix variants are excluded entirely —
not fetched, not extracted, not staged.

Supported platform mappings:

| Nix system | npm os | npm cpu |
|---|---|---|
| `x86_64-linux` | `linux` | `x64` |
| `aarch64-linux` | `linux` | `arm64` |
| `x86_64-darwin` | `darwin` | `x64` |
| `aarch64-darwin` | `darwin` | `arm64` |

Unknown systems fall back to including everything (no filtering).

## Requirements

- **pnpm-lock.yaml v9** (pnpm 9.x). Older lockfile versions are not
  supported.
- **Nix with flakes** enabled.
- The lockfile parser uses IFD (Import From Derivation), which requires
  Python 3 + PyYAML at eval time. These come from nixpkgs and are
  cached after first eval.

## Limitations

- **Lifecycle scripts** (`postinstall`, etc.) are not run. Packages like
  esbuild and sharp that ship prebuilt binaries work fine; packages that
  compile native code in postinstall will not.
- **Git/tarball dependencies** without integrity hashes are skipped.
  Only registry tarballs with `integrity` in the lockfile are supported.
- **Monolithic farm.** Any lockfile change rebuilds the farm derivation.
  Individual fetch/extract layers are cached, but the farm is all-or-nothing.

## How it Works

See [ARCHITECTURE.md](ARCHITECTURE.md) for a deep dive into the hardlink
staging approach, relative symlink scheme, scoped package handling,
and the full pipeline internals.

## License

MIT
