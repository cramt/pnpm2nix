{
  description = "pnpm2nix-cramt — pure-Nix pnpm-lock.yaml v9 to per-package node_modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      lib = import ./lib { inherit pkgs; };
    in {
      lib = lib;

      packages = {
        # Surfaced for dev convenience: build the example workspace.
        # Run with `nix build .#example-foo` etc.
      };
    }) // {
      # Overlay form for downstream flakes that prefer the nixpkgs convention.
      overlays.default = final: prev: {
        pnpm2nix-cramt = import ./lib { pkgs = final; };
      };
    };
}
