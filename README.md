# benchx-arrow

Continuous C++ micro-benchmark tracking for [Apache Arrow](https://github.com/apache/arrow), powered by [**benchx**](https://github.com/benchx-dev/benchx) and [**benchx-ci**](https://github.com/benchx-dev/benchx-ci).

**Live dashboard:** https://benchx-dev.github.io/benchx-arrow/

## How it works

This repository holds **only Apache Arrow's configuration and build provider**. All measurement, storage, view generation (`bx view`), and CI/EC2 orchestration live in `benchx` and `benchx-ci`:

| File | Role |
|---|---|
| [`project.json`](project.json) | Upstream repo, branch, commit URL template, and commit-title skip tags |
| [`benchx.conf.json`](benchx.conf.json) | Target provider command (`provider/arrow-provider.sh`) and `google-benchmark` adapter |
| [`machines.json`](machines.json) | Ephemeral AWS EC2 Spot machine definitions (`c6a.4xlarge`, `m5.4xlarge`, `t4g.2xlarge`) |
| [`provider/arrow-provider.sh`](provider/arrow-provider.sh) | Checks out and incrementally builds Apache Arrow C++ with CMake + Ninja + `sccache` |
| [`provider/setup-env.sh`](provider/setup-env.sh) | Builds the commit's conda environment (`ci/conda_env_{unix,cpp}.txt`) + `benchx[parquet]` on fresh EC2 instances |
| [`provider/discover.sh`](provider/discover.sh) | Lists runnable `release/*-benchmark` binaries (skipping reference-only 0-test binaries) |
| [`.github/workflows/`](.github/workflows/) | Thin callers delegating `bench`, `publish`, `schedule`, and `command` to [`benchx-dev/benchx-ci`](https://github.com/benchx-dev/benchx-ci) |

## Running a benchmark

### Manually (workflow dispatch)

```bash
gh workflow run bench.yml --repo benchx-dev/benchx-arrow \
  -f sha=main \
  -f machine=amd64-c6a-4xlarge-linux \
  -f suite_filter='arrow-bit-util-benchmark'
```

### From an issue or PR comment

Collaborators can comment on any issue or PR in this repository:

```text
@github-actions bench <commit> [machine=<name>] [filter=<regex>] [budget=<minutes>]
```

### Locally

Because `provider/arrow-provider.sh` is self-contained, you can measure Arrow C++ locally with `benchx` and inspect the same dashboard via `bx view`:

```bash
pip install "benchx[parquet]"
bx bench @cpp=main --suite release/arrow-bit-util-benchmark
bx view
```

## Setting this up for your own project

See [`benchx-dev/benchx-ci`](https://github.com/benchx-dev/benchx-ci) for the AWS CloudFormation template (`aws/setup.yaml`) and reusable workflow inputs.
