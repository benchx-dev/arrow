#!/usr/bin/env bash
# List runnable Arrow C++ benchmark suites relative to BUILD_DIR.
# Skips reference-only binaries that register 0 benchmarks unless built with
# -DARROW_WITH_BENCHMARKS_REFERENCE=ON, while keeping binaries that fail to list
# so broken builds still surface in logs.
set -euo pipefail
BUILD=${1:?}
while IFS= read -r bin; do
  [[ -n $bin ]] || continue
  if listed=$("$BUILD/release/$bin" --benchmark_list_tests=true 2>/dev/null); then
    if [[ -z ${listed//[[:space:]]/} ]]; then
      echo "skipping $bin: no benchmarks registered" >&2
      continue
    fi
  fi
  printf 'release/%s\n' "$bin"
done < <(cd "$BUILD/release" && ls -1 | grep -E -- '-benchmark$' || true)
