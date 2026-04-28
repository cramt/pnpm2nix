# Build the shared .pnpm farm — the heart of the pnpm2nix pipeline.
#
# Lays out every non-workspace snapshot into a
# `.pnpm/<encoded-key>/node_modules/<pkg>` directory tree, matching pnpm's
# on-disk layout. Package *files* come from the extract layer; the farm adds
# the directory skeleton, hardlinks to extracted files, and relative dep
# symlinks.
#
# Optimization over the previous snapshot + farm two-stage approach:
#   1. Copy each unique package from the Nix store into a staging area ONCE.
#   2. Hardlink (`cp -al`) from staging into every snapshot position.
#      This works because both source and target are under $out (same mount).
#   3. Remove the staging area; file data persists via the hardlinks.
#
# Result: ~1x total package data written, down from ~3x. Zero intermediate
# snapshot derivations (previously one per snapshot).
{
  lib,
  runCommand,
  callPackage,
  stdenv,
}:
parsed:
extracted:
let
  inherit (lib) filterAttrs concatStringsSep mapAttrsToList;
  inherit ((callPackage ./encode.nix {})) encodeKey;

  # ---------------------------------------------------------------------------
  # Platform filtering: skip packages whose os/cpu fields don't match the build
  # host. Eliminates ~292 fetches+extracts on linux-x64 for a typical monorepo.
  # ---------------------------------------------------------------------------
  nixToNpmOs = {
    "x86_64-linux" = "linux";   "aarch64-linux" = "linux";
    "x86_64-darwin" = "darwin";  "aarch64-darwin" = "darwin";
  };
  nixToNpmCpu = {
    "x86_64-linux" = "x64";     "aarch64-linux" = "arm64";
    "x86_64-darwin" = "x64";    "aarch64-darwin" = "arm64";
  };
  system = stdenv.hostPlatform.system;
  npmOs = nixToNpmOs.${system} or null;
  npmCpu = nixToNpmCpu.${system} or null;

  # A package matches if it has no os/cpu restriction, or the restriction
  # includes the current platform. When the system is unknown (npmOs/npmCpu
  # are null), nothing is filtered — safe fallback.
  matchesPlatform = pkgId: let
    spec = parsed.packages.${pkgId} or {};
    osField = spec.os or null;
    cpuField = spec.cpu or null;
  in
    (osField == null || npmOs == null || builtins.elem npmOs osField)
    && (cpuField == null || npmCpu == null || builtins.elem npmCpu cpuField);

  nonWorkspaceSnapshots =
    filterAttrs (_: snap:
      !(snap.workspace or false)
      && matchesPlatform snap.package
    ) parsed.snapshots;

  # Unique package IDs referenced by non-workspace snapshots. Workspace-only
  # packages have no extract derivation and are handled by the importer layer.
  usedPkgIds =
    lib.unique (mapAttrsToList (_: snap: snap.package) nonWorkspaceSnapshots);

  # Replace `/` (illegal in filenames) for flat staging directory names.
  # Package IDs like `@babel/core@7.24.0` become `@babel+core@7.24.0`.
  sanitizeId = id: builtins.replaceStrings ["/"] ["+"] id;

  # --- Stage 1: copy each unique package from the store into $out/.p/ ---
  stageLines = concatStringsSep "\n" (map (pkgId: let
    drv = extracted.${pkgId}
      or (throw "pnpm2nix: snapshot references unknown package '${pkgId}' (missing integrity?)");
    dir = sanitizeId pkgId;
  in ''
    cp -a "${drv}" "$out/.p/${dir}"
    chmod -R u+w "$out/.p/${dir}"
  '') usedPkgIds);

  # --- Stage 2: hardlink package files + create dep symlinks per snapshot ---
  snapshotLines = concatStringsSep "\n" (mapAttrsToList (key: snap: let
    enc = encodeKey key;
    dir = sanitizeId snap.package;

    # Only link deps that resolve to another non-workspace snapshot. Workspace
    # deps are wired up by the importer layer (which knows the source paths).
    resolvedDeps =
      filterAttrs (_: depKey: nonWorkspaceSnapshots ? ${depKey}) snap.deps;

    depLinks = concatStringsSep "\n" (mapAttrsToList (depName: depKey: let
      # Scoped packages (@scope/name) sit one directory deeper, requiring an
      # extra `..` to escape back up to `.pnpm/`.
      isScoped = lib.hasPrefix "@" depName;
      relPrefix = if isScoped then "../../../" else "../../";
      # For aliases (e.g. h3-v2 → h3@2.0.1-rc.20), the dep is installed
      # under `depName` but the target snapshot's directory uses the real
      # package name. Look it up from the target snapshot.
      targetName = nonWorkspaceSnapshots.${depKey}.name;
    in ''
      mkdir -p "$out/.pnpm/${enc}/node_modules/$(dirname '${depName}')"
      ln -s "${relPrefix}${encodeKey depKey}/node_modules/${targetName}" \
            "$out/.pnpm/${enc}/node_modules/${depName}"
    '') resolvedDeps);

  in ''
    mkdir -p "$out/.pnpm/${enc}/node_modules/$(dirname '${snap.name}')"
    cp -al "$out/.p/${dir}" "$out/.pnpm/${enc}/node_modules/${snap.name}"
    ${depLinks}
  '') nonWorkspaceSnapshots);

in
  runCommand "pnpm-farm" {
    passthru = {
      snapshotCount = builtins.length (builtins.attrNames nonWorkspaceSnapshots);
      packageCount = builtins.length usedPkgIds;
      inherit system npmOs npmCpu;
    };
  } ''
    mkdir -p "$out/.pnpm" "$out/.p"

    # Stage 1: one real copy per unique package into a staging area inside $out.
    ${stageLines}

    # Stage 2: hardlink from staging into each snapshot position, then create
    # the relative dep symlinks that pnpm's node_modules layout requires.
    ${snapshotLines}

    # Stage 3: remove staging. Inodes persist via the hardlinks in stage 2.
    rm -rf "$out/.p"
  ''
