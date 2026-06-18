# Capability: maintain

A scheduled health pass that keeps the vault accurate, valid, and lean. All steps
are report-first; anything that moves or deletes data requires human confirmation.

## Trigger
Scheduled (e.g. nightly light pass, weekly deep pass), or on demand.

## Inputs
- Token-review window (default 60 days), prune staleness window (default 365 days).

## Tooling
- Dashboard: `python search_and_maintenance.py --action Stats`
- Token refresh: `python search_and_maintenance.py --action RecalcTokens --older-than-days 60`
  (recomputes `context_tokens`/`word_count`/`content_hash`, restamps review date).
- Schema check: `python search_and_maintenance.py --action Validate --report`
- Prune candidates (report only): `python search_and_maintenance.py --action Prune --stale-days 365 --report`
- Prune apply (after approval): add `--apply` to move stale, unpinned notes to `04_Archive`.
- Rebuild machine index: `python search_and_maintenance.py --action Reindex`

## Agent steps (judgment)
1. Run `Stats` to get the current shape; note anomalies (e.g. orphans, stale counts).
2. Run `Validate`; fix metadata-level problems directly (missing fields, bad dates,
   broken links, missing proxy targets). These are non-destructive.
3. Run `RecalcTokens` so context budgeting stays accurate.
4. Run `Prune` (report). Review candidates; confirm with the human before `--apply`.
   Respect `pinned: true` (always skipped) and consider `archive_after`.
5. Optionally run `consolidate` (separate capability) for duplicate clusters.
6. Append a one-line entry to the audit ledger (`.maintenance/audit-log.md`):
   date · action · counts · notes. Append-only; never rewrite history.

## Outputs
- Refreshed token estimates, clean validation, an up-to-date index, an audit line,
  and a reviewed (not auto-executed) prune list.

## Done when
- `Validate` is clean, `Stats` looks expected, and the run is logged.

## Cadence (suggested)
- Nightly: `Validate`, `RecalcTokens`, `Reindex`, `Stats`.
- Weekly: `Duplicates` (consolidate review) + `Prune` review.
