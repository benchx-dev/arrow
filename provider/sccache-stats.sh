#!/usr/bin/env bash
# Print sccache statistics after a build/measure run.
set -euo pipefail
sccache --show-stats
