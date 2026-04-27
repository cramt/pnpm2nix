# pnpm2nix — Improvement Backlog

Profiled against `~/rezip/monorepo` (2,334 packages, 2,358 snapshots, 20 importers).

---

## ~~P1 — Platform Filtering (os/cpu)~~ ✓ DONE

**Problem:** The lockfile has 320 packages with `os`/`cpu` fields (esbuild, rollup, sharp, workerd, turbo, oxlint, etc.). On linux-x64, only 30 match. The other 292 are foreign-platform (darwin, windows, android, aix, freebsd...). All 292 are currently fetched, extracted, staged, and hardlinked into the farm despite never being used at runtime.

**What to change:**

1. **parser.py** — extract `os` and `cpu` arrays from the `packages` section into the JSON output:
   ```python
   packages[f"{name}@{version}"] = {
       ...
       "os": (meta or {}).get("os"),    # e.g. ["linux"] or None
       "cpu": (meta or {}).get("cpu"),   # e.g. ["x64"] or None
   }
   ```

2. **farm.nix** — accept `stdenv.hostPlatform.system`, map it to npm os/cpu strings, filter `usedPkgIds` and `nonWorkspaceSnapshots` to exclude packages that don't match the build platform:
   ```nix
   nixToNpmOs = {
     "x86_64-linux" = "linux"; "aarch64-linux" = "linux";
     "x86_64-darwin" = "darwin"; "aarch64-darwin" = "darwin";
   };
   nixToNpmCpu = {
     "x86_64-linux" = "x64"; "aarch64-linux" = "arm64";
     "x86_64-darwin" = "x64"; "aarch64-darwin" = "arm64";
   };

   matchesPlatform = pkgId: let
     spec = parsed.packages.${pkgId} or {};
     osField = spec.os or null;
     cpuField = spec.cpu or null;
   in
     (osField == null || builtins.elem currentOs osField)
     && (cpuField == null || builtins.elem currentCpu cpuField);
   ```

**Impact:** Eliminates 292 fetches, 292 extract derivations, and ~292 snapshot entries from the farm. ~46% smaller farm on linux-x64.

---

## P2 — JSON Manifest Instead of Inline Script

**Problem:** The farm build script is generated inline — one shell line per package, one block per snapshot, one line per dep link. With 1,589 stage lines + 2,034 snapshot blocks + 5,757 dep link lines, the resulting `.drv` is ~1.8MB. Every lockfile change means Nix hashes and stores a new ~1.8MB derivation.

**What to change:**

1. Generate a JSON manifest at Nix eval time via `builtins.toFile`:
   ```nix
   manifest = builtins.toFile "farm-manifest.json" (builtins.toJSON {
     packages = map (pkgId: {
       id = pkgId;
       dir = sanitizeId pkgId;
       drv = "${extracted.${pkgId}}";
     }) usedPkgIds;

     snapshots = mapAttrsToList (key: snap: {
       enc = encodeKey key;
       name = snap.name;
       dir = sanitizeId snap.package;
       deps = mapAttrsToList (depName: depKey: {
         inherit depName;
         depEnc = encodeKey depKey;
         isScoped = lib.hasPrefix "@" depName;
       }) resolvedDeps;
     }) nonWorkspaceSnapshots;
   });
   ```

2. Replace the inline script with a small fixed loop that reads the manifest with `jq`:
   ```bash
   jq -r '.packages[] | "\(.drv)\t\(.dir)"' "$manifest" | while IFS=$'\t' read drv dir; do
     cp -a "$drv" "$out/.p/$dir"
     chmod -R u+w "$out/.p/$dir"
   done
   ```

**Trade-off:** Adds `jq` as a build-time dep (already present via nodeModules.nix).

**Impact:** .drv shrinks from ~1.8MB to ~50KB. Faster eval, faster `nix-store --query`, less store bloat.

---

## P3 — Extract Bin Info in parser.py

**Problem:** `nodeModules.nix` shells out to `jq` at build time to read each dependency's `package.json` for bin entries. This runs once per top-level dep per importer. The `hasBin` boolean is already in the parser output, but the actual bin map (`{ "name": "path" }`) isn't.

**Options (pick one):**

- **Minimal:** Only invoke `jq` for packages where `hasBin == true`. The parsed data already has this field — just gate the `populate_bin_for_pkg` call on it.

- **Full:** Have `extract.nix` emit a `.bins.json` sidecar alongside each extracted package (read `package.json` during extraction, write out just the bin map). Then `nodeModules.nix` reads those files instead of invoking `jq`.

- **Eval-time:** Parse bin entries in `parser.py` from the lockfile itself (bin info is in the `packages` section for some entries). Incomplete — not all packages declare bins in the lockfile, only in their `package.json`.

**Impact:** Removes `jq` as a runtime dep from nodeModules builds, or at minimum reduces invocations to only packages with bins.

---

## P4 — Skip Staging for Single-Snapshot Packages

**Problem:** Only 24 of 1,589 packages have multiple snapshots (all exactly 2). The staging area + `cp -al` hardlink dance exists for these 24. The other 1,565 packages are staged and then hardlinked into exactly one position — so the `cp -a` to staging + `cp -al` to final + `rm -rf .p` does double filesystem work vs. a direct `cp -a` to the final position.

**What to change:** Split the build into two paths:
- Single-snapshot packages: `cp -a` directly to `.pnpm/<enc>/node_modules/<name>`.
- Multi-snapshot packages: use the staging + hardlink dance.

**Trade-off:** More complex build script for marginal IO savings. The current `rm -rf .p` is one extra directory traversal.

**Verdict:** Probably not worth the complexity. Listed for completeness.

---

## ~~P5 — parser.py Dead Branch Cleanup~~ ✓ DONE

**Problem:** Lines 181-184 have a dead if/else — both branches produce identical output:

```python
# Before:
if str(version_field).startswith(("link:", "file:", "workspace:")):
    importer_entry[dst][dep_name] = f"{dep_name}@{version_field}"
else:
    importer_entry[dst][dep_name] = f"{dep_name}@{version_field}"

# After:
importer_entry[dst][dep_name] = f"{dep_name}@{version_field}"
```

**Impact:** Code hygiene. Trivial fix.
