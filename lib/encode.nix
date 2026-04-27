{ lib }: let
  # Match pnpm's depPathToFilename behavior closely enough that two snapshots
  # producing relative symlinks at <key>/.pnpm/../<encodeKey depKey> agree on
  # what the dep directory is named. We don't need to match pnpm's exact hash
  # output (we never share these dirs with a real pnpm install) — only need
  # determinism and uniqueness.
  #
  # pnpm's rule: replace path-illegal chars with `+`, and if the result exceeds
  # MAX_LENGTH (120 in recent pnpm), truncate to (MAX_LENGTH - 27) and append
  # `_<26-char-hash>`. We mirror that, using a sha256 hex prefix instead of
  # base32 for portability.
  maxLength = 120;
  hashLen = 26;
  truncTo = maxLength - hashLen - 1;  # 93

  sanitize = key: builtins.replaceStrings
    [ "/" ":" "*" "?" "\"" "<" ">" "|" "\\" "$" ]
    [ "+" "+" "+" "+" "+" "+" "+" "+" "+" "+" ]
    key;
in {
  encodeKey = key: let
    s = sanitize key;
  in
    if builtins.stringLength s <= maxLength
    then s
    else "${builtins.substring 0 truncTo s}_${builtins.substring 0 hashLen (builtins.hashString "sha256" s)}";
}
