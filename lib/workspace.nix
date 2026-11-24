# mkPnpmWorkspace — top-level entry point for building pnpm monorepo apps in Nix.
#
# Pipeline:
#   lockfile → platform filter → fetch → extract → farm (cells) → node_modules → app builds
#
# See ARCHITECTURE.md at the repo root for a diagram and detailed walkthrough.
{
  lib,
  stdenv,
  callPackage,
  pnpmLib,
}: {
  workspace,
  apps,
  packages ? [],
  pnpmLockYaml ? workspace + "/pnpm-lock.yaml",
  # pnpm 11+ stores patchedDependencies paths in pnpm-workspace.yaml
  # (only the hash lives in the lockfile). Pass it so the parser can
  # reconstruct the path/hash pair. null is fine for pre-11 workspaces
  # or workspaces with no patches.
  pnpmWorkspaceYaml ?
    let p = workspace + "/pnpm-workspace.yaml"; in
    if builtins.pathExists p then p else null,
  nodejs,
  pnpm ? null,
  buildEnv ? {},
  extraNativeBuildInputs ? [],
  extraNodeModuleSources ? [],
  noDevDependencies ? false,
  appSrc ? null,
  # Run workspace packages' `prepare` scripts, as `pnpm install` does, and
  # build every app against the prepared packages. See "Workspace `prepare`
  # scripts" below.
  prepareWorkspacePackages ? true,
  # Source for a package's prepare derivation, as `path -> src`. Defaults to
  # `srcFor { inherit path; }`. Mirrors `appSrc` for callers that filter.
  packageSrc ? null,
  # Workspace-root entries (files or dirs, root-relative names) every default
  # source includes on top of its importers. null means every regular file at
  # the root except the lockfile. An allowlist is the safer choice for a busy
  # repo: anything new at the root (infra, docs, CI config) then stays out of
  # every build instead of invalidating all of them.
  rootSrc ? null,
  # `importerPath -> [relative path]`: what to drop from an importer's dir in
  # every default source, e.g. deploy config or docs no script reads.
  importerSrcExclude ? (_: []),
}: let
  # `workspace` is commonly a flake input (`inputs.foo`) or a store-path string
  # rather than a literal `./.`. Those coerce fine in string contexts, but
  # lib.fileset rejects anything that isn't a real path, so normalize once here
  # and use `workspaceRoot` wherever path semantics are required.
  # The context has to be discarded before appending: Nix refuses to append a
  # store-path-carrying string to a path. The target already exists in the
  # store, so there's nothing to build and no dependency to lose.
  toPath = p:
    if builtins.isPath p
    then p
    else /. + builtins.unsafeDiscardStringContext (toString p);
  workspaceRoot = toPath workspace;

  # Resolution order:
  #   1. explicit `pnpm` arg to mkPnpmWorkspace
  #   2. derive from the workspace's package.json "packageManager" field
  resolvedPnpm =
    if pnpm != null
    then pnpm
    else pnpmLib.pnpmFromPackageManager {
      inherit nodejs;
      workspace = workspaceRoot;
    };

  inherit (lib) mapAttrs filterAttrs concatStringsSep mapAttrsToList listToAttrs attrValues filter;

  # ---------------------------------------------------------------------------
  # Pipeline stages. Each is lazy — only evaluated when consumed downstream.
  # ---------------------------------------------------------------------------

  # Stage 1: YAML lockfile → Nix attrset (IFD via Python/PyYAML).
  # pnpmWorkspaceYaml is needed for pnpm 11+ patchedDependencies paths.
  parsed = (callPackage ./lockfile.nix {}) pnpmLockYaml pnpmWorkspaceYaml;

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
  # workspace is passed so extract can apply pnpm patches (patchedDependencies).
  extracted = (callPackage ./extract.nix {}) platformParsed fetched workspaceRoot;

  # Stage 4: per-snapshot cell derivations + thin compose symlink layers
  farmLib = (callPackage ./farm.nix {}) platformParsed extracted;

  # Stage 5: per-importer node_modules, each with its own closure-pruned
  # compose layer over the shared cells
  nm = (callPackage ./nodeModules.nix {}) platformParsed farmLib;
  inherit (nm) mkImporterNodeModules isWorkspaceKey encodeKey;

  # ---------------------------------------------------------------------------
  # Importers: workspace root (".") + apps + shared packages.
  # ---------------------------------------------------------------------------

  # The lockfile's importers are included because a build's workspace closure
  # can reach one the caller never listed (a package depending on an app).
  importerPaths = lib.unique (["."] ++ map (a: a.path) apps ++ packages
    ++ builtins.attrNames parsed.importers);

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
          # Bare-path form: land the file under its own filename. baseNameOf
          # runs on the path value (not the interpolated store path), so it
          # yields the clean name, not the `<hash>-name` store basename.
          else ''cp -f "${s}" "./${baseNameOf s}"''
      )
      extraOthers
    );

  # ---------------------------------------------------------------------------
  # Workspace `prepare` scripts.
  #
  # `pnpm install` runs every workspace package's `prepare`, so whatever it
  # generates (a types build in dist/, codegen) is what consumers resolve
  # locally even though it's gitignored. Each shared package with a `prepare`
  # gets one derivation that runs it and outputs the prepared package dir; every
  # build then lays those over the package sources before running, so the
  # sandbox sees the same tree a local install would.
  # ---------------------------------------------------------------------------

  readManifest = path: let
    file = workspaceRoot + "/${path}/package.json";
  in
    if builtins.pathExists file
    then builtins.fromJSON (builtins.readFile file)
    else {};

  preparedPaths =
    if prepareWorkspacePackages
    then filter (p: ((readManifest p).scripts or {}) ? prepare) packages
    else [];

  # `a/b` + `../c` -> `a/c`, for the lockfile's importer-relative link: paths.
  # null when the link leaves the workspace: there's no importer to follow.
  joinRelative = base: rel: let
    step = acc: seg:
      if acc == null || seg == "" || seg == "."
      then acc
      else if seg == ".."
      then (if acc == [] then null else lib.init acc)
      else acc ++ [seg];
    segments = lib.foldl' step
      (filter (s: s != "" && s != ".") (lib.splitString "/" base))
      (lib.splitString "/" rel);
  in
    if segments == null then null
    else if segments == [] then "."
    else concatStringsSep "/" segments;

  # Importer paths among `deps` (name -> lockfile key) that are workspace links.
  workspaceLinkPaths = importerPath: deps:
    filter (p: p != null) (mapAttrsToList (depName: depKey: let
      versionPart = builtins.substring (lib.stringLength depName + 1) (-1) depKey;
      rel = lib.removePrefix "link:"
        (lib.removePrefix "file:"
          (lib.removePrefix "workspace:" versionPart));
    in
      joinRelative importerPath rel)
    (filterAttrs (_: k: isWorkspaceKey k) deps));

  # Everything the importer itself links to, devDependencies included: what a
  # build OF this importer needs.
  workspaceDepPaths = importerPath:
    workspaceLinkPaths importerPath (importerTopLevelDeps importerPath);

  # What the importer needs when something ELSE depends on it: npm's rule, no
  # devDependencies. Peers count, since a workspace package resolves its peers
  # through its own links (pnpm lists a dev+peer dep under devDependencies, so
  # the manifest says which of those are peers). This is what keeps a
  # type-only devDependency (a client package's dev link to the server whose
  # types it re-exports) out of every consumer's closure.
  runtimeDepPaths = importerPath: let
    e = parsed.importers.${importerPath} or {deps = {}; devDeps = {}; optionalDeps = {};};
    peers = builtins.attrNames ((readManifest importerPath).peerDependencies or {});
  in
    workspaceLinkPaths importerPath
    (e.deps // e.optionalDeps // filterAttrs (name: _: builtins.elem name peers) e.devDeps);

  # Importers physically inside another importer's dir (a package nested in an
  # app). A source holding the outer dir holds the inner one too, and a script
  # there may drive it (`pnpm --filter <nested> build`), so it gets set up.
  nestedIn = path:
    filter (p: p != "." && lib.hasPrefix (path + "/") p) importerPaths;

  # Every importer a build needs, to a fixpoint. The given importers are built
  # here, so they bring all their deps (workspaceDepPaths); what they reach
  # brings only its runtimeDepPaths. An importer nested in one that's present
  # is in the source anyway and a script may build it, so it counts as built
  # here too. Sorted so the order — and with it every derivation built from
  # it — doesn't depend on the order the caller listed things in.
  importersFor = paths: let
    built = p: {key = "built:${p}"; path = p; built = true;};
    reached = p: {key = "reached:${p}"; path = p; built = false;};
  in
    lib.sort lib.lessThan (lib.remove "." (lib.unique (map (c: c.path)
      (builtins.genericClosure {
        startSet = map built paths;
        operator = item:
          map reached ((if item.built then workspaceDepPaths else runtimeDepPaths) item.path)
          ++ map built (nestedIn item.path);
      }))));

  # Prepared packages a package's own `prepare` needs first: the prepared ones
  # among its transitive workspace deps. A cycle between two packages that both
  # have `prepare` can't be ordered (pnpm can't either) and recurses at eval.
  preparedDepsOf = path:
    filter (p: p != path && builtins.elem p preparedPaths) (importersFor [path]);

  rootEntries =
    if rootSrc != null
    then map (n: workspaceRoot + "/${n}") rootSrc
    else let
      # pnpm-lock.yaml is consumed at eval time (IFD → farm); pnpm never reads
      # it during `pnpm run`. Leaving it out means a lockfile change only
      # rebuilds what its dependency closure actually changed.
      lockfile = toString pnpmLockYaml;
    in
      lib.mapAttrsToList (name: _: workspaceRoot + "/${name}")
      (filterAttrs (name: type: type == "regular" && toString (workspaceRoot + "/${name}") != lockfile)
        (builtins.readDir workspaceRoot));

  # Source for building `path`: its importer closure (see importersFor), the
  # root entries and `include`, minus each importer's node_modules and
  # importerSrcExclude, minus `exclude`. `include`/`exclude` are root-relative.
  # Nothing outside the closure, so an edit to an unrelated app or package
  # leaves the build, and its hash, untouched.
  srcFor = {
    path,
    extraImporters ? [],
    include ? [],
    exclude ? [],
  }: let
    importers = importersFor ([path] ++ extraImporters);
    existing = paths: filter builtins.pathExists (map (p:
      if p == "." then workspaceRoot else workspaceRoot + "/${p}") paths);
    dropped = lib.concatMap (p: map (rel: "${p}/${rel}") (["node_modules"] ++ importerSrcExclude p)) importers
      ++ exclude;
  in
    lib.fileset.toSource {
      root = workspaceRoot;
      fileset = lib.fileset.difference
        (lib.fileset.unions (existing (importers ++ include) ++ filter builtins.pathExists rootEntries))
        (lib.fileset.unions (existing dropped));
    };

  # Packages a build's src leaves out (a deliberately filtered appSrc) stay out.
  overlayPreparedLines = paths: concatStringsSep "\n" (map (p: ''
    if [ -d "${p}" ]; then
      cp -r "${prepared.${p}}/." "${p}/"
      chmod -R u+w "${p}"
    fi
  '') paths);

  prepared = listToAttrs (map (path: {
    name = path;
    value = mkBuild {
      name = "prepare-${lib.strings.sanitizeDerivationName path}";
      inherit path;
      src = if packageSrc != null then packageSrc path else srcFor {inherit path;};
      script = "prepare";
      overlay = preparedDepsOf path;
      installPhase = ''
        runHook preInstall
        mkdir -p $out
        # Only what `prepare` created or changed, so the overlay can't roll a
        # consumer's copy of the package's own sources back.
        (cd "${path}" && find . -name node_modules -prune -o \( -type f -o -type l \) -print) |
          while IFS= read -r f; do
            if [ ! -e "$src/${path}/$f" ] || ! cmp -s "${path}/$f" "$src/${path}/$f"; then
              mkdir -p "$out/$(dirname "$f")"
              cp -P "${path}/$f" "$out/$f"
            fi
          done
        runHook postInstall
      '';
    };
  }) preparedPaths);

  # ---------------------------------------------------------------------------
  # Per-app build derivation.
  # ---------------------------------------------------------------------------

  mkApp = app: let
    distDir = app.distDir or "dist";
  in mkBuild {
    inherit (app) name path;
    version = app.version or "0.0.0";
    src =
      if appSrc != null
      then appSrc app.name
      else srcFor {inherit (app) path; extraImporters = app.extraImporters or [];};
    script = app.script or "build";
    extraImporters = app.extraImporters or [];
    buildEnv = app.buildEnv or {};
    extraNativeBuildInputs = app.extraNativeBuildInputs or [];
    preBuildPackages = app.preBuildPackages or [];
    # Only the prepared packages this app reaches, so another package's
    # `prepare` output changing doesn't touch this derivation.
    overlay = filter (p: builtins.elem p preparedPaths)
      (importersFor ([app.path] ++ (app.extraImporters or [])));
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
  };

  mkBuild = build: let
    # Extra workspace importers whose node_modules must be set up in the
    # sandbox even though they aren't built here. Use when the app's source
    # (or its bundler/typechecker) pulls another importer's source into the
    # program and so needs that importer's dependencies resolvable — e.g. a
    # cross-app type consumer whose `tsc` compiles a sibling app's source via
    # generated types. Their dirs must also be present in the app's `src`.
    app = build;
    extraImporters = build.extraImporters or [];
    # Only the importers this build reaches. Setting up every package used to
    # tie each build to every importer's node_modules (and the hoist compose
    # over all of them), so a dep bump in one package rebuilt everything.
    appComponents = ["."] ++ importersFor ([app.path] ++ extraImporters);
    setupAll = concatStringsSep "\n" (map importerSetupLines appComponents);

    # Hoist fallback target for this build (see farm.nix header): a compose
    # over everything reachable from every importer set up in this sandbox.
    # Cells carry a dangling `node_modules → /build/.p2n-hoist` link at their
    # root; pointing it at this compose's hoisted .pnpm/node_modules/ gives
    # undeclared-dependency lookups (nitropack modules, @types walk-up) the
    # same behavior as pnpm's default hoistPattern ['*'] — scoped to this
    # app's closure, so its hash only moves when that closure does.
    appHoistFarm = farmLib.composeFor
      "pnpm-hoist-${lib.strings.sanitizeDerivationName app.name}"
      (lib.unique (lib.flatten
        (map (p: attrValues (importerTopLevelDeps p)) appComponents)));
    hoistSetup = ''
      ln -sfn "${appHoistFarm}/.pnpm/node_modules" "$NIX_BUILD_TOP/.p2n-hoist"
    '';
    appBuildEnv = buildEnv // (build.buildEnv or {});
    appExtraNative = extraNativeBuildInputs ++ (build.extraNativeBuildInputs or []);
    # Workspace packages whose build script must run before the app build.
    # Useful when a workspace package produces gitignored build artifacts
    # (e.g. codegen, asset inlining) that the app's bundler needs to resolve
    # and that its `prepare` doesn't already produce.
    preBuildLines = concatStringsSep "\n" (map (pkg:
      "pnpm --filter ./${pkg} run build"
    ) (build.preBuildPackages or []));
  in
    stdenv.mkDerivation {
      pname = build.name;
      version = build.version or "0.0.0";
      inherit (build) src installPhase;
      nativeBuildInputs = [nodejs resolvedPnpm] ++ appExtraNative;

      # The node_modules tree is full of store-pointing symlinks. fixupPhase
      # tries to follow them and fails noisily; skip it.
      dontFixup = true;
      dontPatchShebangs = true;

      # Sandbox-required pnpm settings via env vars. pnpm 11 made `.npmrc`
      # auth/registry-only — non-auth settings must come from env or
      # pnpm-workspace.yaml. Env vars work on both pnpm 10 and 11, so this
      # is the portable place to put them. (The .npmrc above is kept for
      # pnpm 10 compatibility and harmless under 11.)
      #
      # - verify_deps_before_run=false: pnpm 11 defaults to "install", which
      #   re-runs install when running scripts. That hits the registry from
      #   inside the sandbox and breaks the build.
      # - manage_package_manager_versions=false: pnpm checks the
      #   `packageManager` field and tries to switch versions otherwise.
      # - side_effects_cache=false: pnpm's side-effects cache wants to write
      #   into a directory that doesn't exist in the sandbox.
      # - pm_on_fail=ignore: pnpm 11+ replacement for the above. Without it
      #   pnpm 12 resolves the packageManager pin against the registry before
      #   every run, even when the running version already matches.
      env = {
        PNPM_CONFIG_VERIFY_DEPS_BEFORE_RUN = "false";
        PNPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS = "false";
        PNPM_CONFIG_PM_ON_FAIL = "ignore";
        PNPM_CONFIG_SIDE_EFFECTS_CACHE = "false";
      };

      configurePhase = ''
        runHook preConfigure
        export HOME=$NIX_BUILD_TOP
        ${hoistSetup}
        ${extrasInjection}
        ${overlayPreparedLines (build.overlay or [])}
        ${setupAll}
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        ${concatStringsSep "\n" (mapAttrsToList (k: v: ''export ${k}=${lib.escapeShellArg v}'') appBuildEnv)}
        ${preBuildLines}
        # pnpm exits 0 on "No projects matched the filters", so an importer
        # missing from src would otherwise build nothing and look green.
        if [ ! -f "${build.path}/package.json" ]; then
          echo "pnpm2nix: ${build.path}/package.json is not in this build's src" >&2
          exit 1
        fi
        pnpm --filter ./${build.path} run ${build.script}
        runHook postBuild
      '';

      passthru = {
        nodeModules = importerNodeModules.${build.path};
        inherit (build) name path;
      };
    };

in {
  apps = listToAttrs (map (a: {
    name = a.name;
    value = mkApp a;
  }) apps);
  nodeModules = importerNodeModules;
  # The default source and importer set of a build of `path`, for callers whose
  # `appSrc`/`packageSrc` overlay or trim it rather than start from scratch.
  inherit srcFor importersFor;
  # One derivation per workspace package with a `prepare` script, keyed by
  # path; its output is the prepared package dir (node_modules excluded).
  inherit prepared;
  pnpmStore = farmLib.compose;
  # The pnpm derivation actually used to build this workspace. Exposed so
  # callers can reuse it for utility scripts (`nix run .#deps-update` etc.)
  # without re-resolving the version themselves.
  pnpm = resolvedPnpm;

  # Internal/debug handles. Not API surface.
  passthru = {
    inherit parsed fetched extracted farmLib importerNodeModules;
    farm = farmLib.compose;
  };
}
