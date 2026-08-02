#!/usr/bin/env bash

set -Eeuo pipefail

printf '%s\n' "$*" >>"${FAKE_RUNTIME_LOG}"
if [[ "${1:-}" == image && "${2:-}" == inspect ]]; then
  printf '%s\n' '[]'
  exit 0
fi

[[ "${1:-}" == run ]] || exit 64
shift
args=("$@")
image_index=-1
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == *@sha256:* ]]; then image_index="$i"; break; fi
done
(( image_index >= 0 )) || exit 65
image="${args[$image_index]}"
command=("${args[@]:$((image_index + 1))}")
joined="${command[*]}"

# Fail the one command whose joined form contains FAKE_RUNTIME_FAIL, so tests
# can drive the driver's failure and retry paths.
if [[ -n "${FAKE_RUNTIME_FAIL:-}" && "$joined" == *"${FAKE_RUNTIME_FAIL}"* ]]; then
  printf '%s\n' '{"error":"ERR_INJECTED","detail":"fake runtime failure"}' >&2
  exit 70
fi

if [[ "$image" == *collectors* ]]; then
  collector_root="${ARTIFACT_HOST_ROOT}/collector.postgres.v1/mock-collector/default/collector-1/_meta"
  mkdir -p "$collector_root"
  printf '%s\n' '{"status":"SUCCESS"}' >"${collector_root}/run.report.json"
  printf '%s\n' '{"run_id":"collector-1","outputs":[{"spec_identity":"collector.postgres.v1/mock-collector/default","connection_ref":"oracle","stream_id":"people"},{"spec_identity":"collector.postgres.v1/mock-collector/default","connection_ref":"oracle","stream_id":"groups"}]}' >"${collector_root}/run.manifest.json"
  printf '%s\n' '{"run_id":"collector-1","status":"SUCCESS","report":{"status":"SUCCESS"}}'
elif [[ "$joined" == *'bronze register-manifest'* ]]; then
  hash="$(shasum -a 256 "${ARTIFACT_HOST_ROOT}/collector.postgres.v1/mock-collector/default/collector-1/_meta/run.manifest.json" | awk '{print $1}')"
  # Warehouse prefixes hashes with the algorithm; keep it so the driver's
  # sha256: stripping stays exercised.
  printf '{"workspace_id":"ws","run_id":"collector-1","manifest_hash":"sha256:%s"}\n' "$hash"
elif [[ "$joined" == *'bronze stage-run'* ]]; then
  printf '%s\n' '{"workspace_id":"ws","run_id":"collector-1","staging_ref":"file:///tmp/bronze-staging-collector-1.json","staging_hash":"sha256:02718aad7b2ecc3c3c541d7163c68eb41240c0f0fcf7d717cb8ccc8bf943b086","state":"PENDING"}'
elif [[ "$joined" == *'bronze commit-run'* ]]; then
  printf '%s\n' '{"workspace_id":"ws","run_id":"collector-1","state":"COMMITTED"}'
elif [[ "$joined" == *'silver run'* ]]; then
  for i in "${!command[@]}"; do [[ "${command[$i]}" == --run-id ]] && silver="${command[$((i + 1))]}"; done
  mkdir -p "${ARTIFACT_HOST_ROOT}/intents"
  printf '%s\n%s\n' '{"intent":"one"}' '{"intent":"two"}' >"${ARTIFACT_HOST_ROOT}/intents/${silver}.jsonl"
  printf '{"run_id":"%s","status":"intents_emitted","mapper_handoff":{"attempted":true,"emission_status":"succeeded","intents_emitted":2}}\n' "$silver"
elif [[ "$joined" == *'validate'* ]]; then
  printf '%s\n' '{"ok":true,"stage":"validate","summary":{"processed":2,"failed":0}}'
elif [[ "$joined" == *' get execution-group '* ]]; then
  printf '%s\n' '{"group_outcome":"succeeded","fully_succeeded":true,"counts":{"planned":2,"attempted":2,"succeeded":2,"failed":0,"unknown":0},"summary":{"converged":true}}'
elif [[ "$joined" == *' run '* ]]; then
  printf '%s\n' '{"summary":{"processed":2,"errors":0}}'
elif [[ "$joined" == *'silver finalize'* ]]; then
  for i in "${!command[@]}"; do [[ "${command[$i]}" == --run-id ]] && silver="${command[$((i + 1))]}"; done
  printf '{"run_id":"%s","status":"ok","workspace_id":"ws"}\n' "$silver"
else
  printf '%s\n' "unexpected command: $joined" >&2
  exit 66
fi
