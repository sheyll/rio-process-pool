{ pkgs ? (import nix/pkgs.nix)
, withProfiling ? false
, withCoverage ? false
}:
pkgs.haskell-nix.project {
  src = pkgs.haskell-nix.haskellLib.cleanGit {
    name = "rio-process-pool";
    src = ./.;
  };
  configureArgs = "--flags=development";
  projectFileName = "cabal.project";
  compiler-nix-name = "ghc8104";
  modules =
    [
      {
        packages.rio-process-pool.components.library.doCoverage = withCoverage;
        packages.rio-process-pool.components.tests.rio-process-pool-test.doCoverage = withCoverage;
      }
    ] ++
    (if withProfiling then
      [{
        packages.rio-process-pool.components.library.enableLibraryProfiling = true;
        packages.rio-process-pool.components.exes.rio-process-pool-memleak-test.enableExecutableProfiling = true;
        packages.rio-process-pool.components.tests.rio-process-pool-test.enableExecutableProfiling = true;
        packages.rio-process-pool.components.benchmarks.rio-process-pool-bench.enableExecutableProfiling = true;
      }] else [ ]);

}

