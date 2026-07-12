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

if [[ "$image" == *collectors* ]]; then
  printf '%s\n' '{"run_id":"collector-1","status":"SUCCESS","report":{"status":"SUCCESS","uri":"shared://test/meta/report.json"},"manifest":{"uri":"shared://test/meta/manifest.json"}}'
elif [[ "$joined" == *'bronze register-manifest'* ]]; then
  hash="$(shasum -a 256 "${ARTIFACT_HOST_ROOT}/meta/manifest.json" | awk '{print $1}')"
  printf '{"workspace_id":"ws","run_id":"collector-1","manifest_sha256":"%s"}\n' "$hash"
elif [[ "$joined" == *'bronze stage-run'* ]]; then
  printf '%s\n' '{"workspace_id":"ws","run_id":"collector-1","staging_evidence":{"ok":true}}'
elif [[ "$joined" == *'bronze commit-run'* ]]; then
  printf '%s\n' '{"workspace_id":"ws","run_id":"collector-1","state":"COMMITTED"}'
elif [[ "$joined" == *'silver run'* ]]; then
  for i in "${!command[@]}"; do [[ "${command[$i]}" == --run-id ]] && silver="${command[$((i + 1))]}"; done
  mkdir -p "${ARTIFACT_HOST_ROOT}/intents"
  printf '%s\n%s\n' '{"intent":"one"}' '{"intent":"two"}' >"${ARTIFACT_HOST_ROOT}/intents/${silver}.jsonl"
  printf '{"run_id":"%s","status":"intents_emitted","mapper_handoff":{"status":"succeeded","intents_emitted":2}}\n' "$silver"
elif [[ "$joined" == *'validate'* ]]; then
  printf '%s\n' '{"ok":true,"processed":2}'
elif [[ "$joined" == *' get execution-group '* ]]; then
  printf '%s\n' '{"summary":{"processed":2,"errors":0,"converged":true}}'
elif [[ "$joined" == *' run '* ]]; then
  printf '%s\n' '{"summary":{"processed":2,"errors":0}}'
elif [[ "$joined" == *'silver finalize'* ]]; then
  for i in "${!command[@]}"; do [[ "${command[$i]}" == --run-id ]] && silver="${command[$((i + 1))]}"; done
  printf '{"run_id":"%s","state":"completed"}\n' "$silver"
else
  printf '%s\n' "unexpected command: $joined" >&2
  exit 66
fi
