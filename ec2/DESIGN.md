# Replacing Conbench for Apache Arrow with benchx

Status: draft for discussion. The prototype it describes is in this directory (see
`README.md` for how to set it up).

## 1. Goal

Keep benchmarking every commit on apache/arrow `main`, and retire Conbench, the Arrow BCI
API service, its Postgres database and the Buildkite pipelines. The replacement has no
long-running service: GitHub Actions schedules, fresh EC2 instances measure, S3 stores,
and everything a reader sees is derived from the files in S3.

Constraints: an open source project with a small budget and little maintainer time. Every
choice below prefers fewer things to operate over features.

## 2. Decisions

| Topic | Decision |
|---|---|
| Scheduling | GitHub Actions, polling apache/arrow. Prototype in `rok/benchx-arrow`; production in a dedicated public repository in the organisation that owns the AWS account (section 4.11) |
| Machines | A fresh EC2 instance per run, always of the same instance type per machine name |
| Launching | `machulav/ec2-github-runner` (`start` launches, `stop` terminates) |
| Environment | Built from scratch on every run, from the measured commit's own dependency lists |
| Build cache | sccache with an S3 backend |
| Measurement | `bx bench`, absolute values per commit (one series per benchmark and machine) |
| Store | The instance uploads raw results per benchmark binary to S3; a workflow compacts them into one Parquet file per commit and machine |
| Views and alerts | Derived from the run files by a workflow; static site |
| History | One-off import of the Conbench export into the same layout |
| Mac | Out of scope for now |

## 3. Overview

```
apache/arrow main
      │  (polled on a schedule)
      ▼
┌──────────────────┐   one run per (commit, machine)
│ schedule workflow│──────────────────────────────┐
└──────────────────┘                              ▼
      ▲ lists raw/                     ┌─────────────────────┐
      │                                │ benchmark workflow  │
      │                                │ 1 start EC2         │
┌─────┴───────────────────────┐        │ 2 set up env        │
│ S3 bucket                   │◀───────│ 3 build (sccache)   │
│  raw/       uploads per unit│        │ 4 bx bench          │
│  runs/      result Parquet  │        │   + upload per unit │
│  sccache/   compiler cache  │        │ 5 terminate EC2     │
│  data/      benchmark inputs│        └─────────────────────┘
│  import/    Conbench history│
│  derived/   merged files    │
└─────┬───────────────────────┘
      ▼            ▲
┌──────────────────┴─┐
│ publish workflow   │──▶ static site, alerts, PR comments
│ compacts raw/→runs/│
└────────────────────┘
```

## 4. Components

### 4.1 Schedule workflow

Runs on a cron (every 15 minutes is enough) and on manual dispatch.

1. List the newest N commits on apache/arrow `main`.
2. Drop commits whose title marks them as irrelevant (`[Doc]`, `[CI]`, `[Release]`,
   `MINOR:`, and the other skip strings arrow-benchmarks-ci uses today).
3. For each of those commits and each machine, list the pair's prefix
   `raw/<commit sha>/<machine>/` and derive its status (section 4.7). A pair is done when
   every expected unit is recorded, or when its attempts are used up (section 4.9).
4. Dispatch the benchmark workflow for each remaining pair.

Manual dispatch with an explicit list of commits is the backfill and re-run path. The
bucket is the only state; there is no queue database.

Because every run gets its own instance, several commits can be measured at the same time.
A `max-parallel` limit on the bench runs under way, counted before each dispatch, caps
the EC2 spend.

### 4.2 Benchmark workflow

Three jobs, following the action's documented pattern:

- **start** (GitHub-hosted): assume the AWS role through OIDC, call the action with
  `mode: start`, the machine's instance type, a base AMI, and `iam-role-name` so the
  instance gets its own role.
- **benchmark** (on the new instance): set up, build, measure, upload (4.3 to 4.7).
- **stop** (GitHub-hosted, `if: always()`): call the action with `mode: stop`.

Guard against leaked instances: the `pre-runner-script` schedules a shutdown after a
maximum lifetime. The runner action cannot launch an instance so that shutdown
terminates it, so the instance only stops, and the schedule workflow terminates every
benchmark instance older than any plausible run.

### 4.3 Machines and series identity

A "machine" is a name bound to one instance type, for example `amd64-c6a-4xlarge-linux`
and `arm64-t4g-2xlarge-linux`, matching today's names so imported history can continue.

- benchx identifies a machine by host name, CPU model and core count. A fresh instance
  gets a fresh host name, so the `pre-runner-script` sets the host name to the machine
  name. Without this every run starts a new series.
- Each launch can land on a different physical host. Within one instance family the CPU
  model is usually the same, but `m5` is sold on two Xeon generations. benchx will keep
  those apart as two series, which is correct but splits history. Prefer families with a
  single CPU model.
- Host-to-host variation that remains inside one CPU model is noise in the series. The
  change detector has to tolerate it (section 6).

### 4.4 Environment, from scratch

Arrow's dependencies change with its commits, so nothing dependency-related is baked into
the AMI. The AMI is a stock OS image plus what the runner agent needs.

Per run:

1. Check out apache/arrow at the measured commit.
2. Create a conda environment from that commit's own `ci/conda_env_*.txt` files (cpp,
   python, r, archery, unix), as arrow-benchmarks-ci does today, plus `sccache` and
   benchx.
3. Fetch benchmark input data from `data/` in the bucket (same region, so this is fast
   and free of transfer charges).
4. Record the resolved environment (`conda list --explicit`) as declared facts in
   `.benchx/setup.json`, so every result carries the exact package set.

Step 4 matters because a dependency update can move a benchmark without any change in
Arrow. With the package set in each result, a step in a series can be attributed to the
commit or to the environment.

Use a fixed environment prefix and a fixed build directory on every run; sccache keys
include paths.

### 4.5 Build with sccache

Arrow's CMake has `ARROW_USE_SCCACHE`, on by default: when `sccache` is on the path and
`SCCACHE_BUCKET` is set, it becomes the compiler launcher. So the job only sets
`SCCACHE_BUCKET`, `SCCACHE_REGION` and `SCCACHE_S3_KEY_PREFIX` (one prefix per machine
architecture). Credentials come from the instance role.

Expectations:

- Consecutive commits share most translation units, so most compiles are cache hits.
- A compiler update in conda-forge invalidates the whole cache once; the next run is a
  cold build and repopulates it. This is acceptable and needs no action.
- A lifecycle rule on `sccache/` expires objects not written for some weeks.

### 4.6 Measurement

`bx bench --no-ingest` per unit; the result documents are uploaded per unit (section 4.7):

| Suite | Harness | Work needed |
|---|---|---|
| C++ micro | Google Benchmark adapter | none beyond the known adapter gaps (section 7) |
| Python macro | pyperf adapter | port the `arctosalliance/benchmarks` cases to plain functions |
| R macro | arrowbench | an adapter that turns arrowbench results into benchx results |

Java and JavaScript are already disabled in the current configuration and stay out.

### 4.7 Store

The instance uploads raw results; a workflow compacts them into Parquet. Two prefixes:

```
raw/<commit sha>/<machine>/attempts/<id>.json     one per attempt: commit, expected units, how it ended
raw/<commit sha>/<machine>/attempts/<id>.log      the attempt's log
raw/<commit sha>/<machine>/units/<unit>.tar.gz    one per unit: its benchx result documents
raw/<commit sha>/<machine>/failed/<unit>.<id>.json  a unit an attempt ran and got nothing from

runs/<commit sha>/<machine>/results.parquet       derived: every recorded result of the pair
runs/<commit sha>/<machine>/status.json           derived: the status, and the raw objects it was built from
```

A **unit** is one benchmark binary for C++ or one benchmark command for Python and R.
benchx writes one JSON document per benchmark case, thousands per commit, so the instance
uploads one archive per unit, as soon as the unit has run.

**The instance only adds objects.** It never reads back, merges or replaces results:

- A unit's archive is written once, with `If-None-Match: *`. A second writer of the same
  unit is refused, so two attempts cannot overwrite each other.
- An attempt's file and log are written only by that attempt.
- There is no stored status. A unit is recorded when its archive exists; an attempt was
  made when its file exists. The scheduler and a restarting instance both derive the
  status from one listing of the pair's prefix.

**Compaction** runs on a GitHub-hosted runner, in the publish workflow (4.8). For every
pair with an upload in the last few days whose raw objects differ from the ones named in
its `status.json`, it downloads the archives, ingests them into a fresh benchx store, and
replaces `results.parquet` and `status.json`.

- It always rebuilds a pair whole, from all its raw objects, and deletes nothing. So it
  can run at any time, also during a run, and running it twice changes nothing.
- Runs of the publish workflow are serialized, so one compaction writes at a time.
- Each Parquet row holds the full result document and its work order, so the Parquet
  file is the complete record once the raw objects are gone.
- Ingest happens in one place, with one benchx version. While the raw objects exist, the
  Parquet can be rebuilt from them, for example after a schema change in benchx.

Lifecycle rules: raw objects expire after 90 days; current objects in `runs/` and
`import/` never expire. Bucket versioning is on, with old versions expired after a month,
as a net against a bad compaction. The compaction must only look at pairs much younger
than the raw expiry, or it would rebuild a pair from half of its objects.

benchx needs no change: the instance runs `bx bench --no-ingest`, the compaction runs
`bx ingest`.

### 4.8 Publish workflow

Triggered when a benchmark workflow ends in any state (success, failure, cancelled or
timed out), and on manual dispatch.

1. Compact `raw/` into `runs/` (4.7). Because each run looks at every pair of the last
   few days, a compaction that failed is made up by the next one; no separate timer is
   needed.
2. Once a month is closed (all its commits complete or out of attempts), merge its run
   files into `derived/months/<yyyy-mm>/<machine>.parquet`.
3. Build the site tables (commits, points per suite, latest, changes), as the benchx-arrow
   prototype's marts step does, from the month files, the open month's run files and
   `import/`, with a SQL engine that reads Parquet from S3.
4. Publish the static site.
5. Run change detection on the affected series; post alerts.

Everything under `derived/` and on the site is disposable and can be rebuilt from `runs/`.

### 4.9 Partial runs, restarts and re-measurement

A run can end early: a job timeout, a lost instance, a build that works but a suite that
hangs. Three rules cover it.

**Partial data is published as it is.** Every unit is uploaded when it finishes, so at
most the unit in flight is lost. The publish workflow runs when the benchmark workflow
ends, however it ends, and compacts what is there. The status says how complete the pair
is; the site shows that per commit and machine (for example "87 of 92 units"), and a
series simply has no point where a unit is missing. Results appear when the run ends,
not during it; a manual publish run in between shows them earlier.

**A restart only moves forward (the ratchet).** A restart is the same dispatch again for
the same commit and machine. After setup and build, the job lists the pair's prefix and
runs only the units that have no archive. It pays for setup and a mostly cached build
again, but never for a benchmark that is already recorded.

**Nothing is recorded twice.**

- An Actions concurrency group per commit and machine keeps two attempts from running at
  once.
- The write-once upload is the backstop: if two attempts do race on a unit, the second
  archive is refused and dropped.
- The compaction builds each Parquet file from scratch, and benchx's ingest is
  idempotent, so compacting again cannot add rows.

Details:

- **Inside a unit**, benchx runs each case in its own process and records a failed or
  timed-out case as a result with that outcome. A unit with some failed cases is
  therefore a finished unit; it is not retried.
- **A unit that produces nothing** (the binary does not start, the harness crashes)
  leaves a small marker, not an archive, and is retried on the next attempt. When the
  attempts for the pair are used up, the pair counts as complete with failures.
- **A filtered attempt** (a manual dispatch that runs only some units) still declares
  all of the commit's units as expected, so it leaves the pair partial, never complete.
- **Attempt counting** is the number of attempt files. An attempt writes its file before
  it builds, so a machine that dies during the build still counts. The scheduler stops
  dispatching a pair when it is complete or has reached the attempt limit (two or three).
- **A restarted run is a different host.** Its units come from another instance than the
  first attempt's. This adds nothing new to the noise model, since every commit already
  runs on a different host, and each archive records which attempt produced it.
- **Deliberate re-measurement** of recorded units (to confirm a suspicious point) is a
  manual dispatch with a `remeasure` input naming the units. Their archives get the
  attempt in their name (`units/<unit>.<id>.tar.gz`), and the compaction adds them as
  further results for that commit, which the schema allows.
- **Order of units**: on a restart, run first the units that have never been tried, so a
  suite that always exhausts the time budget does not starve the units behind it.

### 4.10 Number of objects

What stays is two objects per commit and machine under `runs/`. With 10 to 15 measured
commits a day and three machines that is about 100 objects a day, or 30,000 to 35,000 a
year, and the monthly merge (4.8) lets readers skip most of them.

Raw objects are temporary: about 120 per commit and machine, so about 5,000 a day and
at most 450,000 in the bucket with the 90 day expiry. Only two things list them. A
scheduler or a restart lists one pair's prefix, a single request. The compaction lists
all of `raw/`, a few hundred requests and well under a minute; if that grows, it can
list by commit, taking the commits from apache/arrow.

Do not move `runs/` to an infrequent-access or archive storage class; those charge per
object and have minimum object sizes.

### 4.11 Home repository

The workflows live in one dedicated public repository, in the GitHub organisation that
owns the AWS account (today that appears to be `arctosalliance`). It holds the three
workflows, the job scripts and the machine list, and nothing else. It can replace
`arrow-benchmarks-ci`.

Why there:

- The AWS roles trust GitHub OIDC tokens from one named repository, and the runner action
  registers runners in the repository the workflow runs in. Both need admin rights over
  that repository's secrets and runners, which the benchmark maintainers have in their
  own organisation and do not have in `apache/arrow`.
- A public repository has free GitHub-hosted minutes for the start, stop, schedule and
  publish jobs, and its run logs are readable by every Arrow contributor.
- An organisation, not a personal account, so access does not depend on one person.

Why not the alternatives:

| Repository | Problem |
|---|---|
| `apache/arrow` | Secrets, self-hosted runners and cloud credentials go through ASF Infra and its policies; scheduled runs would compete with Arrow's own CI for the ASF's shared runners. The gain, a push trigger in place of polling, is a few minutes of latency. |
| `rok/benchx-arrow` | Right for the prototype; a personal, private repository is the wrong owner for the production pipeline. |
| a `benchx-dev` repository | benchx is a general tool; one project's deployment and AWS credentials do not belong with it. A worked example there is fine. |

Consequences:

- apache/arrow needs no change at all. The only thing that touches it is the bot token
  that posts pull request comments.
- GitHub disables scheduled workflows in a public repository after 60 days without
  repository activity. The pipeline writes to S3, not to the repository, so this would
  eventually stop the schedule. Have the publish workflow commit a small status file
  (for example the date of the last published commit) to keep the repository active.

## 5. Credentials

| Who | Gets | How |
|---|---|---|
| start and stop jobs | launch and terminate the benchmark instances only | GitHub OIDC to an AWS role |
| the instance | read and write `sccache/`, read `data/`, list and write `raw/` | instance role |
| schedule workflow | list and read `raw/` | GitHub OIDC to an AWS role |
| publish workflow | read the bucket, write `runs/` and `derived/` | GitHub OIDC to an AWS role |
| the runner action | register a runner in the repository | GitHub App token, or a fine-grained token with a tracked expiry |
| alerts | comment on apache/arrow pull requests | the existing bot's token |

No long-lived AWS keys exist anywhere. The instance, which runs the code of the commit
being measured, cannot write the Parquet files that readers use.

## 6. Change detection and pull requests

- **Main branch**: with a different host on each run, comparing one commit to the
  previous one is not reliable. Detection works on a window of the series and looks for a
  lasting step. This does not exist in benchx yet (section 7).
- **Pull requests** (second phase): a dispatch that measures the PR head and its base.
  Running both on one instance, with `bx compare`, removes host variation and is the
  better fit there. A scheduled job polls apache/arrow for `@ursabot please benchmark`
  comments from committers, so no webhook is needed.

## 7. Work in benchx

1. Conbench importer, following the migration contract in
   `docs/design/benchmark-result-schema.md` section 6.
2. arrowbench (R) adapter.
3. History change detector.
4. Views: the static site lives in the benchx-arrow prototype today.
5. Google Benchmark adapter: keep Arrow's `bytes_per_second` and `items_per_second`
   counters (they were dropped when the prototype was built; recheck).

## 8. Migration

1. Stand the new pipeline up beside the current one, on one machine and the C++ suite.
2. Add the remaining machines and the Python and R suites.
3. Import the Conbench export into `import/`. Imported series continue only where the
   machine name and the benchmark's identity carry over; the rest stay as a read-only
   archive.
4. Run both systems in parallel for a few weeks and compare what each flags.
5. Move the pull request bot over, then switch off Conbench, the BCI service, Postgres
   and Buildkite.

## 9. Prototype

The prototype is in `rok/benchx-arrow`, beside the existing
node setup: `ec2/` (run script, environment setup, machine list, setup guide),
`.github/workflows/bench.yml` and `schedule.yml`, `tools/compact.py`, and a compaction
and S3 sync step in `publish.yml`.

Differences from this document:

- The compaction also writes `run.parquet` (the dashboard's row) beside
  `results.parquet` and `status.json`, so the prototype's dashboard tools read the
  bucket unchanged.
- The publish workflow copies the bucket's `runs/` next to the repository's and derives
  everything from scratch; there is no monthly merge yet.
- Only the C++ suite, and one enabled machine. The environment therefore takes only
  the commit's `unix` and `cpp` lists, and no input data is fetched from `data/`.
- The schedule runs hourly, not every 15 minutes: in a private repository every timed
  run is a billed minute.
- No `remeasure` input yet.
- A run can be asked for in a comment in the prototype's own repository
  (`@github-actions bench <commit>`, `command.yml` and `tools/command.py`), for commits
  of the upstream branch only. This is a way to test by hand; it is not the pull
  request benchmarking of section 6, which measures a head against its base.

Tested locally with directories in place of the bucket: an attempt killed after one
benchmark binary, a compaction of the partial run, a restart that ran only the missing
binary, a second compaction with no duplicated results, and a third that changed nothing.
Not yet run: anything on AWS (the workflows, instance setup, sccache, S3 conditional
writes).

## 10. Where this fits in benchx's design

benchx's `docs/design/system-decomposition.md` names the components of a benchmarking
system. This pipeline maps onto them as follows.

| Piece | Component | Fit |
|---|---|---|
| schedule workflow, `tools/schedule.py` | 3.5 Scheduler | Direct. Its unit of work is a whole run per commit and machine, not a single work order. |
| `ec2/bench-run.sh` | an orchestrator (named in 3.4, under the target provider) | Calls the provider, then one runner invocation per unit, with restart. The decomposition has no section for this role. |
| `bx bench --no-ingest` | 3.3 Runner, 3.2 Harness adapters | Direct, unchanged benchx. |
| `provider/`, `ec2/setup-env.sh` | target provider (extension point) | Direct, project-owned. |
| `raw/` uploads, `tools/compact.py` | 3.1 Result store | The store's ingest, split in two: producers write result files, a later step ingests them idempotently. `runs/` is the system of record. |
| attempt files, derived status, restarts | 3.5 Scheduler (work-order status) | Scheduler state. It is derived from which uploads exist, never from their contents. |
| EC2 launch, AWS roles, runner token | outside the system (section 5) | CI platforms and machine provisioning are not components. |
| `tools/marts.py`, `tools/views.py`, the site | 3.9 Views | Direct. |
| Conbench import, history change detection | 3.10 Importers, 3.7 Change detector | Not built; both are benchx work (section 7). |

Parts of this are not specific to Arrow and may move into benchx later: the remote
store with compaction (`tools/remote.py`, `tools/compact.py`), the scheduler's status
model, and the orchestrator loop. Together they are one answer to the decomposition's
open question about the thinnest complete deployment. For now everything stays in this
repository.

## 11. Open questions

1. Confirm the home organisation and repository name (section 4.11), and which AWS
   account owns the bucket.
2. Replace `m5` with a single-CPU-model family, or accept split series.
3. How much host-to-host variation there is within one instance type. Measure the same
   commit on ten fresh instances before trusting the series.
4. Cost per run (setup, build and suite time on each instance type) and the resulting
   limit on parallel runs.
5. Whether the Python macro benchmarks move into apache/arrow or stay in a separate
   repository.
6. Retry policy for failed runs, and who gets told.
