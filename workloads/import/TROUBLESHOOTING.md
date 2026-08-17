# Troubleshooting a failed import

For the operator, integrator, or helpdesk engineer who ran
`./run-import.sh <source> start` and saw it fail.

Follow the steps in order. Each one narrows the failure to a specific file on
disk; by step 5 you either have the cause or you have the evidence bundle to
escalate with.

Everything here is read-only. Nothing in this document changes deployment state.

---

## 0. What you need

- Shell access on the host that ran the import, as the user that ran it.
- `jq` and `python3` on `PATH`.
- `AUTONOX_HOME` — where the deployment's settings live, conventionally
  `/etc/autonox`.

The import runs with an **erased environment** (`run-import.sh` uses `env -i`),
so your interactive shell does not have `RECEIPT_DIR`, `ARTIFACT_HOST_ROOT`, or
any other setting. Load the two you need the same way the wrapper does:

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"

eval "$(env -i AUTONOX_HOME="$AUTONOX_HOME" bash -c '
  set -a; . "$AUTONOX_HOME/import.env"; set +a
  printf "RECEIPT_DIR=%q\nARTIFACT_HOST_ROOT=%q\n" "$RECEIPT_DIR" "$ARTIFACT_HOST_ROOT"')"

echo "$RECEIPT_DIR" "$ARTIFACT_HOST_ROOT"
```

If either prints empty, the deployment settings are incomplete — that is the
bug, and no import can succeed until `import.env` defines both.

---

## 1. Find the receipt

The **receipt** is the import's record of truth: one JSON file per import run,
recording every task, its status, and the paths to its evidence. Every step
below starts from it.

The failing run prints the path on stderr (`… failed; see …/latest`). If you
still have that output, use it. Otherwise:

```bash
run_dir=$(ls -dt "${RECEIPT_DIR%/}"/*/ | head -1)          # newest run
receipt="${run_dir%/}/$(cat "${run_dir%/}/latest")"
echo "$receipt"
```

`latest` holds the **file name** of the newest receipt, not a path — that is why
it is joined to `run_dir` above.

**When several runs exist**, pick by identity rather than by timestamp. A
*resumed* older run gets new receipts written into its existing directory, so
the newest directory is not always the newest activity:

```bash
for d in "${RECEIPT_DIR%/}"/*/; do
  r="${d}$(cat "$d/latest" 2>/dev/null)"
  [[ -f "$r" ]] && jq -r '[.orchestration_run_id, .status, .identity.system_instance_id, .updated_at] | @tsv' "$r"
done | sort -k4 | column -t
```

Then set `receipt="$RECEIPT_DIR/<orchestration_run_id>/$(cat "$RECEIPT_DIR/<orchestration_run_id>/latest")"`.

A formatted overview of the same file:

```bash
./run-import.sh <source> status --receipt "$receipt"
```

---

## 2. Identify the failed task

```bash
jq -r '.tasks | to_entries[]
       | select(.value.status=="failed")
       | "\(.key)\texit=\(.value.exit_code)\t\(.value.message)"' "$receipt"
```

Read the **exit code** — it decides which of the next two steps applies:

| `exit_code` | What happened | Where the cause is |
|---|---|---|
| **non-zero** | The container itself failed — crash, bad arguments, unreachable dependency | `stderr.log` (step 3) |
| **0** | The container ran fine and returned valid JSON, but the *content* failed a check | the tool's own report (step 4) |

A `message` like `"collector result is not successful"` with `exit_code: 0` is
the second kind: nothing crashed, the collector simply reported that its work
did not succeed.

The task names, in pipeline order:
`preflight` → `collect` → `bronze_register` → `bronze_stage` → `bronze_commit` →
`silver` → `reconcile_validate` / `reconcile_run` / `reconciliation_evidence` →
`silver_finalize`.

---

## 3. Read the attempt evidence

Every task attempt writes two files, and the receipt records both paths:

```bash
jq -r '.tasks.<task> | "result: \(.result)\nlog:    \(.log)"' "$receipt"
```

They live under `<run_dir>/attempts/<task>/<timestamp>-<random>/`:

- **`result.json`** — the container's stdout, always exactly one JSON object.
- **`stderr.log`** — everything the container wrote to stderr: diagnostics,
  stack traces, connection errors.

```bash
task=collect                                              # or whichever failed
jq . "$(jq -r --arg t "$task" '.tasks[$t].result' "$receipt")"
less "$(jq -r --arg t "$task" '.tasks[$t].log' "$receipt")"
```

To see every attempt of a task, including earlier retries:

```bash
ls -t "${run_dir%/}/attempts/$task/"
```

**If `exit_code` was non-zero, stop here** — `stderr.log` has the cause. Common
ones: image missing or wrong digest, unreachable database or source system, bad
credentials, a mount that is not present inside the container.

---

## 4. `collect` failed with `exit_code: 0` — find the collector's report

This is the case where `result.json` is nearly useless: the collector's stdout
is only `{"run_id": "...", "status": "FAILED"}`. It carries no errors, because
the collector writes its detail to the **artifact tree**, not to stdout.

Get the run id, then locate the report:

```bash
run_id=$(jq -r '.run_id' "$(jq -r '.tasks.collect.result' "$receipt")")
report=$(find "${ARTIFACT_HOST_ROOT%/}" -type f -path "*/${run_id}/_meta/run.report.json")
echo "$report"
```

The path follows the collector's layout:

```
$ARTIFACT_HOST_ROOT/bronze/<kind>/<name>/<scope>/<run_id>/_meta/run.report.json
```

Read the failure detail:

```bash
jq '{status, run_id, executions: [.executions[] | {spec_identity, status, duration_ms}]}' "$report"
jq '.errors[]' "$report"
```

Each entry in `.errors[]` carries `code`, `message`, `severity`, `scope`, `at`,
and — when the failure is attributable to one spec or stream — `spec_identity`,
`stream_id`, `spec_ref`, and `connection_ref`. Start with `scope`: `run` means
the whole run failed, anything else names the spec that failed.

For per-stream detail on a partially successful execution:

```bash
jq '.executions[] | select(.status != "SUCCESS") | {spec_identity, status, streams}' "$report"
```

`.errors[].code` tells you which team owns the problem:

| Code | Meaning | Usually fixed by |
|---|---|---|
| `ERR_SPEC_INVALID` | The collector spec or connection catalog is malformed or references something missing | Integrator — fix `COLLECTOR_SPEC` / `CONNECTION_CATALOG` |
| `ERR_EXECUTION_FAILED` | The source system rejected or failed the extraction | Customer's source system: credentials, permissions, availability |
| `ERR_PUBLISH_FAILED` | The collector could not write output | Host: artifact volume permissions, disk full, mount missing |
| `ERR_CAPABILITY_MISSING` | The spec asks for an extraction this collector image does not implement | AutoNox support — wrong image or unsupported spec |
| `ERR_BINDING_MISSING` | A spec references a binding that the connection catalog does not define | Integrator |
| `ERR_UNSUPPORTED_OP` | The requested operation is not available for this source kind | AutoNox support |
| `ERR_BACKPRESSURE_TIMEOUT` | The sink could not keep up and the run timed out | Host performance / AutoNox support |
| `ERR_CANCELLED` | The run was interrupted | Re-run; check for host reboots or timer conflicts |

**A `FAILED` status with a report present means partial output was published.**
The manifest is written next to the report — `run.manifest.json` in the same
`_meta/` directory — so you can see which streams landed before the failure.

### If `find` returns nothing

There is no report, and that is diagnostic in itself. The collector writes
`run.report.json` only for source specs that reached execution. If the run died
earlier — unreadable spec, unreadable connection catalog, an unusable output
root — nothing is written to the artifact tree at all.

In that case `stderr.log` from step 3 is the only record:

```bash
cat "$(jq -r '.tasks.collect.log' "$receipt")"
```

Also confirm you are looking in the right place: `ARTIFACT_HOST_ROOT` is the
**host** path, while the collector wrote to its **container** path. If those two
do not refer to the same storage, the report exists but is invisible from the
host. Check `ARTIFACT_HOST_ROOT`, `ARTIFACT_URI_PREFIX`, and
`COLLECTOR_ARTIFACT_PATH_PREFIX` in `import.env` against the volume mount in
`COLLECTOR_CONTAINER_VOLUMES`.

---

## 5. Re-run correctly

**`collect` and `preflight` cannot be retried in place.** Re-collecting produces
a new source run and a new Bronze run — that is a new import, not a retry:

```bash
./run-import.sh <source> start
```

**Every other task is resumable**, but only after an operator has confirmed the
downstream system's actual state. The driver refuses a plain `resume` on a
receipt with a failed task, deliberately: a failed Bronze commit or
reconciliation may have partially applied, and blindly repeating it can double-
apply. Inspect the subsystem with its supported read-only adapter first, then
record what you checked:

```bash
OPERATOR_ID="your.name" ./run-import.sh <source> retry-task \
  --receipt "$receipt" \
  --task <task> \
  --acknowledge "what you inspected and what you found"
```

The failed attempt is archived under `.tasks.<task>.history` rather than erased,
and your acknowledgement is recorded in `.operator_actions` — the receipt stays
audit evidence either way.

To continue an import that was merely **interrupted** (host reboot, cancelled
terminal) with no failed task:

```bash
./run-import.sh <source> resume --receipt "$receipt"
```

> **The Silver workspace lock is the one thing no retry recovers.** If a run
> failed after Silver took the lock and cannot be finalized, the next import
> into that workspace fails on the lock rather than waiting. There is no
> supported way to inspect or release it — wait out the 7200-second expiry.

---

## 6. Escalating to AutoNox support

Send these, in this order:

1. **The receipt** — `$receipt`. Safe to send: it records environment variable
   *names*, mount *destinations*, and argument *counts*, never their values.
2. **The failing task's `result.json`.**
3. **The collector's `run.report.json`**, if step 4 found one.
4. **The failing task's `stderr.log`.**

```bash
task=collect
mkdir -p /tmp/import-evidence && cd /tmp/import-evidence
cp "$receipt" .
cp "$(jq -r --arg t "$task" '.tasks[$t].result' "$receipt")" "${task}.result.json"
cp "$(jq -r --arg t "$task" '.tasks[$t].log' "$receipt")"    "${task}.stderr.log"
[[ -n "${report:-}" ]] && cp "$report" collector.run.report.json
cd .. && tar czf import-evidence.tgz import-evidence
```

> **Review items 3 and 4 before sending them off-site.** Unlike the receipt,
> `stderr.log` and `run.report.json` are not redacted — they can contain
> customer identifiers, record contents, hostnames, or account names from the
> source system. Redact per the customer's data-handling policy.

Also state: the source name, `orchestration_run_id`, the container runtime
(`docker` / `podman`), and whether the run was manual, cron, or systemd timer.

---

## Appendix: showing the exact container commands

When the failure looks like a wrong mount, a missing environment variable, or an
image that is not the one you expect, re-run with:

```bash
DEBUG_CONTAINER_COMMANDS=1 IMPORT_PASSTHROUGH_ENV=DEBUG_CONTAINER_COMMANDS \
  ./run-import.sh <source> start
```

Each container command is printed to the terminal before it runs. The
`IMPORT_PASSTHROUGH_ENV` part is required — the wrapper erases the environment,
so the flag will not reach the driver without being named explicitly.

> This prints **real argument values, including secrets**. Use it on a terminal
> you control, and never paste the output into a ticket unredacted.

## Appendix: quick reference

| Thing | Where |
|---|---|
| Receipts | `$RECEIPT_DIR/<orchestration_run_id>/receipt.<n>.json` |
| Newest receipt's file name | `$RECEIPT_DIR/<orchestration_run_id>/latest` |
| Per-attempt evidence | `<run_dir>/attempts/<task>/<timestamp>-<random>/{result.json,stderr.log}` |
| Preflight image inspection | `<run_dir>/preflight-image-inspect.json` |
| Collector report | `$ARTIFACT_HOST_ROOT/bronze/<kind>/<name>/<scope>/<run_id>/_meta/run.report.json` |
| Collector manifest | same directory, `run.manifest.json` |
| Deployment settings | `$AUTONOX_HOME/import.env` |
| Per-source settings | `$AUTONOX_HOME/sources/<source>.env` |
| Image digests | `$AUTONOX_HOME/images.env` |
| Import locks | `$AUTONOX_HOME/var/locks/import-<workspace>.lock` |
