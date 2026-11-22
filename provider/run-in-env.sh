#!/usr/bin/env bash
# Run a command inside the Arrow conda environment built by provider/setup-env.sh.
set -euo pipefail
export ARROW_DEPENDENCY_SOURCE=CONDA
WORK=${BENCHX_WORK:-/opt/benchx-arrow}
exec "$WORK/bin/micromamba" run -p "$WORK/env" "$@"
