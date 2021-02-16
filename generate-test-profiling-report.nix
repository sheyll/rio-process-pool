let pkgs = import nix/pkgs.nix;
in
pkgs.runCommand "test-profiling-report"
{
  unitTest = import ./test.nix { withProfiling = true; };
  hp2pretty = pkgs.haskellPackages.hp2pretty;
} ''
  mkdir -p $out
  cd $out
  $unitTest/bin/rio-process-pool-test --html test-result.html
  # produce rio-process-pool-test.svg
  $hp2pretty/bin/hp2pretty rio-process-pool-test.hp
''

