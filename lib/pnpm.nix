# pnpm derivation builder + helpers to derive the correct pnpm version
# from a workspace's `package.json` "packageManager" field.
#
# Source for pnpm < 12: the npm tarball (cross-platform, ~3MB), SRI hash from
# ../pnpm-versions.json.
# Source for pnpm >= 12: the prebuilt `@pnpm/exe.<target>` native binary, SRI
# hash from ../pnpm-exe-versions.json. pnpm 12's `pnpm` tarball is only a
# wrapper that downloads that binary on first run, which the sandbox forbids.
# Both files are maintained by scripts/update-pnpm-versions.mjs.
{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  nodejs,
}: let
  versionsFile = ../pnpm-versions.json;
  versions = builtins.fromJSON (builtins.readFile versionsFile);
  exeVersions = builtins.fromJSON (builtins.readFile ../pnpm-exe-versions.json);

  isNative = version: lib.versionAtLeast version "12";

  # musl on linux: those builds are static-pie, so no patchelf on NixOS.
  exeTargets = {
    "x86_64-linux" = "linux-x64-musl";
    "aarch64-linux" = "linux-arm64-musl";
    "x86_64-darwin" = "darwin-x64";
    "aarch64-darwin" = "darwin-arm64";
  };
  hostSystem = stdenv.hostPlatform.system;
  exeTarget =
    exeTargets.${hostSystem}
      or (throw "pnpm2nix: no prebuilt pnpm >= 12 binary mapped for ${hostSystem}");

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

  # Build a pnpm derivation for a specific version. `hash` is the npm
  # tarball's integrity for pnpm < 12 and the host's `@pnpm/exe.<target>`
  # integrity for pnpm >= 12 (see pnpm-exe-versions.json).
  mkPnpm = {
    version,
    hash,
    nodejs,
  }:
    if isNative version
    then mkNativePnpm {inherit version hash;}
    else mkNodePnpm {inherit version hash nodejs;};

  mkNativePnpm = {
    version,
    hash,
  }:
    stdenv.mkDerivation {
      pname = "pnpm";
      inherit version;
      src = fetchurl {
        url = "https://registry.npmjs.org/@pnpm/exe.${exeTarget}/-/exe.${exeTarget}-${version}.tgz";
        inherit hash;
      };
      dontBuild = true;
      dontStrip = true;
      installPhase = ''
        runHook preInstall
        install -Dm755 pnpm $out/bin/pnpm
        ln -s pnpm $out/bin/pn
        runHook postInstall
      '';

      meta = {
        description = "pnpm ${version} (prebuilt native binary from npm)";
        homepage = "https://pnpm.io";
        license = lib.licenses.mit;
        mainProgram = "pnpm";
      };
    };

  # The npm tarball is the same across platforms; we just wrap node to
  # execute bin/pnpm.cjs.
  mkNodePnpm = {
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
    else let
      hashes =
        if isNative pm.version
        then {
          file = "pnpm-exe-versions.json";
          hash = (exeVersions.${pm.version} or {}).${exeTarget} or null;
        }
        else {
          file = "pnpm-versions.json";
          hash = versions.${pm.version} or null;
        };
    in
      if hashes.hash == null
      then
        throw ''
          pnpm2nix: pnpm version "${pm.version}" is not in ${hashes.file}.
          Refresh the version list:
            node scripts/update-pnpm-versions.mjs
        ''
      else
        mkPnpm {
          inherit (pm) version;
          inherit (hashes) hash;
          inherit nodejs;
        };
in {
  inherit mkPnpm parsePackageManager readPackageManager pnpmFromPackageManager versions exeVersions;
}
