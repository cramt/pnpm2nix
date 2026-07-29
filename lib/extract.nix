{
  lib,
  runCommand,
  gnutar,
  gzip,
  stdenv,
  nodejs,
  gitMinimal,
}: parsed: fetched: workspaceSrc: let
  # One derivation per name@version. Output layout is a flat directory containing
  # the package's contents directly (i.e., the contents of `package/` from the tarball).
  # Consumers symlink this into `node_modules/<name>` at the next layer.
  #
  # patchShebangs: bin scripts in npm packages typically use `#!/usr/bin/env node`,
  # but the Nix sandbox has no /usr/bin/env. We rewrite `#!/usr/bin/env node` to
  # `#!<nodejs-store-path>/bin/node` so the scripts work when later linked into
  # `node_modules/.bin/`. Doing it at the extraction layer caches per-package,
  # not per-build.

  patchedDeps = parsed.patchedDependencies or {};

  extractOne = key: spec: let
    tarball = fetched.${key};
    safeName = builtins.replaceStrings ["/"] ["+"] spec.name;
    patchInfo = patchedDeps.${key} or null;
    hasPatch = patchInfo != null;
    # Store path names can't contain '@', and pnpm 11 percent-encodes the '/'
    # in scoped names ('@pierre%2Fdiffs@1.3.0-beta.5.patch'), which is illegal
    # too. sanitizeDerivationName maps everything outside the legal set to '-'.
    # builtins.path lets us rename without touching the file on disk.
    patchFile = if hasPatch then builtins.path {
      path = workspaceSrc + "/${patchInfo.path}";
      name = lib.strings.sanitizeDerivationName (builtins.baseNameOf patchInfo.path);
    } else null;
  in runCommand "pnpm-pkg-${safeName}-${spec.version}" {
    nativeBuildInputs = [ gnutar gzip nodejs ] ++ lib.optional hasPatch gitMinimal;
    inherit tarball;
    passthru = { inherit (spec) name version hasBin; };
  } (''
    mkdir -p $out
    # `--delay-directory-restore`: some npm tarballs ship directories without
    # execute bit (e.g. pngjs's `drw-rw-rw-`). Tar normally restores those
    # perms as it walks the archive, breaking its own ability to descend.
    # This flag holds dir perms until the end of extraction. We then chmod
    # `u+rwX` so we can read everything; the trailing `chmod -R a-w` makes
    # the output read-only the way Nix store outputs typically are.
    tar -xzf $tarball --strip-components=1 -C $out --delay-directory-restore
    chmod -R u+rwX $out

    if command -v patchShebangs >/dev/null 2>&1; then
      patchShebangs $out
    fi
  '' + lib.optionalString hasPatch ''

    # Apply pnpm patch for ${key}
    echo "pnpm2nix: applying patch ${patchInfo.path} to ${key}"
    cd $out
    git apply --unsafe-paths "${patchFile}"
    cd -
  '' + ''

    chmod -R a-w $out
  '');
in
  lib.mapAttrs extractOne parsed.packages
