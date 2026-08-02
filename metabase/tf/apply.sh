#!/usr/bin/env bash
set -euo pipefail

# Applies the Metabase Terraform project in the order the provider needs: the
# database resource first, then a schema sync, then everything else.
#
# Nothing here writes into this repository. Customer config is read from
# $AUTONOX_HOME/metabase.tfvars (override with METABASE_TFVARS), and
# Terraform's working directory and state go to $AUTONOX_HOME/var/tf/metabase
# (override with METABASE_TF_ROOT).

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${METABASE_TFVARS:-}" && -z "${AUTONOX_HOME:-}" ]]; then
  echo "ERROR: set AUTONOX_HOME (config lives in \$AUTONOX_HOME/metabase.tfvars)" >&2
  exit 2
fi

TFVARS="${METABASE_TFVARS:-${AUTONOX_HOME}/metabase.tfvars}"
if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: no tfvars at $TFVARS" >&2
  echo "       cp ${TF_DIR}/terraform.tfvars.example \"$TFVARS\" && chmod 600 \"$TFVARS\"" >&2
  exit 2
fi

# State records the Metabase admin and bireader passwords in cleartext, so it
# lives beside the configuration it came from, not in the vendor tree.
TF_ROOT="${METABASE_TF_ROOT:-${AUTONOX_HOME:?set AUTONOX_HOME or METABASE_TF_ROOT}/var/tf/metabase}"
export TF_DATA_DIR="${TF_ROOT}/.terraform"
STATE_PATH="${TF_ROOT}/terraform.tfstate"
mkdir -p "$TF_ROOT"

if [[ ! -d "$TF_DATA_DIR" ]]; then
  echo "==> Initializing Terraform (state: ${STATE_PATH})..."
  terraform -chdir="$TF_DIR" init -input=false \
    -backend-config="path=${STATE_PATH}"
fi

# Parse credentials from tfvars
METABASE_HOST=$(grep 'metabase_host' "$TFVARS" | sed 's/.*= *"\(.*\)"/\1/')
METABASE_USER=$(grep 'metabase_username' "$TFVARS" | sed 's/.*= *"\(.*\)"/\1/')
METABASE_PASS=$(grep 'metabase_password' "$TFVARS" | sed 's/.*= *"\(.*\)"/\1/')

echo "==> Applying database resource..."
terraform -chdir="$TF_DIR" apply -var-file="$TFVARS" \
  -target=metabase_database.postgres -auto-approve

DB_ID=$(terraform -chdir="$TF_DIR" show -json | python3 -c "
import sys, json
state = json.load(sys.stdin)
for r in state['values']['root_module']['resources']:
    if r['type'] == 'metabase_database':
        print(r['values']['id'])
        break
")
echo "==> Database ID: $DB_ID"

TOKEN=$(curl -sf -X POST "${METABASE_HOST}/api/session" \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"${METABASE_USER}\", \"password\": \"${METABASE_PASS}\"}" \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

echo "==> Triggering schema sync..."
curl -sf -X POST "${METABASE_HOST}/api/database/${DB_ID}/sync_schema" \
  -H "X-Metabase-Session: $TOKEN" > /dev/null

echo "==> Waiting for bi_views tables to appear..."
for i in $(seq 1 40); do
  FOUND=$(curl -sf "${METABASE_HOST}/api/database/${DB_ID}/schema/bi_views" \
    -H "X-Metabase-Session: $TOKEN" \
    | python3 -c "
import sys, json
tables = json.load(sys.stdin)
names = {t['name'] for t in tables}
needed = {'active_identities', 'accounts', 'entitlements', 'entitlement_relations', 'identity_entitlements', 'orphaned_accounts'}
print('yes' if needed.issubset(names) else 'no')
" 2>/dev/null || echo "no")

  if [ "$FOUND" = "yes" ]; then
    echo "==> Sync complete!"
    break
  fi

  echo "    Waiting for sync... ($i/40)"
  sleep 3

  if [ "$i" -eq 40 ]; then
    echo "ERROR: Timed out waiting for table sync"
    exit 1
  fi
done

echo "==> Applying remaining resources..."
terraform -chdir="$TF_DIR" apply -var-file="$TFVARS" -auto-approve
