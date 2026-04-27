{
  lib,
  fetchurl,
}: parsed: let
  fetchOne = _: spec: fetchurl {
    name = "${baseNameOf spec.name}-${spec.version}.tgz";
    url = spec.url;
    hash = spec.integrity;
  };
in
  lib.mapAttrs fetchOne parsed.packages
