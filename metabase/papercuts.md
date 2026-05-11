# paper cuts we need to solve before prod

## to solve

## solved

1. "filter by column" on Who Works Here tables
   - added `Department` filter on `identity_roster` (field-backed search, maps to `identities.department`)
   - added `Account Source` and `Account Status` filters on the accounts table (field-backed search, maps to `accounts.source` and `accounts.status`)

2. identity emails list with search in `common_entitlements`
   - changed `Identity Emails` dashboard parameter to `isMultiSelect = true` with `values_source_type = "field"` backed by `identities.email`
   - Metabase joins multi-select picks with commas, which feeds directly into the existing `STRING_TO_ARRAY({{identity_emails}}, ',')` SQL

3. entitlements catalog: sensitivity filter + source drill-down
   - new auxiliary card `sensitivity_values` queries `DISTINCT attributes->>'sensitivity'` and powers the dropdown
   - `Sensitivity` dashboard parameter uses `values_source_type = "card"` pointing to that auxiliary card
   - `Source` dashboard parameter uses `values_source_type = "field"` backed by `entitlements.source`
   - both map to new `[[AND ...]]` optional clauses in the catalog SQL

4. common entitlements between a group of identities
   - new card `common_entitlements` + dashboard "Common Entitlements"
   - native SQL uses `CROSS JOIN LATERAL audit.get_identity_access_snapshot` for each email in a comma-separated input; HAVING filters to entitlements shared by every identity
   - 1.1 source level drill down: rows broken out by `via_source`; optional Source filter parameter on the dashboard

2. add search to tables
   - added `parameters_json` with `string/contains` parameters to the "Who Works Here" dashboard
   - "Search Identity" maps to `display_name` on the identity_roster card
   - "Search Account" maps to `username` on the active accounts card

3. add descriptions and sensitivity to entitlements
   - new card `entitlements_catalog` + dashboard "Entitlements Catalog"
   - native SQL extracts `attributes->>'description'` and `attributes->>'sensitivity'` from the JSONB column
   - optional Search filter on the dashboard filters by name/display_name

4. entitlements delta between 2 dates with source drill down
   - new card `access_changes_between_dates` + dashboard "Access Changes Between Dates"
   - uses existing `audit.compare_access_between_dates(start, end)` function (see suggestion.md for caveats)
   - dashboard parameters: Start Date, End Date, optional Identity Email, Source (dropdown), Change Type (ADDED/REMOVED dropdown)
