# Ephemeral machines

A second way to measure, beside the node in `node/`: GitHub Actions starts a fresh
EC2 instance for one commit, the instance builds and measures, and its results go
to an S3 bucket instead of this repository. Nothing runs between runs. `DESIGN.md`
has the reasoning and the plan beyond the prototype.

```
schedule.yml ── lists what each commit and machine left in raw/ ──▶ dispatches bench.yml
command.yml  ── a comment `@github-actions bench <commit>` ───────▶ dispatches bench.yml
bench.yml       start   launch the instance as a one-job runner (machulav/ec2-github-runner)
                bench   ec2/setup-env.sh   conda environment from the commit's own lists
                        ec2/bench-run.sh   build with sccache, measure, upload each binary's results
                stop    terminate the instance
publish.yml  ── tools/compact.py: raw/ ──▶ Parquet under runs/ ──▶ the dashboard
```

## What is in the bucket

```
raw/<sha>/<machine>/attempts/<id>.json     one per attempt: the commit, its units, how it ended
raw/<sha>/<machine>/attempts/<id>.log      the attempt's log
raw/<sha>/<machine>/units/<unit>.tar.gz    one per benchmark binary: its result files
raw/<sha>/<machine>/failed/<unit>.<id>.json  a binary that an attempt ran and got nothing from
runs/<sha>/<machine>/results.parquet       derived: a benchx store of every recorded result
runs/<sha>/<machine>/run.parquet           derived: the dashboard's row about the run
runs/<sha>/<machine>/status.json           derived: the status, and what it was built from
sccache/<arch>/                            the compiler cache
```

A machine only adds objects under `raw/`. A unit's archive is uploaded as soon as
the binary has run and is written once, so a run that dies has already uploaded
what it measured, and two attempts cannot overwrite each other. A restart (the
same dispatch again) lists the prefix and runs only the binaries that have no
archive. There is no stored status: it is derived from the listing
(`tools/run_state.py`).

`tools/compact.py` runs in the publish workflow, which every bench run that got
an instance dispatches as its last job, however it ended. It rebuilds the three
files under `runs/` for every commit and machine whose raw objects changed in the
last three days. It rebuilds a pair whole and deletes
nothing, so it is safe to run at any time and to run twice. Raw objects are
removed by a lifecycle rule after 90 days; until then the Parquet can be rebuilt
from them (`--days N`, with N well below 90).

## Asking for a benchmark

Nothing is measured on its own until `SCHEDULE_ENABLED` is `true`. Until then, and
after, a run is asked for in one of two ways.

In a comment on any issue or pull request of this repository, on a line of its own:

```
@github-actions bench <commit> [machine=<name>] [filter=<regex>] [budget=<minutes>]
@github-actions bench main filter=bit-util budget=30
```

`<commit>` is a sha (short or full), a tag or a branch of the upstream repository,
and must be on the upstream branch. The defaults are the first scheduled machine
(or the first listed when none are scheduled),
every benchmark binary and 240 minutes; the budget may be at most 360. Only the
owner, members of the organisation and collaborators are listened to. The answer
comes back as a comment (`tools/command.py`). Like every comment trigger, this
runs the workflow file on the default branch.

Or from a shell, which takes any commit and does not check the branch:

```
gh workflow run bench.yml -f sha=<full sha> -f suite_filter=bit-util -f budget_minutes=30
```

## Trying it without AWS

`RAW_URL` and both of the compaction's URLs may be directories. With a built tree
from the node setup:

```
SHA=<commit> MACHINE=laptop RAW_URL=/tmp/raw SUITE_FILTER='bit-util' REPETITIONS=1 \
BX=~/.benchx-arrow/venv/bin/bx PYTHON=~/.benchx-arrow/venv/bin/python ec2/bench-run.sh
~/.benchx-arrow/venv/bin/python tools/compact.py --raw-url /tmp/raw --runs-url /tmp/runs
```

Kill the first and run it again to see the restart.

## Setting it up

The workflows must be on the default branch before they can be dispatched.

1. **AWS resources.** `ec2/aws-setup.yaml` is a CloudFormation template for all of
   them. Deploy in `us-east-2` (all three benchmark instance types are available across
   all three AZs at the lowest Spot prices and with lower Spot contention than
   `us-east-1`). If the account already has an identity provider for
   `token.actions.githubusercontent.com`, pass its ARN as `GitHubOidcProviderArn`;
   an account can have only one.

   ```
   aws cloudformation deploy --region us-east-2 --stack-name benchx-arrow \
     --template-file ec2/aws-setup.yaml --capabilities CAPABILITY_NAMED_IAM \
     --parameter-overrides GitHubRepository=<owner>/<repository>
   ```

   It creates:

   - **The bucket**, with versioning. Noncurrent versions expire after 30 days,
     objects under `sccache/` after 30 days and under `raw/` after 90; current
     objects under `runs/` never expire. A bucket policy refuses any upload of a
     unit's archive that is not write-once, whoever sends it. Deleting the stack
     keeps the bucket.
   - **A network**: a small VPC with three public subnets (one per AZ, for Spot
     failover), and a security group with no inbound rules and all outbound allowed.
   - **The instance role** (with an instance profile of the same name), for the
     machine itself: read and write under `raw/` and `sccache/`, list the bucket.
     It cannot touch `runs/` and cannot delete.
   - **The workflow role**, assumed by GitHub through OIDC, by runs of this
     repository on its default branch only. It may launch instances into those
     subnets with the tag `project=benchx-arrow`, terminate instances with that
     tag, hand them the instance role, read the bucket (the scheduler and the
     publish job) and write under `runs/` (the compaction).
2. **Runner token.** A fine-grained token for this repository with
   "Administration: read and write" (it creates runner registrations), saved as the
   secret `GH_RUNNER_TOKEN`. Note its expiry.
3. **Repository variables.** Each output of the stack names the variable it goes
   into, so this sets all but the last:

   ```
   aws cloudformation describe-stacks --region us-east-2 --stack-name benchx-arrow \
     --query 'Stacks[0].Outputs[].[Description,OutputValue]' --output text |
     while read -r name value; do gh variable set "$name" --body "$value"; done
   ```

   | Variable | Value |
   |---|---|
   | `AWS_REGION` | the bucket's and the instances' region (`us-east-2`) |
   | `AWS_ROLE_ARN` | the workflow role |
   | `BENCH_BUCKET` | the bucket's name |
   | `EC2_AMI_X86_64`, `EC2_AMI_AARCH64` | the stock Ubuntu 24.04 images current when the stack was deployed; deploy again to move to newer ones |
   | `EC2_SUBNET_IDS`, `EC2_SECURITY_GROUP_ID` | the three AZ subnets (comma-separated, tried in order for Spot) and security group |
   | `EC2_INSTANCE_ROLE` | the instance role's name |
   | `SCHEDULE_ENABLED` | `true` to let the hourly timer dispatch; leave unset at first |

4. **First run.** Ask for a recent commit with a narrow filter and a small budget
   ("Asking for a benchmark" above; for example `filter=bit-util budget=30`). Then run
   `schedule` by hand with `dry_run` to see what it would start. A filtered run
   leaves the commit partial and counts as one of its attempts (two by default),
   so the scheduler will later run the rest of that commit once.

Machines are listed in `ec2/machines.json`; any listed machine can be launched manually, and only those with `"scheduled": true` are dispatched by the timer.

## Costs to keep in mind

- In a private repository GitHub bills the hosted jobs (start, stop, schedule,
  publish) by the minute; the job on the instance is free of GitHub charges.
- An instance that the stop job fails to terminate halts itself after the budget
  plus two hours. Halted, it is stopped, not terminated, and its volume is still
  billed. The schedule workflow terminates any benchmark instance older than eight
  hours, on every run, dry runs included; while `SCHEDULE_ENABLED` is unset that
  happens only when `schedule` is run by hand.
- The scheduler keeps at most four bench runs, and so instances, under way at once
  (`--max-parallel` in `tools/schedule.py`). Runs started by hand count.
