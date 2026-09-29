#!/usr/bin/env node
// Fetch npm packuments for pnpm and (re)generate the version → hash maps.
//
// pnpm-versions.json maps a pnpm version to the SRI integrity hash of its npm
// tarball (https://registry.npmjs.org/pnpm/-/pnpm-<version>.tgz).
//
// pnpm-exe-versions.json maps a version to { "<target>": "<integrity>" } for
// the prebuilt `@pnpm/exe.<target>` packages. From pnpm 12 the CLI is a native
// Rust binary and the `pnpm` tarball is only a wrapper that downloads it on
// first run, which a Nix sandbox can't do — so for 12+ Nix fetches the binary
// directly.
//
// The integrity field in a packument is already in SRI form (sha512-<base64>),
// so Nix fetchurl can consume it directly.
//
// Idempotent: re-running with no new pnpm releases is a no-op.
//
// Requires: Node 18+ (for the global fetch).

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const registry = process.env.PNPM_REGISTRY_URL ?? "https://registry.npmjs.org";

// Only the targets lib/pnpm.nix maps a Nix system to. musl on linux because
// those builds are static, so they run on NixOS without patchelf.
const EXE_TARGETS = [
  "linux-x64-musl",
  "linux-arm64-musl",
  "darwin-x64",
  "darwin-arm64",
];

// Sort an object's keys so the output is stable across runs (mirrors `jq -S`).
const sortKeys = (obj) =>
  Object.fromEntries(
    Object.keys(obj)
      .sort()
      .map((k) => [k, obj[k]]),
  );

// { "<ver>": "<integrity>" } for every version of `name` with an SRI hash
// (very old releases used shasum only).
const fetchIntegrities = async (name) => {
  const url = `${registry}/${name}`;
  console.error(`fetching ${url} ...`);
  // The "install-v1" media type returns only dist-relevant fields, which is
  // ~10x smaller than the full packument and is all we need.
  const res = await fetch(url, {
    headers: { Accept: "application/vnd.npm.install-v1+json" },
  });
  if (!res.ok) {
    console.error(`error: registry returned HTTP ${res.status} for ${name}`);
    process.exit(1);
  }
  const packument = await res.json();
  const out = {};
  for (const [version, meta] of Object.entries(packument.versions ?? {})) {
    const integrity = meta?.dist?.integrity;
    if (integrity != null) out[version] = integrity;
  }
  return out;
};

const readJson = (file) =>
  existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};

const writeJson = (file, obj, oldCount) => {
  writeFileSync(file, JSON.stringify(obj, null, 2) + "\n");
  const newCount = Object.keys(obj).length;
  console.error(`wrote ${file}`);
  console.error(`  versions: ${oldCount} -> ${newCount} (+${newCount - oldCount})`);
};

// Merges prefer existing entries (immutable; npm tarballs don't change) and
// add any newly-published versions.

const wrapperFile = join(repoRoot, "pnpm-versions.json");
const wrapperExisting = readJson(wrapperFile);
writeJson(
  wrapperFile,
  sortKeys({ ...(await fetchIntegrities("pnpm")), ...wrapperExisting }),
  Object.keys(wrapperExisting).length,
);

const exeFile = join(repoRoot, "pnpm-exe-versions.json");
const exeExisting = readJson(exeFile);
const exeFresh = {};
for (const target of EXE_TARGETS) {
  for (const [version, integrity] of Object.entries(
    await fetchIntegrities(`@pnpm/exe.${target}`),
  )) {
    (exeFresh[version] ??= {})[target] = integrity;
  }
}
const exeMerged = {};
for (const version of new Set([
  ...Object.keys(exeFresh),
  ...Object.keys(exeExisting),
])) {
  exeMerged[version] = sortKeys({
    ...exeFresh[version],
    ...exeExisting[version],
  });
}
writeJson(exeFile, sortKeys(exeMerged), Object.keys(exeExisting).length);
