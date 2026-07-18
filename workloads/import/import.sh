#!/usr/bin/env bash
# Portable, receipt-driven import orchestrator. See import-orchestration.md.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
RECEIPT_SCHEMA_VERSION=1
STATE_FILE=""
RUN_DIR=""
ATTEMPT_DIR=""
CURRENT_TASK=""

usage() {
  cat <<'EOF'
Usage:
  import.sh start
  import.sh resume --receipt <receipt.json>
  import.sh status --receipt <receipt.json>

All deployment configuration is supplied through environment variables. See
.env.example and import-orchestration.md. `start` creates a new import; it
never resumes a partially completed import.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

require_command() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }
require_var() { [[ -n "${!1:-}" ]] || die "required environment variable is missing: $1"; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

new_id() {
  local prefix="$1" now random
  now="$(date -u +%Y%m%dT%H%M%SZ)"
  random="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s_%s_%s' "$prefix" "$now" "$random"
}

is_digest_image() { [[ "$1" =~ @sha256:[[:xdigit:]]{64}$ ]]; }
is_env_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

# Newline-delimited values intentionally avoid shell word splitting and eval.
read_lines() {
  local value="${!1:-}" line
  [[ -n "$value" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && printf '%s\0' "$line"
  done <<<"$value"
}

read_nul_array() {
  local variable="$1"; local -n target="$2"; target=()
  while IFS= read -r -d '' value; do target+=("$value"); done < <(read_lines "$variable")
}

validate_runtime_list() {
  local tool="$1" env_var="${tool}_CONTAINER_ENV_NAMES" vol_var="${tool}_CONTAINER_VOLUMES"
  local arg_var="${tool}_CONTAINER_RUN_ARGS" entry
  local -a entries
  read_nul_array "$env_var" entries
  for entry in "${entries[@]}"; do
    is_env_name "$entry" || die "$env_var contains invalid environment name: $entry"
    [[ -n "${!entry:-}" ]] || die "$env_var requests unset environment variable: $entry"
  done
  read_nul_array "$vol_var" entries
  for entry in "${entries[@]}"; do
    [[ "$entry" == *:* ]] || die "$vol_var requires host:container[:options] entries"
  done
  read_nul_array "$arg_var" entries
  for entry in "${entries[@]}"; do
    [[ "$entry" != *$'\n'* ]] || die "$arg_var entries must each be one argument"
  done
}

validate_inputs() {
  require_command jq; require_command "$CONTAINER_RUNTIME"; require_command mktemp; require_command od
  for image in "$COLLECTOR_IMG" "$WAREHOUSE_IMG" "$RECONCILE_IMG"; do
    is_digest_image "$image" || die "image must be pinned by digest: $image"
  done
  for tool in COLLECTOR WAREHOUSE RECONCILE; do validate_runtime_list "$tool"; done
  [[ "$ARTIFACT_URI_PREFIX" != */ ]] || die "ARTIFACT_URI_PREFIX must not end in /"
  [[ -d "$ARTIFACT_HOST_ROOT" ]] || die "ARTIFACT_HOST_ROOT is not a directory: $ARTIFACT_HOST_ROOT"
  [[ -d "$RECEIPT_DIR" ]] || die "RECEIPT_DIR is not a directory: $RECEIPT_DIR"
}

require_config() {
  local name="$1" hash_name="${1}_SHA256" value="${!1}" supplied_hash="" computed
  if declare -p "$hash_name" >/dev/null 2>&1; then supplied_hash="${!hash_name}"; fi
  if [[ -n "$supplied_hash" ]]; then
    [[ "$supplied_hash" =~ ^[[:xdigit:]]{64}$ ]] || die "${name}_SHA256 must be a SHA-256 hex digest"
    printf '%s' "$supplied_hash"; return
  fi
  [[ -f "$value" ]] || die "$name is not a local file; provide ${name}_SHA256 for a logical URI"
  computed="$(sha256_file "$value")"
  printf '%s' "$computed"
}

uri_to_host_path() {
  local uri="$1" relative
  [[ "$uri" == "$ARTIFACT_URI_PREFIX"/* ]] || die "artifact URI is outside ARTIFACT_URI_PREFIX: $uri"
  relative="${uri#"$ARTIFACT_URI_PREFIX"/}"
  [[ "$relative" != *".."* ]] || die "artifact URI contains an unsafe path: $uri"
  printf '%s/%s' "${ARTIFACT_HOST_ROOT%/}" "$relative"
}

uri_to_container_path() {
  local tool="$1" uri="$2" prefix_var="${tool}_ARTIFACT_PATH_PREFIX" prefix relative
  prefix="${!prefix_var}"
  [[ "$uri" == "$ARTIFACT_URI_PREFIX"/* ]] || die "artifact URI is outside ARTIFACT_URI_PREFIX: $uri"
  relative="${uri#"$ARTIFACT_URI_PREFIX"/}"
  printf '%s/%s' "${prefix%/}" "$relative"
}

collector_artifact_uri_from_run_id() {
  local run_id="$1" filename="$2" label="$3" root="${ARTIFACT_HOST_ROOT%/}"
  local -a matches=()
  while IFS= read -r path; do
    [[ -n "$path" ]] && matches+=("$path")
  done < <(find "$root" -type f -path "*/${run_id}/_meta/${filename}" | sort)
  case "${#matches[@]}" in
    0) die "collector ${label} is unavailable through ARTIFACT_HOST_ROOT for run_id: $run_id" ;;
    1) ;;
    *) die "multiple collector ${label}s found through ARTIFACT_HOST_ROOT for run_id: $run_id" ;;
  esac
  local relative="${matches[0]#"$root"/}"
  printf '%s/%s' "$ARTIFACT_URI_PREFIX" "$relative"
}

json_quote_lines() {
  local variable="$1"; local -a values; read_nul_array "$variable" values
  printf '%s\0' "${values[@]:-}" | jq -Rs 'split("\u0000") | map(select(length > 0))'
}

state_update() {
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "${RUN_DIR}/.state.XXXXXX")"
  jq "$filter" "$@" "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

publish_receipt() {
  local sequence receipt tmp latest_tmp
  sequence="$(jq -r '.receipt_sequence + 1' "$STATE_FILE")"
  state_update '.receipt_sequence = $n | .updated_at = $now' --argjson n "$sequence" --arg now "$(date -u +%FT%TZ)"
  receipt="${RUN_DIR}/receipt.${sequence}.json"
  tmp="${receipt}.tmp.$$"
  cp "$STATE_FILE" "$tmp"
  mv "$tmp" "$receipt"
  latest_tmp="${RUN_DIR}/latest.tmp.$$"
  printf '%s\n' "$(basename "$receipt")" >"$latest_tmp"
  mv "$latest_tmp" "${RUN_DIR}/latest"
  printf '%s\n' "$receipt"
}

record_event() {
  local task="$1" status="$2" result="$3" log="$4" exit_code="$5" message="${6:-}"
  state_update '.tasks[$task] = ((.tasks[$task] // {}) + {status:$status, result:$result, log:$log, exit_code:$exit, updated_at:$now, message:$message})' \
    --arg task "$task" --arg status "$status" --arg result "$result" --arg log "$log" \
    --argjson exit "$exit_code" --arg now "$(date -u +%FT%TZ)" --arg message "$message"
  publish_receipt >/dev/null
}

redacted_command() {
  local tool="$1" image="$2" value destination mounts_json; local -a envs vols args destinations
  read_nul_array "${tool}_CONTAINER_ENV_NAMES" envs
  read_nul_array "${tool}_CONTAINER_VOLUMES" vols
  read_nul_array "${tool}_CONTAINER_RUN_ARGS" args
  for value in "${vols[@]}"; do
    destination="${value#*:}"
    destination="${destination%%:*}"
    destinations+=("$destination")
  done
  mounts_json="$(printf '%s\0' "${destinations[@]:-}" | jq -Rs 'split("\u0000") | map(select(length > 0))')"
  jq -cn --arg runtime "$CONTAINER_RUNTIME" --arg image "$image" \
    --argjson envs "$(json_quote_lines "${tool}_CONTAINER_ENV_NAMES")" \
    --argjson mount_destinations "$mounts_json" --argjson run_arg_count "${#args[@]}" \
    '{runtime:$runtime,image:$image,remove:true,environment_names:$envs,mount_destinations:$mount_destinations,run_arg_count:$run_arg_count}'
}

run_container() {
  local tool="$1" image="$2"; shift 2
  local -a envs vols args command_args
  read_nul_array "${tool}_CONTAINER_ENV_NAMES" envs
  read_nul_array "${tool}_CONTAINER_VOLUMES" vols
  read_nul_array "${tool}_CONTAINER_RUN_ARGS" args
  read_nul_array "${tool}_COMMAND_ARGS" command_args
  local -a command=("$CONTAINER_RUNTIME" run --rm)
  command+=("${args[@]}")
  local value
  for value in "${envs[@]}"; do command+=(--env "$value"); done
  for value in "${vols[@]}"; do command+=(--volume "$value"); done
  command+=("$image" "${command_args[@]}" "$@")
  "${command[@]}"
}

run_task() {
  local task="$1" tool="$2" image="$3"; shift 3
  local stamp result log start end code command_json
  CURRENT_TASK="$task"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  ATTEMPT_DIR="${RUN_DIR}/attempts/${task}/${stamp}"
  mkdir -p "$ATTEMPT_DIR"
  result="${ATTEMPT_DIR}/result.json"; log="${ATTEMPT_DIR}/stderr.log"
  start="$(date -u +%FT%TZ)"; command_json="$(redacted_command "$tool" "$image")"
  set +e
  run_container "$tool" "$image" "$@" >"$result" 2>"$log"
  code=$?
  set -e
  end="$(date -u +%FT%TZ)"
  if (( code != 0 )); then
    record_event "$task" failed "$result" "$log" "$code" "container command failed"
    note "$task failed; see ${RUN_DIR}/latest"; return "$code"
  fi
  jq -e 'type == "object"' "$result" >/dev/null 2>&1 || {
    record_event "$task" failed "$result" "$log" 0 "stdout must be one JSON object"
    die "$task emitted non-JSON or mixed stdout"
  }
  jq --arg task "$task" --arg start "$start" --arg end "$end" --argjson command "$command_json" \
    '.tasks[$task] += {started_at:$start, ended_at:$end, command:$command}' "$STATE_FILE" >"${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  TASK_RESULT="$result"; TASK_LOG="$log"
}

assert_json() {
  local file="$1" message filter count; shift
  local -a args=("$@")
  count="${#args[@]}"
  (( count >= 2 )) || die "internal error: assert_json requires a filter and message"
  message="${args[$((count - 1))]}"; filter="${args[$((count - 2))]}"
  jq -e "${args[@]:0:$((count - 2))}" "$filter" "$file" >/dev/null 2>&1 && return
  if [[ -n "$CURRENT_TASK" && -n "${TASK_RESULT:-}" && -n "${TASK_LOG:-}" ]]; then
    record_event "$CURRENT_TASK" failed "$TASK_RESULT" "$TASK_LOG" 0 "$message"
  fi
  die "$message ($file)"
}

check_manifest() {
  local manifest_uri="$1" collector_run_id="$2" manifest_host manifest_hash output_count
  manifest_host="$(uri_to_host_path "$manifest_uri")"
  [[ -f "$manifest_host" ]] || die "collector manifest is unavailable through ARTIFACT_HOST_ROOT: $manifest_uri"
  manifest_hash="$(sha256_file "$manifest_host")"
  assert_json "$manifest_host" --arg run "$collector_run_id" '.run_id == $run and (.outputs | type == "array" and length > 0)' "invalid collector manifest"
  output_count="$(jq '.outputs | length' "$manifest_host")"
  jq -e '[.outputs[] | [(.spec_identity // ""), (.connection_ref // ""), (.stream_id // "")] | join("\u0000")] | length == (unique | length)' "$manifest_host" >/dev/null || die "manifest contains duplicate stream identities"
  state_update '.collector.manifest = {uri:$uri, sha256:$sha, output_count:$count}' --arg uri "$manifest_uri" --arg sha "$manifest_hash" --argjson count "$output_count"
}

collector_stage() {
  run_task collect COLLECTOR "$COLLECTOR_IMG" run --spec "$COLLECTOR_SPEC" --connection-catalog "$CONNECTION_CATALOG" --root-uri "$COLLECTOR_ROOT_URI"
  assert_json "$TASK_RESULT" '.run_id | type == "string" and length > 0' "collector result is missing run_id"
  assert_json "$TASK_RESULT" '(.status // .report.status) == "SUCCESS"' "collector result is not successful"
  local run_id manifest_uri report_uri report_hash
  run_id="$(jq -r '.run_id' "$TASK_RESULT")"
  manifest_uri="$(jq -r '.manifest.uri // empty' "$TASK_RESULT")"
  [[ -n "$manifest_uri" ]] || manifest_uri="$(collector_artifact_uri_from_run_id "$run_id" run.manifest.json manifest)"
  report_uri="$(jq -r '.report.uri // empty' "$TASK_RESULT")"
  [[ -n "$report_uri" ]] || report_uri="$(collector_artifact_uri_from_run_id "$run_id" run.report.json report)"
  local report_host; report_host="$(uri_to_host_path "$report_uri")"
  [[ -f "$report_host" ]] || die "collector report is unavailable through ARTIFACT_HOST_ROOT: $report_uri"
  report_hash="$(sha256_file "$report_host")"
  assert_json "$report_host" '.status == "SUCCESS"' "authoritative collector report is not successful"
  state_update '.collector = {run_id:$run, result:$result, report:{uri:$report_uri,sha256:$report_hash}}' --arg run "$run_id" --arg result "$TASK_RESULT" --arg report_uri "$report_uri" --arg report_hash "$report_hash"
  check_manifest "$manifest_uri" "$run_id"
  record_event collect succeeded "$TASK_RESULT" "$TASK_LOG" 0 "collector report and manifest passed"
}

bronze_stage() {
  local run_id manifest_uri manifest_path manifest_hash
  run_id="$(jq -r '.collector.run_id' "$STATE_FILE")"; manifest_uri="$(jq -r '.collector.manifest.uri' "$STATE_FILE")"
  manifest_hash="$(jq -r '.collector.manifest.sha256' "$STATE_FILE")"; manifest_path="$(uri_to_container_path WAREHOUSE "$manifest_uri")"
  run_task bronze_register WAREHOUSE "$WAREHOUSE_IMG" bronze register-manifest --wiring "$WAREHOUSE_WIRING" --workspace-id "$WORKSPACE_ID" --run-id "$run_id" --manifest "$manifest_path"
  assert_json "$TASK_RESULT" --arg run "$run_id" --arg hash "$manifest_hash" '.run_id == $run and ((.manifest_sha256 // .manifest_hash) | sub("^sha256:"; "")) == $hash' "Bronze manifest registration does not match receipt"
  record_event bronze_register succeeded "$TASK_RESULT" "$TASK_LOG" 0 "manifest registered"
  run_task bronze_stage WAREHOUSE "$WAREHOUSE_IMG" bronze stage-run --wiring "$WAREHOUSE_WIRING" --workspace-id "$WORKSPACE_ID" --run-id "$run_id"
  assert_json "$TASK_RESULT" --arg run "$run_id" '.run_id == $run and ((.staging_ref // .staging_evidence) != null) and ((.staging_hash // .staging_sha256) != null)' "Bronze staging evidence is missing or mismatched"
  record_event bronze_stage succeeded "$TASK_RESULT" "$TASK_LOG" 0 "staging evidence recorded"
  run_task bronze_commit WAREHOUSE "$WAREHOUSE_IMG" bronze commit-run --wiring "$WAREHOUSE_WIRING" --workspace-id "$WORKSPACE_ID" --run-id "$run_id"
  assert_json "$TASK_RESULT" --arg ws "$WORKSPACE_ID" --arg run "$run_id" '(.workspace_id // .workspace) == $ws and .run_id == $run and (.state // .status) == "COMMITTED"' "Bronze run is not committed"
  record_event bronze_commit succeeded "$TASK_RESULT" "$TASK_LOG" 0 "Bronze committed"
}

silver_stage() {
  local bronze_run intents_uri intents_path count hash silver_run
  bronze_run="$(jq -r '.collector.run_id' "$STATE_FILE")"; silver_run="$(jq -r '.silver.run_id' "$STATE_FILE")"
  intents_uri="${INTENTS_URI:-${ARTIFACT_URI_PREFIX}/intents/${silver_run}.jsonl}"
  intents_path="$(uri_to_container_path WAREHOUSE "$intents_uri")"
  mkdir -p "$(dirname "$(uri_to_host_path "$intents_uri")")"
  run_task silver WAREHOUSE "$WAREHOUSE_IMG" silver run --wiring "$WAREHOUSE_WIRING" --workspace-id "$WORKSPACE_ID" --system-instance-id "$SYSTEM_INSTANCE_ID" --bronze-run-id "$bronze_run" --flow-spec "$FLOW_SPEC" --banding-spec "$BANDING_SPEC" --run-id "$silver_run" --intents-output-path "$intents_path"
  assert_json "$TASK_RESULT" --arg run "$silver_run" '.run_id == $run and .status == "intents_emitted" and (.mapper_handoff.status // .mapper_handoff.emission_status) == "succeeded"' "Silver did not emit a successful handoff for the preallocated run"
  local host; host="$(uri_to_host_path "$intents_uri")"; [[ -f "$host" ]] || die "Silver intent JSONL is unavailable through ARTIFACT_HOST_ROOT"
  count="$(awk 'END { print NR + 0 }' "$host")"; hash="$(sha256_file "$host")"
  assert_json "$TASK_RESULT" --argjson count "$count" '(.mapper_handoff.intents_emitted | tonumber) == $count' "Silver reported an intent count different from frozen JSONL"
  state_update '.silver += {result:$result, status:"intents_emitted", lock_owner:$run, intents:{uri:$uri,sha256:$hash,count:$count}}' --arg result "$TASK_RESULT" --arg run "$silver_run" --arg uri "$intents_uri" --arg hash "$hash" --argjson count "$count"
  record_event silver succeeded "$TASK_RESULT" "$TASK_LOG" 0 "intents frozen and lock retained"
}

reconcile_stage() {
  local intents_uri intents_path count hash current_hash group validate_result
  intents_uri="$(jq -r '.silver.intents.uri' "$STATE_FILE")"; count="$(jq -r '.silver.intents.count' "$STATE_FILE")"; hash="$(jq -r '.silver.intents.sha256' "$STATE_FILE")"
  local host; host="$(uri_to_host_path "$intents_uri")"; [[ -f "$host" ]] || die "frozen intent file is missing"
  current_hash="$(sha256_file "$host")"; [[ "$current_hash" == "$hash" ]] || die "frozen intent file hash changed; refusing reconciliation"
  [[ "$(awk 'END { print NR + 0 }' "$host")" == "$count" ]] || die "frozen intent file count changed; refusing reconciliation"
  intents_path="$(uri_to_container_path RECONCILE "$intents_uri")"; group="$(jq -r '.reconciliation.execution_group' "$STATE_FILE")"
  if (( count == 0 )); then
    state_update '.reconciliation += {validation:{status:"noop",processed:0}, run:{status:"noop",processed:0,errors:0}}'
    record_event reconcile_validate succeeded "" "" 0 "explicit zero-intent no-op"
    record_event reconcile_run succeeded "" "" 0 "explicit zero-intent no-op"
    publish_receipt >/dev/null; return
  fi
  run_task reconcile_validate RECONCILE "$RECONCILE_IMG" --wiring "$RECONCILE_WIRING" validate --intents "$intents_path" --target-ref "$TARGET_REF" --execution-group "$group" --max-intents "$count"
  assert_json "$TASK_RESULT" --argjson count "$count" '.ok == true and ((.summary.processed // .processed) | tonumber) == $count' "Reconciliation validation did not process the complete frozen intent set"
  record_event reconcile_validate succeeded "$TASK_RESULT" "$TASK_LOG" 0 "complete frozen JSONL validated"
  validate_result="$TASK_RESULT"
  run_task reconcile_run RECONCILE "$RECONCILE_IMG" --wiring "$RECONCILE_WIRING" run --intents "$intents_path" --target-ref "$TARGET_REF" --execution-group "$group" --max-intents "$count"
  assert_json "$TASK_RESULT" --argjson count "$count" '(.summary.processed // .processed | tonumber) == $count and (.summary.errors // .errors // 0 | tonumber) == 0' "Reconciliation did not successfully process every intent"
  record_event reconcile_run succeeded "$TASK_RESULT" "$TASK_LOG" 0 "reconciliation run completed"
  run_task reconciliation_evidence RECONCILE "$RECONCILE_IMG" --wiring "$RECONCILE_WIRING" get execution-group --workspace-id "$WORKSPACE_ID" --target-ref "$TARGET_REF" --execution-group "$group"
  assert_json "$TASK_RESULT" --argjson count "$count" '(.counts.attempted // .attempted | tonumber) == $count and (.counts.succeeded // .succeeded | tonumber) == $count and ((.counts.failed // .failed // 0) | tonumber) == 0 and (.group_outcome == "succeeded" or .fully_succeeded == true)' "execution-group evidence is incomplete"
  if [[ "$COMPLETION_POLICY" == "observed_converged" ]]; then
    assert_json "$TASK_RESULT" '(.summary.converged // .converged // false) == true' "execution-group lacks converged observation evidence"
  fi
  record_event reconciliation_evidence succeeded "$TASK_RESULT" "$TASK_LOG" 0 "durable execution-group evidence accepted"
}

finalize_stage() {
  local run; run="$(jq -r '.silver.run_id' "$STATE_FILE")"
  run_task silver_finalize WAREHOUSE "$WAREHOUSE_IMG" silver finalize --wiring "$WAREHOUSE_WIRING" --workspace-id "$WORKSPACE_ID" --run-id "$run"
  assert_json "$TASK_RESULT" --arg run "$run" --arg ws "$WORKSPACE_ID" '.run_id == $run and .workspace_id == $ws and .status == "ok"' "Silver finalization did not complete the expected run"
  record_event silver_finalize succeeded "$TASK_RESULT" "$TASK_LOG" 0 "Silver completed and lock released"
  state_update '.status = "completed" | .completed_at = $now' --arg now "$(date -u +%FT%TZ)"
  publish_receipt >/dev/null
}

task_status() { jq -r --arg task "$1" '.tasks[$task].status // "pending"' "$STATE_FILE"; }

run_pipeline() {
  local failed
  failed="$(jq -r '.tasks | to_entries[]? | select(.value.status == "failed") | .key' "$STATE_FILE" | head -n 1)"
  [[ -z "$failed" ]] || die "receipt records a failed or uncertain task ($failed); inspect subsystem state with its supported read-only adapter before resuming"
  [[ "$(task_status collect)" == succeeded ]] || collector_stage
  [[ "$(task_status bronze_register)" == succeeded && "$(task_status bronze_stage)" == succeeded && "$(task_status bronze_commit)" == succeeded ]] || bronze_stage
  [[ "$(task_status silver)" == succeeded ]] || silver_stage
  if [[ "$(jq -r '.silver.intents.count' "$STATE_FILE")" == 0 ]]; then
    [[ "$(task_status reconcile_run)" == succeeded ]] || reconcile_stage
  else
    [[ "$(task_status reconciliation_evidence)" == succeeded ]] || reconcile_stage
  fi
  [[ "$(task_status silver_finalize)" == succeeded ]] || finalize_stage
}

init_state() {
  local config_json collector_hash catalog_hash warehouse_hash flow_hash banding_hash reconcile_hash
  collector_hash="$(require_config COLLECTOR_SPEC)"; catalog_hash="$(require_config CONNECTION_CATALOG)"; warehouse_hash="$(require_config WAREHOUSE_WIRING)"; flow_hash="$(require_config FLOW_SPEC)"; banding_hash="$(require_config BANDING_SPEC)"; reconcile_hash="$(require_config RECONCILE_WIRING)"
  config_json="$(jq -cn --arg collector_ref "$COLLECTOR_SPEC" --arg collector_sha "$collector_hash" --arg catalog_ref "$CONNECTION_CATALOG" --arg catalog_sha "$catalog_hash" --arg warehouse_ref "$WAREHOUSE_WIRING" --arg warehouse_sha "$warehouse_hash" --arg flow_ref "$FLOW_SPEC" --arg flow_sha "$flow_hash" --arg banding_ref "$BANDING_SPEC" --arg banding_sha "$banding_hash" --arg reconcile_ref "$RECONCILE_WIRING" --arg reconcile_sha "$reconcile_hash" '{collector_spec:{ref:$collector_ref,sha256:$collector_sha},connection_catalog:{ref:$catalog_ref,sha256:$catalog_sha},warehouse_wiring:{ref:$warehouse_ref,sha256:$warehouse_sha},flow_spec:{ref:$flow_ref,sha256:$flow_sha},banding_spec:{ref:$banding_ref,sha256:$banding_sha},reconcile_wiring:{ref:$reconcile_ref,sha256:$reconcile_sha}}')"
  jq -cn --argjson version "$RECEIPT_SCHEMA_VERSION" --arg orchestration "$ORCHESTRATION_RUN_ID" --arg silver "$SILVER_RUN_ID" --arg tenant "$TENANT_ID" --arg environment "$ENVIRONMENT" --arg workspace "$WORKSPACE_ID" --arg system "$SYSTEM_INSTANCE_ID" --arg target "$TARGET_REF" --arg collector_img "$COLLECTOR_IMG" --arg warehouse_img "$WAREHOUSE_IMG" --arg reconcile_img "$RECONCILE_IMG" --arg group "silver/$SILVER_RUN_ID" --arg policy "$COMPLETION_POLICY" --arg now "$(date -u +%FT%TZ)" --argjson config "$config_json" \
    '{schema_version:$version,receipt_sequence:0,status:"running",orchestration_run_id:$orchestration,created_at:$now,updated_at:$now,identity:{tenant_id:$tenant,environment:$environment,workspace_id:$workspace,system_instance_id:$system,target_ref:$target},images:{collector:$collector_img,warehouse:$warehouse_img,reconciliation:$reconcile_img},configuration:$config,collector:{},silver:{run_id:$silver},reconciliation:{execution_group:$group,completion_policy:$policy},tasks:{}}' >"$STATE_FILE"
  publish_receipt >/dev/null
}

load_state() {
  local receipt="$1"
  [[ -f "$receipt" ]] || die "receipt does not exist: $receipt"
  RUN_DIR="$(cd "$(dirname "$receipt")" && pwd)"; STATE_FILE="${RUN_DIR}/state.resume.$$.json"
  cp "$receipt" "$STATE_FILE"
  ORCHESTRATION_RUN_ID="$(jq -r '.orchestration_run_id' "$STATE_FILE")"; SILVER_RUN_ID="$(jq -r '.silver.run_id' "$STATE_FILE")"
  TENANT_ID="$(jq -r '.identity.tenant_id' "$STATE_FILE")"; ENVIRONMENT="$(jq -r '.identity.environment' "$STATE_FILE")"; WORKSPACE_ID="$(jq -r '.identity.workspace_id' "$STATE_FILE")"; SYSTEM_INSTANCE_ID="$(jq -r '.identity.system_instance_id' "$STATE_FILE")"; TARGET_REF="$(jq -r '.identity.target_ref' "$STATE_FILE")"
}

preflight_stage() {
  local inspect_log="${RUN_DIR}/preflight-image-inspect.json"
  "$CONTAINER_RUNTIME" image inspect "$COLLECTOR_IMG" "$WAREHOUSE_IMG" "$RECONCILE_IMG" >"$inspect_log" 2>&1 || die "one or more configured images are unavailable to $CONTAINER_RUNTIME"
  record_event preflight succeeded "$inspect_log" "$inspect_log" 0 "configuration, artifact storage, and image availability verified"
}

main() {
  local action="${1:-}" receipt=""
  case "$action" in
    start) shift ;;
    resume|status) shift; [[ "${1:-}" == "--receipt" && -n "${2:-}" ]] || { usage >&2; exit 2; }; receipt="$2"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
  (( $# == 0 )) || die "unexpected arguments: $*"
  if [[ "$action" == status ]]; then
    load_state "$receipt"
    jq '{orchestration_run_id,status,identity,silver,reconciliation,tasks,updated_at}' "$STATE_FILE"
    return
  fi
  : "${CONTAINER_RUNTIME:=podman}"; : "${COMPLETION_POLICY:=observed_converged}"
  for var in TENANT_ID ENVIRONMENT WORKSPACE_ID SYSTEM_INSTANCE_ID TARGET_REF COLLECTOR_IMG WAREHOUSE_IMG RECONCILE_IMG RECEIPT_DIR ARTIFACT_URI_PREFIX ARTIFACT_HOST_ROOT COLLECTOR_ARTIFACT_PATH_PREFIX WAREHOUSE_ARTIFACT_PATH_PREFIX RECONCILE_ARTIFACT_PATH_PREFIX COLLECTOR_SPEC CONNECTION_CATALOG COLLECTOR_ROOT_URI WAREHOUSE_WIRING FLOW_SPEC BANDING_SPEC RECONCILE_WIRING; do require_var "$var"; done
  validate_inputs
  if [[ "$action" == start ]]; then
    ORCHESTRATION_RUN_ID="${ORCHESTRATION_RUN_ID:-$(new_id import)}"; SILVER_RUN_ID="${SILVER_RUN_ID:-$(new_id silver)}"; RUN_DIR="${RECEIPT_DIR%/}/${ORCHESTRATION_RUN_ID}"
    [[ ! -e "$RUN_DIR" ]] || die "receipt directory already exists: $RUN_DIR (use resume)"
    mkdir -p "$RUN_DIR/attempts"; STATE_FILE="$RUN_DIR/state.json"; init_state; preflight_stage
  else
    load_state "$receipt"
    [[ "$(jq -r '.status' "$STATE_FILE")" != completed ]] || { note "import is already completed"; return; }
  fi
  run_pipeline
  note "completed import ${ORCHESTRATION_RUN_ID}; receipt: $(cat "${RUN_DIR}/latest")"
}

main "$@"
