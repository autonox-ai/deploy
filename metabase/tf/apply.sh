#!/usr/bin/env bash
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse credentials from tfvars
METABASE_HOST=$(grep 'metabase_host' terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
METABASE_USER=$(grep 'metabase_username' terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')
METABASE_PASS=$(grep 'metabase_password' terraform.tfvars | sed 's/.*= *"\(.*\)"/\1/')

echo "==> Applying database resource..."
terraform apply -target=metabase_database.postgres -auto-approve

DB_ID=$(terraform show -json | python3 -c "
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
terraform apply -auto-approve
