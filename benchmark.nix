{ withProfiling ? false
}:
(import ./default.nix { inherit withProfiling; }).rio-process-pool.components.benchmarks.rio-process-pool-bench

