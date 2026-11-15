#!/usr/bin/env bash
# Build the environment for one commit from nothing, on a fresh machine: a conda
# environment from the dependency lists of the Arrow commit being measured, plus
# the compilers, sccache and this repository's Python tools. Nothing here is
# baked into the machine image, because Arrow's dependencies change with its
# commits.
#
# The resolved package set is written to $BENCHX_SETUP_FILE, which benchx copies
# into every result: a step in a series can then be told apart as the commit's or
# the environment's.
#
#   SHA           the Arrow commit
#   BENCHX_WORK   where everything goes; fixed across runs, since sccache keys
#                 include paths (default /opt/benchx-arrow)
set -euo pipefail
: "${SHA:?}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
export BENCHX_WORK=${BENCHX_WORK:-/opt/benchx-arrow}
source "$ROOT/provider/clone-lib.sh"
ENV=$WORK/env
MAMBA=$WORK/bin/micromamba
SETUP_FILE=${BENCHX_SETUP_FILE:-$WORK/setup.json}
PYTHON_VERSION=${PYTHON_VERSION:-3.12}

mkdir -p "$WORK/bin" "$WORK/env-lists"
if [[ ! -x $MAMBA ]]; then
  case $(uname -m) in
    x86_64) platform=linux-64 ;;
    aarch64) platform=linux-aarch64 ;;
    *) echo "setup-env: unsupported architecture $(uname -m)" >&2; exit 2 ;;
  esac
  curl -fsSL "https://micro.mamba.pm/api/micromamba/$platform/latest" | tar -xj -C "$WORK" bin/micromamba
fi

ensure_clone
sha=$(resolve_commit "$SHA") || { echo "setup-env: unknown commit $SHA" >&2; exit 2; }
files=()
for list in unix cpp; do
  git -C "$CLONE" show "$sha:ci/conda_env_$list.txt" >"$WORK/env-lists/$list.txt"
  files+=(--file "$WORK/env-lists/$list.txt")
done

rm -rf "$ENV"
"$MAMBA" create -y -q -p "$ENV" -c conda-forge "${files[@]}" compilers ninja sccache git pip "python=$PYTHON_VERSION"
"$MAMBA" run -p "$ENV" pip install -q -r "$ROOT/tools/requirements.txt" -r "$ROOT/ec2/requirements.txt"

"$MAMBA" env export -p "$ENV" --explicit >"$WORK/env-explicit.txt"
# The machine's own description, when this is EC2 (instance metadata, version 2).
imds() {
  local token
  token=$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null) || return 0
  curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true
}
INSTANCE_TYPE=$(imds instance-type) INSTANCE_ID=$(imds instance-id) AMI_ID=$(imds ami-id) \
"$ENV/bin/python" - "$WORK/env-explicit.txt" "$SETUP_FILE" <<'PY'
import json, os, sys
packages = [line.strip() for line in open(sys.argv[1]) if line.startswith("http")]
facts = {"conda": {"channel": "conda-forge", "packages": packages}}
instance = {k: os.environ[v] for k, v in (("type", "INSTANCE_TYPE"), ("id", "INSTANCE_ID"), ("image", "AMI_ID")) if os.environ.get(v)}
if instance:
    facts["ec2"] = instance
json.dump(facts, open(sys.argv[2], "w"), indent=1)
PY
echo "setup-env: $(grep -c '^http' "$WORK/env-explicit.txt") packages in $ENV; facts in $SETUP_FILE"
