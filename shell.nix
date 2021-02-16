{ withProfiling ? false }:
let
  pkgs = import nix/pkgs.nix;
in
(import ./default.nix { inherit pkgs withProfiling; }).shellFor {
  packages = p: [ p.rio-process-pool ];
  withHoogle = true;
  tools = {
    cabal = "latest";
    ormolu = "latest";
    haskell-language-server = "latest";
  };
  buildInputs = with pkgs.haskellPackages;
    [
      tasty-discover
      graphmod
      hp2pretty
      pkgs.git
      pkgs.graphviz
    ];
}

