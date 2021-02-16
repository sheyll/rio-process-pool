let pkgs = import nix/pkgs.nix; in
pkgs.runCommand "benchmark-report"
{
  benchmark = import ./benchmark.nix { withProfiling = false; };
} ''
  mkdir -p $out
  cd $out

  $benchmark/bin/rio-process-pool-bench -o benchmark-1-CORES.html +RTS -N1
  # $benchmark/bin/rio-process-pool-bench -o benchmark-2-CORES.html +RTS -N2
  $benchmark/bin/rio-process-pool-bench -o benchmark-ALL-CORES.html +RTS -N
''

