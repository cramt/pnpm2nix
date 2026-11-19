"""resolve_patched_dependencies against pnpm's key forms. Run: python3 test_resolve.py <parser.py>"""
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("parser", sys.argv[1])
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)
resolve = parser.resolve_patched_dependencies


def pkg(name, version):
    return {f"{name}@{version}": {"name": name, "version": version}}


packages = {
    **pkg("nitro-opentelemetry", "0.10.3"),
    **pkg("@astrojs/vite-plugin-astro", "0.1.3"),
    **pkg("left-pad", "1.0.0"),
    **pkg("left-pad", "2.0.0"),
}
A = {"path": "a.patch", "hash": "a"}
B = {"path": "b.patch", "hash": "b"}


def fails(patches):
    try:
        resolve(patches, packages)
    except SystemExit:
        return True
    return False


# A bare key follows whatever version is locked: the case that used to vanish.
assert resolve({"nitro-opentelemetry": A, "@astrojs/vite-plugin-astro": B}, packages) == {
    "nitro-opentelemetry@0.10.3": A,
    "@astrojs/vite-plugin-astro@0.1.3": B,
}
assert resolve({"@astrojs/vite-plugin-astro@0.1.3": A}, packages) == {
    "@astrojs/vite-plugin-astro@0.1.3": A
}
# Exact beats bare, bare covers the remaining versions.
assert resolve({"left-pad": A, "left-pad@2.0.0": B}, packages) == {
    "left-pad@1.0.0": A,
    "left-pad@2.0.0": B,
}
# A stale exact key (what a dependency bump leaves behind) is an error, not a no-op.
assert fails({"nitro-opentelemetry@0.10.2": A})
assert fails({"not-locked": A})
assert fails({"left-pad@^1.0.0": A})
print("ok patched-dependencies")
