{ pkgs }: {
  mkPnpmWorkspace = pkgs.callPackage ./workspace.nix {};

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
