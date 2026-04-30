# mkPnpmWorkspace — top-level entry point for building pnpm monorepo apps in Nix.
#
# Pipeline:
#   lockfile → platform filter → fetch → extract → farm (cells) → node_modules → app builds
#
# See ARCHITECTURE.md at the repo root for a diagram and detailed walkthrough.
{
  lib,
  stdenv,
  runCommand,
  python3,
  fetchurl,
  gnutar,
  gzip,
  callPackage,
  pnpm ? null,
}: {
  workspace,
  apps,
  packages ? [],
  pnpmLockYaml ? workspace + "/pnpm-lock.yaml",
  nodejs,
  pnpm ? null,
  buildEnv ? {},
  extraNativeBuildInputs ? [],
  extraNodeModuleSources ? [],
  noDevDependencies ? false,
} @ callerArgs: let
  resolvedPnpm =
    if callerArgs.pnpm != null
    then callerArgs.pnpm
    else if pnpm != null
    then pnpm
    else throw "pnpm2nix: pass `pnpm` to mkPnpmWorkspace or override at callPackage time";

  inherit (lib) mapAttrs filterAttrs concatStringsSep mapAttrsToList listToAttrs attrValues filter;

  # ---------------------------------------------------------------------------
  # Pipeline stages. Each is lazy — only evaluated when consumed downstream.
  # ---------------------------------------------------------------------------

  # Stage 1: YAML lockfile → Nix attrset (IFD via Python/PyYAML)
  parsed = (callPackage ./lockfile.nix {}) pnpmLockYaml;

  # Stage 1.5: Platform filtering — drop packages and snapshots whose os/cpu
  # fields don't match the build host. Prevents fetching and extracting ~292
  # irrelevant tarballs on linux-x64 for a typical monorepo.
  nixToNpmOs = {
    "x86_64-linux" = "linux";   "aarch64-linux" = "linux";
    "x86_64-darwin" = "darwin";  "aarch64-darwin" = "darwin";
  };
  nixToNpmCpu = {
    "x86_64-linux" = "x64";     "aarch64-linux" = "arm64";
    "x86_64-darwin" = "x64";    "aarch64-darwin" = "arm64";
  };
  hostSystem = stdenv.hostPlatform.system;
  npmOs = nixToNpmOs.${hostSystem} or null;
  npmCpu = nixToNpmCpu.${hostSystem} or null;

  matchesPlatform = pkgId: let
    spec = parsed.packages.${pkgId} or {};
    osField = spec.os or null;
    cpuField = spec.cpu or null;
  in
    (osField == null || npmOs == null || builtins.elem npmOs osField)
    && (cpuField == null || npmCpu == null || builtins.elem npmCpu cpuField);

  platformParsed = parsed // {
    packages = filterAttrs (id: _: matchesPlatform id) parsed.packages;
    snapshots = filterAttrs (_: snap:
      (snap.workspace or false) || matchesPlatform snap.package
    ) parsed.snapshots;
  };

  # Stage 2: one fetchurl per unique name@version (platform-filtered)
  fetched = (callPackage ./fetch.nix {}) platformParsed;

  # Stage 3: one tar extraction + patchShebangs per package (platform-filtered)
  extracted = (callPackage ./extract.nix {}) platformParsed fetched;

  # Stage 4: per-snapshot cell derivations + thin assembly symlink layer
  farm = (callPackage ./farm.nix {}) platformParsed extracted;

  # Stage 5: per-importer node_modules (thin symlink layer over the farm)
  nm = (callPackage ./nodeModules.nix {}) platformParsed farm;
  inherit (nm) mkImporterNodeModules isWorkspaceKey encodeKey;

  # ---------------------------------------------------------------------------
  # Importers: workspace root (".") + apps + shared packages.
  # ---------------------------------------------------------------------------

  importerPaths = ["."] ++ map (a: a.path) apps ++ packages;

  importerTopLevelDeps = path: let
    e = parsed.importers.${path} or {deps = {}; devDeps = {}; optionalDeps = {};};
  in
    e.deps
    // e.optionalDeps
    // (if noDevDependencies then {} else e.devDeps);

  # Per-importer node_modules — only top-level dep symlinks + .bin entries.
  # Tiny derivations; cheap to rebuild on importer-specific changes.
  importerNodeModules = listToAttrs (map (path: {
    name = path;
    value = mkImporterNodeModules {
      name =
        if path == "."
        then "root"
        else path;
      topLevelDeps = importerTopLevelDeps path;
    };
  }) importerPaths);

  # ---------------------------------------------------------------------------
  # Workspace dep links: for link:/file:/workspace: deps, create relative
  # symlinks from the importer's node_modules into the workspace source tree.
  # ---------------------------------------------------------------------------

  workspaceDepLinkLines = importerPath: deps:
    concatStringsSep "\n" (mapAttrsToList (depName: depKey: let
      atIndex = lib.strings.stringLength depName + 1;
      versionPart = builtins.substring atIndex (-1) depKey;
      rel = lib.removePrefix "link:"
        (lib.removePrefix "file:"
          (lib.removePrefix "workspace:" versionPart));
      # Lockfile stores `link:` paths relative to the importer's directory.
      # The symlink lives at <importerPath>/node_modules/<dep>. For unscoped
      # packages the parent is node_modules/ (one `..` to reach importer dir).
      # For scoped packages (@scope/name) the parent is node_modules/@scope/
      # (two `..`s to reach importer dir).
      isScoped = lib.hasPrefix "@" depName;
      escapePrefix = if isScoped then "../../" else "../";
      relTarget = escapePrefix + rel;
    in ''
      mkdir -p "${importerPath}/node_modules/$(dirname '${depName}')"
      ln -sf "${relTarget}" "${importerPath}/node_modules/${depName}"
    '') deps);

  # ---------------------------------------------------------------------------
  # Per-importer setup: copy the (small, symlink-only) importer node_modules
  # derivation into the build tree, then layer in workspace dep links.
  # ---------------------------------------------------------------------------

  importerSetupLines = importerPath: let
    nodeModulesDrv = importerNodeModules.${importerPath};
    workspaceDirect = filterAttrs (_: k: isWorkspaceKey k) (importerTopLevelDeps importerPath);
  in ''
    mkdir -p "${importerPath}"
    if [ -d "${nodeModulesDrv}/node_modules" ]; then
      mkdir -p "${importerPath}/node_modules"
      # cp -aT preserves symlinks (doesn't dereference). The importer drv
      # is almost entirely symlinks, so this is fast.
      cp -aT "${nodeModulesDrv}/node_modules" "${importerPath}/node_modules"
      # chmod -R u+w does NOT follow symlinks during recursion, so this
      # only affects the node_modules directory entries — not the farm.
      chmod -R u+w "${importerPath}/node_modules"
    fi
    ${workspaceDepLinkLines importerPath workspaceDirect}
  '';

  # ---------------------------------------------------------------------------
  # Source isolation: each app build only sees its own directory + shared
  # packages. Touching app B doesn't invalidate app A's build cache.
  # ---------------------------------------------------------------------------

  isolatedSrc = appName: let
    others = filter (a: a.name != appName) apps;
    excludePaths =
      (map (a: workspace + "/${a.path}") others)
      ++ (let
        candidates = ["." "apps" "packages"];
        nestedNm = lib.flatten (map (root: let
          dir = workspace + "/${root}";
        in
          if root == "."
          then
            (lib.optional (builtins.pathExists (dir + "/node_modules")) (dir + "/node_modules"))
          else if builtins.pathExists dir
          then
            map (sub: dir + "/${sub}/node_modules")
            (builtins.attrNames (builtins.readDir dir))
          else [])
        candidates);
      in
        filter builtins.pathExists nestedNm);
  in
    lib.fileset.toSource {
      root = workspace;
      fileset = lib.fileset.difference
        workspace
        (lib.fileset.unions excludePaths);
    };

  # ---------------------------------------------------------------------------
  # .npmrc injection: sandbox-required settings merged with caller overrides.
  # ---------------------------------------------------------------------------

  defaultNpmrc = ''
    manage-package-manager-versions=false
    side-effects-cache=false
  '';

  extrasInjection = let
    callerNpmrc =
      lib.findFirst
      (s: builtins.isAttrs s && s.name == ".npmrc")
      null
      extraNodeModuleSources;
    extraOthers =
      filter
      (s: !(builtins.isAttrs s && s.name == ".npmrc"))
      extraNodeModuleSources;
    npmrcText =
      if callerNpmrc == null
      then defaultNpmrc
      else defaultNpmrc + "\n" + (builtins.readFile callerNpmrc.value);
    npmrcDrv = builtins.toFile "p2n-npmrc" npmrcText;
  in
    concatStringsSep "\n" (
      [''cp -f "${npmrcDrv}" .npmrc'']
      ++ map (
        s:
          if builtins.isAttrs s
          then ''cp -f "${s.value}" "${s.name}"''
          else ''cp -f "${s}" "."''
      )
      extraOthers
    );

  # ---------------------------------------------------------------------------
  # Per-app build derivation.
  # ---------------------------------------------------------------------------

  mkApp = app: let
    appComponents = ["."] ++ packages ++ [app.path];
    setupAll = concatStringsSep "\n" (map importerSetupLines appComponents);
    appBuildEnv = buildEnv // (app.buildEnv or {});
    appExtraNative = extraNativeBuildInputs ++ (app.extraNativeBuildInputs or []);
    script = app.script or "build";
    distDir = app.distDir or "dist";
    # Workspace packages whose build script must run before the app build.
    # Useful when a workspace package produces gitignored build artifacts
    # (e.g. codegen, asset inlining) that the app's bundler needs to resolve.
    preBuildPackages = app.preBuildPackages or [];
    preBuildLines = concatStringsSep "\n" (map (pkg:
      "pnpm --filter ./${pkg} run build"
    ) preBuildPackages);
  in
    stdenv.mkDerivation {
      pname = app.name;
      version = app.version or "0.0.0";
      src = isolatedSrc app.name;
      nativeBuildInputs = [nodejs resolvedPnpm] ++ appExtraNative;

      # The node_modules tree is full of store-pointing symlinks. fixupPhase
      # tries to follow them and fails noisily; skip it.
      dontFixup = true;
      dontPatchShebangs = true;

      configurePhase = ''
        runHook preConfigure
        export HOME=$NIX_BUILD_TOP
        ${extrasInjection}
        ${setupAll}
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        ${concatStringsSep "\n" (mapAttrsToList (k: v: ''export ${k}=${lib.escapeShellArg v}'') appBuildEnv)}
        ${preBuildLines}
        pnpm --filter ./${app.path} run ${script}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p $out
        if [ -d "${app.path}/${distDir}" ]; then
          cp -r "${app.path}/${distDir}/." $out/
        else
          echo "warning: dist dir ${app.path}/${distDir} not found; copying app dir as-is"
          cp -r "${app.path}/." $out/
        fi
        runHook postInstall
      '';

      passthru = {
        nodeModules = importerNodeModules.${app.path};
        inherit (app) name path;
      };
    };

in {
  apps = listToAttrs (map (a: {
    name = a.name;
    value = mkApp a;
  }) apps);
  nodeModules = importerNodeModules;
  pnpmStore = farm;

  # Internal/debug handles. Not API surface.
  passthru = {
    inherit parsed fetched extracted farm importerNodeModules;
  };
}
