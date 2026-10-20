# Usage: run.sh <awk script> <fixtures dir>. Each case: expected status, then
# expected deletion list.
set -eu
awkScript=$1
dir=$2
check() {
  fixture=$1 wantStatus=$2 wantDeletions=$3
  tmp=$(mktemp -d)
  touch "$tmp/deletions" "$tmp/rest.patch"
  awk -v delfile="$tmp/deletions" -v keepfile="$tmp/rest.patch" \
      -v statusfile="$tmp/status" -f "$awkScript" "$dir/$fixture"
  gotStatus=$(cat "$tmp/status")
  gotDeletions=$(tr '\n' ' ' < "$tmp/deletions" | sed 's/ $//')
  if [ "$gotStatus" != "$wantStatus" ] || [ "$gotDeletions" != "$wantDeletions" ]; then
    echo "FAIL $fixture: status $gotStatus (want $wantStatus), deletions '$gotDeletions' (want '$wantDeletions')"
    exit 1
  fi
  echo "ok $fixture"
}
check plain-diff.patch 1 ""
check git-delete-and-edit.patch 1 "gone.js"
check git-delete-only.patch 0 "gone.js"
