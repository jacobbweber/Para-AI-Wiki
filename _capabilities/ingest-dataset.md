# Capability: ingest-dataset

Bring a spreadsheet or structured data file into the vault **without** ever dumping
its contents into context. Two phases: map the structure, then extract only what a
question needs.

## Trigger
An ingested item is tabular (`.xlsx`, `.xls`, `.csv`, `.tsv`) or otherwise a dataset.

## Structure produced
```
03_Resources/Datasets/<slug>/
├── source.xlsx      # original, untouched
├── manifest.md      # PHASE 1 — structure ONLY: sheets, dimensions, header row/col
│                    #            coordinates, merged regions, data ranges. No bulk values.
├── profile.md       # column types, units, row counts, a few sample rows, anomalies
└── index.md         # OUR YAML front matter; summary; links to manifest/profile
```

## Tooling — reference implementation
`bin/dataset_tool.py` (portable Python; CSV needs only the stdlib, XLSX needs
`openpyxl`). Any runtime may reimplement the same contract.

```
# Phase 1 — map (writes manifest.md, profile.md, starter index.md; NO bulk values)
python bin/dataset_tool.py map "00_Inbox/<file>.csv" "03_Resources/Datasets/<slug>" --slug <slug>

# Phase 2 — targeted extract (prints ONLY the requested slice)
python bin/dataset_tool.py extract "03_Resources/Datasets/<slug>/source.csv" --columns a,b,c --rows 1:20
python bin/dataset_tool.py extract "<source>" --head 10
```
After mapping, the toolkit treats only `index.md` as a note (`manifest.md`,
`profile.md`, `source.*` are skipped); run `Validate`/`Reindex` after finalizing.

## Agent steps (judgment)
1. **Phase 1 — map.** Scan layout; write `manifest.md` describing every sheet's
   shape, where headers live, merged cells, and the data range — but **no bulk cell
   values**. Write `profile.md` with column types/units, row counts, 2–3 sample
   rows, and notable anomalies.
2. Write `index.md` with full schema front matter, `document_type: Dataset` (or
   `Proxy-Note` pointing at `source.xlsx`), and a `summary` of what the data is.
3. **Phase 2 — extract (on demand only).** When a question arrives, read the
   manifest to locate the relevant sheet/range, then pull only that slice. Never
   read the whole sheet to "have it."

## Outputs
- A cataloged dataset whose structure is known but whose values stay out of context
  until a specific question pulls a specific slice.

## Done when
- `manifest.md` + `profile.md` + a valid `index.md` exist and no bulk values were
  loaded into context during ingestion.
