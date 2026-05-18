{
  lib,
  runCommand,
  python3,
}: lockfile: workspaceYaml: let
  # workspaceYaml is the second positional arg; pass null when calling
  # without a pnpm-workspace.yaml (pre-pnpm-11 or workspaces with no
  # patches).
  pythonWithYaml = python3.withPackages (ps: [ ps.pyyaml ]);

  # IFD: parse pnpm-lock.yaml at evaluation time. The script is small enough
  # and the lockfile small enough that the IFD cost is negligible vs. the
  # work it saves downstream. The output is content-addressed by the input
  # lockfile, so it caches across builds.
  #
  # pnpm-workspace.yaml is passed in alongside the lockfile because pnpm 11
  # moved `patchedDependencies` paths there (the lockfile only carries the
  # hash). When unavailable the parser falls back to the legacy in-lockfile
  # format.
  workspaceArg =
    if workspaceYaml == null
    then ""
    else " ${workspaceYaml}";
  parsedJson = runCommand "pnpm-lockfile.json" {
    nativeBuildInputs = [ pythonWithYaml ];
  } ''
    python3 ${./parser.py} ${lockfile}${workspaceArg} > $out
  '';
in
  builtins.fromJSON (builtins.readFile parsedJson)
