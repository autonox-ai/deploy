# Suggestion: Using `audit.compare_access_between_dates` Correctly

## Recommended Role

Use `audit.compare_access_between_dates(start_timestamp, end_timestamp)` as a **change-detection primitive** between two points in time.

It is best for:

- What access was **added** since the previous review?
- What access was **removed** since the previous review?
- Which identities changed between two dates?

## What It Returns Well

- Identity context: `identity_id`, `display_name`, `email`
- Access context: `app_name`, `entitlement_name`, `entitlement_type`, `via_source`
- Change semantics: `change_type` (`ADDED` / `REMOVED`)

## What It Is Not

Do not use it as a replacement for point-in-time investigation cards.

It does **not** provide:

- full current-state access inventory
- unchanged access rows
- account-level drill fidelity (`via_account`)

## Practical Pattern in Metabase

1. Keep `Access Investigations` for point-in-time state (`get_identity_access_snapshot`, `get_account_access_snapshot`).
2. Add a separate "Access Changes Between Dates" card/dashboard powered by `compare_access_between_dates`.
3. Include filters for:
   - `start_timestamp`
   - `end_timestamp`
   - `identity_email` (optional)
   - `via_source` (optional)
   - `change_type` (optional)
4. Add drill-through from change rows into `Access Investigations` at the **end date**.

## Operational Caveat

Current compare logic is keyed to identity + entitlement + source semantics. If an entitlement moves between accounts within the same source, this function may not surface that as a change. Use snapshot-based investigation for account-level provenance.

## Validation Note

A sample one-day window returned zero deltas in current data; that means no detected add/remove in that span, not that the function is broken.
