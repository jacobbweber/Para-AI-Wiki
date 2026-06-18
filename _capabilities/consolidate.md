# Capability: consolidate

Find notes that say similar things and resolve them, so the vault gets denser as it
grows instead of accumulating overlap. The tooling **finds** candidates; the agent
**decides**; structural changes need human confirmation.

## Trigger
Scheduled (e.g. weekly), or when ingestion flags a likely duplicate.

## Inputs
- A similarity threshold (default 0.40) and shingle size (default 3).

## Tooling
- Detect: `python search_and_maintenance.py --action Duplicates --threshold 0.4 --report`
  → writes ranked clusters + exact-content matches to `.maintenance/duplicates_*.json`.
- Stamp for review (optional): add `--apply` to write `cluster_id` + `merge_candidates`
  onto the involved notes so the work is visible in their front matter.
- The agent performs merges/rewrites itself (atomic writes); the tooling never merges.

## Agent steps (judgment)
1. Read the duplicates report. For each cluster, open the members' summaries (and
   bodies only if needed).
2. Decide per cluster: **MERGE** (fold into one canonical note), **SYNTHESIZE-NEW**
   (distill a new note from several), or **KEEP-SEPARATE** (clear the stamps).
3. Propose the decision to the human; act only on approval.
4. On MERGE/SYNTHESIZE: preserve lineage — set `supersedes` on the survivor and
   `superseded_by` + `status: Deprecated` on the losers, union their
   `tags`/`ontology`/`related`, repoint `[[links]]`, then archive the losers
   (`04_Archive`) rather than deleting. Update `Map_of_Content.md`.
5. Re-run `Validate` to confirm no broken links resulted.

## Outputs
- Fewer, denser notes; archived (not deleted) superseded notes; intact link graph.

## Done when
- Every reviewed cluster is resolved (merged, synthesized, or explicitly kept), and
  `Validate` is clean.
