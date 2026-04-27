{
  lib,
  runCommand,
  python3,
}: lockfile: let
  pythonWithYaml = python3.withPackages (ps: [ ps.pyyaml ]);

  # IFD: parse pnpm-lock.yaml at evaluation time. The script is small enough
  # and the lockfile small enough that the IFD cost is negligible vs. the
  # work it saves downstream. The output is content-addressed by the input
  # lockfile, so it caches across builds.
  parsedJson = runCommand "pnpm-lockfile.json" {
    nativeBuildInputs = [ pythonWithYaml ];
  } ''
    python3 ${./parser.py} ${lockfile} > $out
  '';
in
  builtins.fromJSON (builtins.readFile parsedJson)
