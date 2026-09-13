# Splits a git patch into the sections git apply can handle (keepfile) and the
# paths of files recorded as a deletion with no hunk body (delfile) — see the
# comment in extract.nix. statusfile gets 1 if keepfile holds a real diff.
function flush(  i) {
  if (n == 0) return
  if (isdiff && hunks == 0 && deleted) {
    print path > delfile
  } else {
    for (i = 1; i <= n; i++) print buf[i] > keepfile
    if (isdiff) kept = 1
  }
  n = 0
  hunks = 0
  deleted = 0
  isdiff = 0
  path = ""
}
/^diff --git / {
  flush()
  isdiff = 1
  path = substr($0, index($0, " b/") + 3)
}
/^deleted file mode / { deleted = 1 }
/^@@/ { hunks++ }
{ buf[++n] = $0 }
END {
  flush()
  print (kept ? "1" : "0") > statusfile
}
