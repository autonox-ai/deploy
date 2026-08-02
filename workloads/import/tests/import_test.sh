#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DRIVER="$ROOT/workloads/import/import.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/artifacts" "$TMP/config" "$TMP/receipts"
printf '%s\n' '{}' >"$TMP/config/collector.yaml"
printf '%s\n' '{}' >"$TMP/config/catalog.yaml"
printf '%s\n' '{}' >"$TMP/config/warehouse.yaml"
printf '%s\n' '{}' >"$TMP/config/flow.yaml"
printf '%s\n' '{}' >"$TMP/config/banding.yaml"
printf '%s\n' '{}' >"$TMP/config/reconcile.yaml"

cp "$ROOT/workloads/import/tests/fake-runtime.sh" "$TMP/bin/fake-runtime"
chmod +x "$TMP/bin/fake-runtime"

export TENANT_ID=test ENVIRONMENT=test WORKSPACE_ID=ws SYSTEM_INSTANCE_ID=oracle TARGET_REF=warehouse/ws
export CONTAINER_RUNTIME="$TMP/bin/fake-runtime" FAKE_RUNTIME_LOG="$TMP/runtime.log"
export COLLECTOR_IMAGE='example/collectors@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
export WAREHOUSE_IMAGE='example/warehouse@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
export RECONCILE_IMAGE='example/reconcile@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
export RECEIPT_DIR="$TMP/receipts" ARTIFACT_URI_PREFIX='shared://test' ARTIFACT_HOST_ROOT="$TMP/artifacts"
export COLLECTOR_ARTIFACT_PATH_PREFIX=/output WAREHOUSE_ARTIFACT_PATH_PREFIX=/output RECONCILE_ARTIFACT_PATH_PREFIX=/output
export COLLECTOR_SPEC="$TMP/config/collector.yaml" CONNECTION_CATALOG="$TMP/config/catalog.yaml" COLLECTOR_ROOT_URI=/output
export WAREHOUSE_WIRING="$TMP/config/warehouse.yaml" FLOW_SPEC="$TMP/config/flow.yaml" BANDING_SPEC="$TMP/config/banding.yaml" RECONCILE_WIRING="$TMP/config/reconcile.yaml"
export COLLECTOR_COMMAND_ARGS=collect TNS_ADMIN=oracle-secret
export COLLECTOR_CONTAINER_ENV_NAMES=TNS_ADMIN
export COLLECTOR_CONTAINER_VOLUMES="$TMP/artifacts:/output:ro"

"$DRIVER" start >/dev/null
receipt="$(find "$TMP/receipts" -name latest -exec sh -c 'cat "$1"' _ {} \;)"
receipt_path="$(find "$TMP/receipts" -name "$receipt" -print -quit)"
jq -e '.status == "completed" and .tasks.silver_finalize.status == "succeeded"' "$receipt_path" >/dev/null
grep -q '^run --rm' "$TMP/runtime.log"
grep -q -- '--env TNS_ADMIN' "$TMP/runtime.log"
! grep 'warehouse.*--env TNS_ADMIN' "$TMP/runtime.log"
! grep -q 'oracle-secret' "$receipt_path"
! grep -q "$TMP/artifacts" "$receipt_path"

# --- retry of a failed task ------------------------------------------------
# A transient failure after intents_emitted must be recoverable without hand-
# editing the receipt, and without redoing the work the receipt already proves.
export ORCHESTRATION_RUN_ID=import_retry SILVER_RUN_ID=silver_retry
export FAKE_RUNTIME_LOG="$TMP/retry.log"
RUN_DIR="$TMP/receipts/import_retry"

FAKE_RUNTIME_FAIL=' get execution-group ' "$DRIVER" start >/dev/null 2>&1 && exit 1
failed_receipt="$RUN_DIR/$(cat "$RUN_DIR/latest")"
jq -e '.tasks.reconciliation_evidence.status == "failed" and .tasks.reconcile_run.status == "succeeded"' "$failed_receipt" >/dev/null

# resume alone must still refuse, and must name the retry path.
"$DRIVER" resume --receipt "$failed_receipt" 2>"$TMP/refusal" && exit 1
grep -q 'retry-task --receipt' "$TMP/refusal"

# An acknowledgement is mandatory.
"$DRIVER" retry-task --receipt "$failed_receipt" --task reconciliation_evidence 2>/dev/null && exit 1
# Recollection is a new import, never an in-place retry.
"$DRIVER" retry-task --receipt "$failed_receipt" --task collect --acknowledge x 2>"$TMP/collect-refusal" && exit 1
grep -q 'new import' "$TMP/collect-refusal"

# Receipts already on disk are immutable, including across the retry.
find "$RUN_DIR" -name 'receipt.*.json' -exec shasum -a 256 {} \; >"$TMP/before.sha"
runs_before="$(grep -c -- ' run --intents ' "$TMP/retry.log")"
collects_before="$(grep -c -- 'collectors@sha256' "$TMP/retry.log")"

OPERATOR_ID=tester "$DRIVER" retry-task --receipt "$failed_receipt" \
  --task reconciliation_evidence --acknowledge 'queried the execution group; all 2 intents applied' >/dev/null

shasum -a 256 -c "$TMP/before.sha" >/dev/null

final="$RUN_DIR/$(cat "$RUN_DIR/latest")"
jq -e '.status == "completed" and .tasks.reconciliation_evidence.status == "succeeded"' "$final" >/dev/null
# The failed attempt is preserved, not erased, and the acknowledgement with it.
jq -e '.tasks.reconciliation_evidence.history | length == 1 and .[0].status == "failed"' "$final" >/dev/null
jq -e '.operator_actions | length == 1 and .[0].actor == "tester" and .[0].task == "reconciliation_evidence" and .[0].cleared_status == "failed"' "$final" >/dev/null
jq -e '.resumed_from | startswith("receipt.")' "$final" >/dev/null
# Nothing the receipt already proved was redone: no recollection, no reapply.
[[ "$(grep -c -- ' run --intents ' "$TMP/retry.log")" == "$runs_before" ]]
[[ "$(grep -c -- 'collectors@sha256' "$TMP/retry.log")" == "$collects_before" ]]
# Sequence numbers are forward-only and each receipt records its own number.
for path in "$RUN_DIR"/receipt.*.json; do
  base="${path##*/}"; n="${base#receipt.}"; n="${n%.json}"
  jq -e --argjson n "$n" '.receipt_sequence == $n' "$path" >/dev/null
done
# A rewind — resuming from an older receipt while higher-numbered ones exist —
# must write forward rather than restarting numbering and overwriting them.
find "$RUN_DIR" -name 'receipt.*.json' -exec shasum -a 256 {} \; >"$TMP/rewind.sha"
high="$(cat "$RUN_DIR/latest")"; high="${high#receipt.}"; high="${high%.json}"
OPERATOR_ID=tester "$DRIVER" retry-task --receipt "$failed_receipt" \
  --task reconciliation_evidence --acknowledge 'rewound deliberately' >/dev/null
shasum -a 256 -c "$TMP/rewind.sha" >/dev/null
rewound="$(cat "$RUN_DIR/latest")"; rewound="${rewound#receipt.}"; rewound="${rewound%.json}"
(( rewound > high ))

# status leaves no working file behind.
"$DRIVER" status --receipt "$RUN_DIR/$(cat "$RUN_DIR/latest")" >/dev/null
[[ -z "$(find "$RUN_DIR" -name 'state.resume.*.json')" ]]

printf '%s\n' 'import test passed'
