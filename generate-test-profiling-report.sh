#!/usr/bin/env bash

set -xue

HERE=$(realpath $(dirname "$0"))

TARGET=${1:-/tmp}

rm -f ${TARGET}/test-profiling-report

nix build \
    --print-build-logs \
    --cores 0 \
    --max-jobs 1 \
    -o ${TARGET}/test-profiling-report \
    -f ${HERE}/generate-test-profiling-report.nix
