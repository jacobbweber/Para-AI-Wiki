# Capability: retrieve

Find the minimum-sufficient content to answer a question, spending tokens only on
the slice that is actually needed (progressive reveal).

## Trigger
The agent needs vault knowledge to answer or act.

## Inputs
- A query (free text), and/or structured filters (domain, topic, tag, status, date,
  confidence).

## Tooling
- Broad recall: `python search_and_maintenance.py --action Search --query "<text>" --mode Broad`
- Precise field match: `... --action Search --field <field> --value "<value>" --mode Precise`
- Filters: `--tag`, `--domain`, `--topic`, `--status`, `--min-confidence`, date ranges.
- Machine index (fast, programmatic): `python search_and_maintenance.py --action Reindex`
  then read `.maintenance/index.json` (or grep it). Reindex regenerates it from the
  notes, so it never drifts.

## Agent steps (judgment)
1. Tier 1 — locate: run a search; read only the returned **summaries** to judge
   relevance. Do not open bodies yet.
2. Tier 2 — assess: open the `index`/front matter of the best candidate(s) to confirm.
3. Tier 3 — read content: open only the specific note body, or — for a chunked work
   — only the relevant `chunks/<n>.md`; for a dataset, only the targeted sheet/range
   (see `ingest-dataset`). Never bulk-read a tree or a whole large work speculatively.
4. On retrieval, update telemetry: `python search_and_maintenance.py --action Touch --path "<rel>"`
   (bumps `last_accessed` + `access_count`).
5. Cite the notes used (by `uid`/title).

## Outputs
- The minimal set of note content needed, plus citations.

## Done when
- The question is answerable from what was read, with sources cited and telemetry updated.
