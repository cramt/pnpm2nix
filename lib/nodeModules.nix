# Per-importer node_modules — a thin layer of symlinks on top of the shared farm.
#
# Each importer (workspace root, app, shared package) gets a tiny derivation
# containing:
#   node_modules/.pnpm   → <farm>/.pnpm           (symlink into shared farm)
#   node_modules/<dep>   → .pnpm/<key>/.../<dep>   (top-level dep symlinks)
#   node_modules/.bin/*  → <farm>/.pnpm/.../<bin>  (bin entry symlinks)
#
# No package files are copied here — only symlinks and directory scaffolding.
# The farm (lib/farm.nix) owns all the actual file content.
{
  lib,
  runCommand,
  callPackage,
  jq,
}:
parsed:
farm:
let
  inherit (lib) concatStringsSep mapAttrsToList filterAttrs;
  inherit ((callPackage ./encode.nix {})) encodeKey;

  # Shell function injected into each importer's build script. Reads the `bin`
  # field from a package's package.json and creates symlinks in the target
  # .bin/ directory. Handles both `"bin": "path"` and `"bin": { "name": "path" }`
  # forms.
  populateBinForPkg = ''
    populate_bin_for_pkg() {
      local pkg_dir="$1"
      local bin_dir="$2"
      local pkg_json="$pkg_dir/package.json"
      [ -f "$pkg_json" ] || return 0

      local entries
      entries=$(${jq}/bin/jq -r '
        if (.bin | type) == "string"
          then "\((.name // "") | split("/") | last)\t\(.bin)"
        elif (.bin | type) == "object"
          then .bin | to_entries | map("\(.key)\t\(.value)") | .[]
        else empty
        end
      ' "$pkg_json" 2>/dev/null) || return 0

      [ -z "$entries" ] && return 0
      mkdir -p "$bin_dir"
      while IFS=$'\t' read -r bin_name bin_path; do
        [ -z "$bin_name" ] && continue
        [ -z "$bin_path" ] && continue
        bin_path="''${bin_path#./}"
        ln -sf "$pkg_dir/$bin_path" "$bin_dir/$bin_name"
      done <<<"$entries"
    }
  '';

  # Detect workspace-typed dependency keys (link:, file:, workspace: protocols).
  # These reference local workspace packages, not registry tarballs, and are
  # handled separately via relative symlinks to the source tree.
  isWorkspaceKey = key: let
    snap = parsed.snapshots.${key} or null;
    parts = lib.splitString "@" key;
    afterAt = lib.elemAt parts (lib.length parts - 1);
    isLinkLike =
      lib.hasPrefix "link:" afterAt
      || lib.hasPrefix "file:" afterAt
      || lib.hasPrefix "workspace:" afterAt;
  in
    (snap != null && (snap.workspace or false)) || isLinkLike;

  # Build one importer's node_modules derivation. The output is a directory of
  # symlinks: .pnpm points to the shared farm, top-level deps point into .pnpm,
  # and .bin entries point into the farm's snapshot directories.
  mkImporterNodeModules = {name, topLevelDeps}: let
    registryDirect = filterAttrs (_: k: !(isWorkspaceKey k)) topLevelDeps;
    workspaceDirect = filterAttrs (_: k: isWorkspaceKey k) topLevelDeps;

    # Single symlink connecting this importer's node_modules/.pnpm to the
    # shared farm. Walk-up module resolution from inside .pnpm/ finds sibling
    # snapshots as expected.
    pnpmFarmLink = ''
      ln -s "${farm}/.pnpm" "$out/node_modules/.pnpm"
    '';

    # Top-level dep links — visible as `node_modules/<dep>` to the importer.
    # They're relative, pointing through .pnpm/ into the snapshot directories.
    topLevelLinks = concatStringsSep "\n" (mapAttrsToList (depName: depKey: let
      isScoped = lib.hasPrefix "@" depName;
      relPrefix = if isScoped then "../.pnpm/" else ".pnpm/";
    in ''
      mkdir -p "$out/node_modules/$(dirname '${depName}')"
      ln -s "${relPrefix}${encodeKey depKey}/node_modules/${depName}" "$out/node_modules/${depName}"
    '') registryDirect);

    # .bin entries use absolute paths into the farm so they resolve regardless
    # of where the importer's node_modules is consumed.
    binLinkLines = concatStringsSep "\n" (mapAttrsToList (depName: depKey: ''
      populate_bin_for_pkg \
        "${farm}/.pnpm/${encodeKey depKey}/node_modules/${depName}" \
        "$out/node_modules/.bin"
    '') registryDirect);

  in
    runCommand "pnpm-node-modules-${lib.strings.sanitizeDerivationName name}" {
      passthru = {
        inherit topLevelDeps;
        workspaceDeps = workspaceDirect;
        registryDeps = registryDirect;
      };
    } ''
      ${populateBinForPkg}
      mkdir -p "$out/node_modules"
      ${pnpmFarmLink}
      ${topLevelLinks}
      ${binLinkLines}
    '';

in {
  inherit mkImporterNodeModules isWorkspaceKey encodeKey;
}
