# The farm layer: per-snapshot "cell" derivations + thin compose layers.
#
# Previous design: one monolithic derivation copying every package into a
# shared `.pnpm/` tree. Any lockfile change rebuilt the whole thing (~GBs of
# writes on non-CoW filesystems). This design splits the farm so a dep change
# only rebuilds the affected snapshot chain:
#
#   cell    — one derivation per snapshot (or per dependency cycle, see below).
#             Layout: $out/<encoded-key>/node_modules/<pkg> with the package
#             files copied from the extract layer, plus dep symlinks.
#   compose — a derivation of nothing but symlinks:
#             .pnpm/<encoded-key> → <cell>/<encoded-key>, plus the hoisted
#             .pnpm/node_modules/ layer. Rebuilds on every lockfile change,
#             but builds in about a second.
#
# Why absolute symlinks between cells work (and relative ones wouldn't):
# Node resolves modules by realpath()ing a file, then walking *up* looking for
# node_modules/. A file in cell A realpaths to
# /nix/store/…-cell-A/<enc>/node_modules/<pkg>/…; the walk-up finds cell A's
# own node_modules/ directory, whose dep symlinks point (absolutely) at other
# cells' store paths. Following one lands in the dep's cell, where the same
# invariant holds recursively. Relative links across cells would instead
# resolve against /nix/store/ and dangle — that constraint is what previously
# forced a monolithic farm.
#
# Cycles: npm allows circular dependencies (browserslist ↔
# update-browserslist-db), and Nix derivations can't reference each other
# cyclically. The parser emits the non-trivial SCCs of the snapshot graph
# (`parsed.cycles`); all members of a cycle share one cell and link to each
# other *relatively* (they're physically co-located, so relative links
# resolve). The SCC condensation is a DAG, so absolute inter-cell references
# always terminate. Real lockfiles have a handful of 2–6 member cycles.
#
# The hoist fallback: pnpm's default hoistPattern ['*'] gives every package
# a last-resort lookup at .pnpm/node_modules/ for deps it uses but never
# declared (nitro-opentelemetry requiring nitropack/kit, TypeScript's
# ancestor-walking @types resolution). In the monolithic farm that worked
# via physical co-location; a cell can't reach its consumer's compose layer
# by walk-up. Instead each cell root carries a *dangling* symlink
#   $out/node_modules → /build/.p2n-hoist
# Node's walk-up from /nix/store/…-cell/<enc>/node_modules/<pkg>/… consults
# the cell root's node_modules/ right after the snapshot's own deps; inside
# an app build sandbox, workspace.nix points /build/.p2n-hoist at that app's
# compose hoist dir. The link contains no store path, so cells stay
# byte-identical across lockfile changes — no rebuild cascade through the
# fallback — and each app resolves hoisted names against its own closure,
# which is pnpm's global-hoist semantics scoped per importer. Outside a
# sandbox the link dangles, which simply means "no hoist", the same as
# running pnpm with hoist disabled.
#
# Caching behavior: bumping a dep rebuilds its fetch + extract + cell, plus
# the cells of its reverse-dependency ancestors (their symlink targets
# changed) and the compose layer. Each cell rebuild copies one package.
# Unaffected cells are cached forever.
#
# Platform filtering is handled upstream (workspace.nix); everything arriving
# here is already host-compatible. Filtering can drop members from a cycle
# cell — harmless, since removing nodes never introduces new cycles.
{
  lib,
  runCommand,
  callPackage,
}:
parsed:
extracted:
let
  inherit (lib) filterAttrs concatStringsSep mapAttrsToList optionalString hasPrefix;
  inherit ((callPackage ./encode.nix {})) encodeKey;

  nonWorkspaceSnapshots =
    filterAttrs (_: snap: !(snap.workspace or false)) parsed.snapshots;

  # Cycle members share a cell whose id is the first (sorted) member key;
  # every other snapshot is a singleton cell keyed by its own snapshot key.
  cycleCellOf = builtins.listToAttrs (lib.flatten (map (members: let
    id = builtins.head members;
  in map (k: { name = k; value = id; }) members) (parsed.cycles or [])));

  cellIdOf = key: cycleCellOf.${key} or key;

  # cellId → [member snapshot keys], post platform filtering.
  cellMembers = lib.groupBy cellIdOf (builtins.attrNames nonWorkspaceSnapshots);

  # Recursive: dep link targets reference sibling cells. Terminates because
  # the SCC condensation is a DAG.
  cells = builtins.mapAttrs mkCell cellMembers;

  mkCell = cellId: memberKeys: let
    firstSnap = nonWorkspaceSnapshots.${builtins.head memberKeys};
    isCycle = builtins.length memberKeys > 1;
    cellName = lib.strings.sanitizeDerivationName
      ("pnpm-cell-${firstSnap.name}-${firstSnap.version}"
        + optionalString isCycle "-cycle${toString (builtins.length memberKeys)}");

    memberBlock = key: let
      snap = nonWorkspaceSnapshots.${key};
      enc = encodeKey key;
      drv = extracted.${snap.package}
        or (throw "pnpm2nix: snapshot references unknown package '${snap.package}' (missing integrity?)");

      # Only link deps that resolve to another non-workspace snapshot.
      # Workspace deps are wired up by the importer layer.
      resolvedDeps =
        filterAttrs (_: depKey: nonWorkspaceSnapshots ? ${depKey}) snap.deps;

      depLinks = concatStringsSep "\n" (mapAttrsToList (depName: depKey: let
        # For aliases the dep name differs from the target's package name.
        targetName = nonWorkspaceSnapshots.${depKey}.name;
        encDep = encodeKey depKey;
        # Scoped dep symlinks sit one directory deeper, so they need an
        # extra `..` to escape back to the cell root.
        relPrefix = if hasPrefix "@" depName then "../../../" else "../../";
        target =
          if cellIdOf depKey == cellId
          then "${relPrefix}${encDep}/node_modules/${targetName}"
          else "${cells.${cellIdOf depKey}}/${encDep}/node_modules/${targetName}";
      in ''
        mkdir -p "$out/${enc}/node_modules/$(dirname '${depName}')"
        ln -s "${target}" "$out/${enc}/node_modules/${depName}"
      '') resolvedDeps);
    in ''
      mkdir -p "$out/${enc}/node_modules/$(dirname '${snap.name}')"
      cp --reflink=auto -a "${drv}" "$out/${enc}/node_modules/${snap.name}"
      ${depLinks}
    '';
  in
    runCommand cellName {
      passthru = { snapshotKeys = memberKeys; };
    } (concatStringsSep "\n" (map memberBlock memberKeys) + ''

      # Hoist fallback (see header comment). Deliberately dangling: resolves
      # only inside an app build sandbox that materializes /build/.p2n-hoist.
      ln -s /build/.p2n-hoist "$out/node_modules"
    '');

  # Transitive snapshot closure of a set of root snapshot keys. Used to build
  # per-importer compose layers containing only what that importer can reach.
  closureFor = rootKeys: map (x: x.key) (builtins.genericClosure {
    startSet = map (k: { key = k; })
      (builtins.filter (k: nonWorkspaceSnapshots ? ${k}) rootKeys);
    operator = item: map (k: { key = k; })
      (builtins.filter (k: nonWorkspaceSnapshots ? ${k})
        (builtins.attrValues nonWorkspaceSnapshots.${item.key}.deps));
  });

  # A compose layer: `.pnpm/<enc>` symlinks into cells + the hoisted
  # `.pnpm/node_modules/` layer (pnpm's default hoistPattern ['*'] — one
  # symlink per unique package name, needed by TypeScript's ancestor-walking
  # @types resolution and other undeclared-dependency lookups rooted at the
  # importer).
  mkCompose = { name ? "pnpm-farm", snapshotKeys }: let
    keys = builtins.filter (k: nonWorkspaceSnapshots ? ${k}) snapshotKeys;

    snapLines = concatStringsSep "\n" (map (key: let
      enc = encodeKey key;
    in ''
      ln -s "${cells.${cellIdOf key}}/${enc}" "$out/.pnpm/${enc}"
    '') keys);

    # One representative snapshot per package name; last-write-wins is fine.
    nameToSnapshot = builtins.foldl' (acc: key:
      acc // { ${nonWorkspaceSnapshots.${key}.name} = key; }) {} keys;

    hoistLines = concatStringsSep "\n" (mapAttrsToList (pkgName: snapKey: let
      relPrefix = if hasPrefix "@" pkgName then "../../" else "../";
      enc = encodeKey snapKey;
    in ''
      mkdir -p "$out/.pnpm/node_modules/$(dirname '${pkgName}')"
      ln -s "${relPrefix}${enc}/node_modules/${pkgName}" \
            "$out/.pnpm/node_modules/${pkgName}"
    '') nameToSnapshot);
  in
    runCommand name {
      passthru = {
        snapshotCount = builtins.length keys;
        hoistedCount = builtins.length (builtins.attrNames nameToSnapshot);
      };
    } ''
      mkdir -p "$out/.pnpm/node_modules"
      ${snapLines}
      ${hoistLines}
    '';

  # Full compose over every snapshot — the classic "the farm" output,
  # exposed as `pnpmStore`. Importers use pruned per-closure composes
  # instead, so an app only rebuilds when its own dependency closure changes.
  compose = mkCompose {
    name = "pnpm-farm";
    snapshotKeys = builtins.attrNames nonWorkspaceSnapshots;
  };
in {
  inherit cells cellIdOf closureFor mkCompose compose;
  composeFor = name: rootKeys: mkCompose {
    inherit name;
    snapshotKeys = closureFor rootKeys;
  };
  passthru = {
    cellCount = builtins.length (builtins.attrNames cellMembers);
    cycleCount = builtins.length (parsed.cycles or []);
    snapshotCount = builtins.length (builtins.attrNames nonWorkspaceSnapshots);
  };
}
