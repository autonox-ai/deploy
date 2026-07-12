#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DRIVER="$ROOT/workloads/import/import.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/artifacts/meta" "$TMP/config" "$TMP/receipts"
printf '%s\n' '{}' >"$TMP/config/collector.yaml"
printf '%s\n' '{}' >"$TMP/config/catalog.yaml"
printf '%s\n' '{}' >"$TMP/config/warehouse.yaml"
printf '%s\n' '{}' >"$TMP/config/flow.yaml"
printf '%s\n' '{}' >"$TMP/config/banding.yaml"
printf '%s\n' '{}' >"$TMP/config/reconcile.yaml"
printf '%s\n' '{"status":"SUCCESS"}' >"$TMP/artifacts/meta/report.json"
printf '%s\n' '{"run_id":"collector-1","outputs":[{"spec_identity":"employees","connection_ref":"oracle","stream_id":"people"},{"spec_identity":"groups","connection_ref":"oracle","stream_id":"groups"}]}' >"$TMP/artifacts/meta/manifest.json"

cp "$ROOT/workloads/import/tests/fake-runtime.sh" "$TMP/bin/fake-runtime"
chmod +x "$TMP/bin/fake-runtime"

export TENANT_ID=test ENVIRONMENT=test WORKSPACE_ID=ws SYSTEM_INSTANCE_ID=oracle TARGET_REF=warehouse/ws
export CONTAINER_RUNTIME="$TMP/bin/fake-runtime" FAKE_RUNTIME_LOG="$TMP/runtime.log"
export COLLECTOR_IMG='example/collectors@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
export WAREHOUSE_IMG='example/warehouse@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
export RECONCILE_IMG='example/reconcile@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
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
printf '%s\n' 'import test passed'
