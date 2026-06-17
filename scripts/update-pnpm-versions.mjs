#!/usr/bin/env node
// Fetch the npm packument for pnpm and (re)generate pnpm-versions.json.
//
// Each entry maps a pnpm version to the SRI integrity hash of its npm tarball
// (https://registry.npmjs.org/pnpm/-/pnpm-<version>.tgz). The integrity field
// in the packument is already in SRI form (sha512-<base64>), so Nix fetchurl
// can consume it directly.
//
// Idempotent: re-running with no new pnpm releases is a no-op.
//
// Requires: Node 18+ (for the global fetch).

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const outFile = join(repoRoot, "pnpm-versions.json");
const registryUrl =
  process.env.PNPM_REGISTRY_URL ?? "https://registry.npmjs.org/pnpm";

// Sort an object's keys so the output is stable across runs (mirrors `jq -S`).
const sortKeys = (obj) =>
  Object.fromEntries(
    Object.keys(obj)
      .sort()
      .map((k) => [k, obj[k]]),
  );

console.error(`fetching ${registryUrl} ...`);

// The "install-v1" media type returns only dist-relevant fields, which is
// ~10x smaller than the full packument and is all we need.
const res = await fetch(registryUrl, {
  headers: { Accept: "application/vnd.npm.install-v1+json" },
});
if (!res.ok) {
  console.error(`error: registry returned HTTP ${res.status}`);
  process.exit(1);
}
const packument = await res.json();

// Reduce versions{} into { "<ver>": "<integrity>" }.
// Skip versions without an SRI integrity (very old releases used shasum only).
const fresh = {};
for (const [version, meta] of Object.entries(packument.versions ?? {})) {
  const integrity = meta?.dist?.integrity;
  if (integrity != null) fresh[version] = integrity;
}

// Merge: prefer existing entries (immutable; npm tarballs don't change)
// and add any newly-published versions.
const existing = existsSync(outFile)
  ? JSON.parse(readFileSync(outFile, "utf8"))
  : {};
const oldCount = Object.keys(existing).length;

const merged = sortKeys({ ...fresh, ...existing });
const newCount = Object.keys(merged).length;

writeFileSync(outFile, JSON.stringify(merged, null, 2) + "\n");

console.error(`wrote ${outFile}`);
console.error(`  versions: ${oldCount} -> ${newCount} (+${newCount - oldCount})`);
