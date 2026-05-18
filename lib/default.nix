{ pkgs }: let
  pnpmLib = pkgs.callPackage ./pnpm.nix { nodejs = pkgs.nodejs; };
in {
  mkPnpmWorkspace = pkgs.callPackage ./workspace.nix { inherit pnpmLib; };

  # pnpm helpers: derive the correct pnpm from a workspace's packageManager
  # field, or build any specific pnpm version.
  #
  # Versions are looked up in ../pnpm-versions.json (refresh via
  # scripts/update-pnpm-versions.sh).
  inherit (pnpmLib) mkPnpm parsePackageManager readPackageManager pnpmFromPackageManager;

  # Lower-level handles for non-workspace use or debugging. Each takes the
  # output of the previous stage and produces its layer:
  #   lockfile: pnpmLockYaml → parsed
  #   fetch:    parsed → fetched
  #   extract:  parsed → fetched → extracted
  #   farm:     parsed → extracted → farmDrv
  #   nodeModules: parsed → farmDrv → { mkImporterNodeModules, ... }
  lockfile = pkgs.callPackage ./lockfile.nix {};
  fetch = pkgs.callPackage ./fetch.nix {};
  extract = pkgs.callPackage ./extract.nix {};
  farm = pkgs.callPackage ./farm.nix {};
  nodeModules = pkgs.callPackage ./nodeModules.nix {};
}
