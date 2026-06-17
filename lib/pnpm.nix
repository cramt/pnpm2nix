# pnpm derivation builder + helpers to derive the correct pnpm version
# from a workspace's `package.json` "packageManager" field.
#
# Source: npm tarball (cross-platform, ~3MB). The tarball's SRI integrity
# hash is read from ../pnpm-versions.json, which is maintained by
# scripts/update-pnpm-versions.mjs.
{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  nodejs,
}: let
  versionsFile = ../pnpm-versions.json;
  versions = builtins.fromJSON (builtins.readFile versionsFile);

  # Parse "pnpm@10.5.2" or "pnpm@10.5.2+sha512.<base64>" → { name; version; }.
  # Returns null if the field is missing or doesn't match.
  parsePackageManager = field:
    if field == null
    then null
    else let
      m = builtins.match "([a-z]+)@([^+]+)(\\+.+)?" field;
    in
      if m == null
      then null
      else {
        name = builtins.elemAt m 0;
        version = builtins.elemAt m 1;
      };

  # Read packageManager from a workspace's package.json.
  # workspace may be a path or a string; package.json must exist.
  readPackageManager = workspace: let
    pkgJsonPath = workspace + "/package.json";
    pkgJson = builtins.fromJSON (builtins.readFile pkgJsonPath);
    pmField = pkgJson.packageManager or null;
  in
    parsePackageManager pmField;

  # Build a pnpm derivation for a specific version. The npm tarball is the
  # same across platforms; we just wrap node to execute bin/pnpm.cjs.
  mkPnpm = {
    version,
    hash,
    nodejs,
  }:
    stdenv.mkDerivation {
      pname = "pnpm";
      inherit version;
      src = fetchurl {
        url = "https://registry.npmjs.org/pnpm/-/pnpm-${version}.tgz";
        inherit hash;
      };
      nativeBuildInputs = [makeWrapper];
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out/{bin,libexec/pnpm}
        cp -r . $out/libexec/pnpm
        makeWrapper ${nodejs}/bin/node $out/bin/pnpm \
          --add-flags $out/libexec/pnpm/bin/pnpm.cjs
        if [ -f $out/libexec/pnpm/bin/pnpx.cjs ]; then
          makeWrapper ${nodejs}/bin/node $out/bin/pnpx \
            --add-flags $out/libexec/pnpm/bin/pnpx.cjs
        fi
        runHook postInstall
      '';

      meta = {
        description = "pnpm ${version} (built from npm tarball)";
        homepage = "https://pnpm.io";
        license = lib.licenses.mit;
      };
    };

  # Derive pnpm from a workspace's packageManager field.
  # Throws with an actionable message if:
  #   - packageManager is missing
  #   - packageManager isn't pnpm@...
  #   - the version isn't in pnpm-versions.json (user must run the updater)
  pnpmFromPackageManager = {
    workspace,
    nodejs,
  }: let
    pm = readPackageManager workspace;
  in
    if pm == null
    then
      throw ''
        pnpm2nix: workspace package.json is missing a "packageManager" field.
        Add one like:
          "packageManager": "pnpm@10.5.2"
      ''
    else if pm.name != "pnpm"
    then
      throw ''
        pnpm2nix: packageManager is "${pm.name}@${pm.version}", expected pnpm.
      ''
    else if !(versions ? ${pm.version})
    then
      throw ''
        pnpm2nix: pnpm version "${pm.version}" is not in pnpm-versions.json.
        Refresh the version list:
          node scripts/update-pnpm-versions.mjs
      ''
    else
      mkPnpm {
        inherit (pm) version;
        hash = versions.${pm.version};
        inherit nodejs;
      };
in {
  inherit mkPnpm parsePackageManager readPackageManager pnpmFromPackageManager versions;
}
