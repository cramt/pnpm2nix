# Build the shared .pnpm farm — the heart of the pnpm2nix pipeline.
#
# Lays out every non-workspace snapshot into a
# `.pnpm/<encoded-key>/node_modules/<pkg>` directory tree, matching pnpm's
# on-disk layout. Package *files* come from the extract layer; the farm adds
# the directory skeleton, hardlinks to extracted files, and relative dep
# symlinks.
#
# Build strategy:
#   1. Copy each unique package from the Nix store into a staging area ONCE.
#      Uses `cp --reflink=auto` so CoW filesystems (btrfs/ZFS) get instant
#      metadata-only copies instead of full data writes.
#   2. Make the staging area writable in one batched chmod pass.
#   3. Hardlink (`cp -al`) from staging into every snapshot position.
#      This works because both source and target are under $out (same mount).
#   4. Remove the staging area; file data persists via the hardlinks.
#
# Why not per-snapshot derivations?
#   npm allows circular dependencies (A→B→C→A). Nix derivations can't
#   reference each other cyclically — each derivation's hash depends on its
#   inputs. A monolithic farm avoids this by wiring all dep symlinks within
#   a single build.
#
# Platform filtering is handled upstream (workspace.nix); everything arriving
# here is already host-compatible.
{
  lib,
  runCommand,
  callPackage,
}:
parsed:
extracted:
let
  inherit (lib) filterAttrs concatStringsSep mapAttrsToList;
  inherit ((callPackage ./encode.nix {})) encodeKey;

  nonWorkspaceSnapshots =
    filterAttrs (_: snap: !(snap.workspace or false)) parsed.snapshots;

  # Unique package IDs referenced by non-workspace snapshots.
  usedPkgIds =
    lib.unique (mapAttrsToList (_: snap: snap.package) nonWorkspaceSnapshots);

  sanitizeId = id: builtins.replaceStrings ["/"] ["+"] id;

  # --- Stage 1: copy each unique package into $out/.p/ (staging) ---
  # --reflink=auto: near-instant on CoW filesystems, regular copy on ext4.
  stageLines = concatStringsSep "\n" (map (pkgId: let
    drv = extracted.${pkgId}
      or (throw "pnpm2nix: snapshot references unknown package '${pkgId}' (missing integrity?)");
    dir = sanitizeId pkgId;
  in ''
    cp --reflink=auto -a "${drv}" "$out/.p/${dir}"
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
      isScoped = lib.hasPrefix "@" depName;
      relPrefix = if isScoped then "../../../" else "../../";
      # For aliases the dep name differs from the target snapshot's package name.
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
    };
  } ''
    mkdir -p "$out/.pnpm" "$out/.p"

    # Stage 1: one copy per unique package into a staging area inside $out.
    ${stageLines}

    # Stage 1.5: batched chmod — one pass over the whole staging area instead
    # of per-directory. Needed because cp -a preserves read-only perms from
    # the Nix store, but cp -al (hardlink) requires writable directories.
    chmod -R u+w "$out/.p"

    # Stage 2: hardlink from staging into each snapshot position, then create
    # the relative dep symlinks that pnpm's node_modules layout requires.
    ${snapshotLines}

    # Stage 3: remove staging. Inodes persist via the hardlinks in stage 2.
    rm -rf "$out/.p"
  ''
