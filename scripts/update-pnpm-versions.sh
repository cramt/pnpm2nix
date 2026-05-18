#!/usr/bin/env bash
# Fetch the npm packument for pnpm and (re)generate pnpm-versions.json.
#
# Each entry maps a pnpm version to the SRI integrity hash of its npm tarball
# (https://registry.npmjs.org/pnpm/-/pnpm-<version>.tgz). The integrity field
# in the packument is already in SRI form (sha512-<base64>), so Nix fetchurl
# can consume it directly.
#
# Idempotent: re-running with no new pnpm releases is a no-op.
#
# Requires: curl, jq.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_FILE="$REPO_ROOT/pnpm-versions.json"
REGISTRY_URL="${PNPM_REGISTRY_URL:-https://registry.npmjs.org/pnpm}"

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required" >&2
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "error: curl is required" >&2
    exit 1
fi

tmp_packument="$(mktemp)"
trap 'rm -f "$tmp_packument"' EXIT

echo "fetching $REGISTRY_URL ..."
curl -fsSL \
    -H "Accept: application/vnd.npm.install-v1+json" \
    "$REGISTRY_URL" >"$tmp_packument"

# The "install-v1" media type returns only dist-relevant fields, which is
# ~10x smaller than the full packument and is all we need.

# Reduce versions{} into { "<ver>": "<integrity>" } sorted by version.
# Skip versions without an SRI integrity (very old releases used shasum only).
new_json="$(jq -S '
    .versions
    | to_entries
    | map(select(.value.dist.integrity != null))
    | map({ key: .key, value: .value.dist.integrity })
    | from_entries
' "$tmp_packument")"

if [ -f "$OUT_FILE" ]; then
    # Merge: prefer existing entries (immutable; npm tarballs don't change)
    # and add any newly-published versions.
    merged="$(jq -S -n \
        --argjson old "$(cat "$OUT_FILE")" \
        --argjson new "$new_json" \
        '$new * $old')"
else
    merged="$new_json"
fi

old_count=0
if [ -f "$OUT_FILE" ]; then
    old_count="$(jq 'length' "$OUT_FILE")"
fi
new_count="$(printf '%s' "$merged" | jq 'length')"

printf '%s\n' "$merged" >"$OUT_FILE"

echo "wrote $OUT_FILE"
echo "  versions: $old_count -> $new_count (+$((new_count - old_count)))"
