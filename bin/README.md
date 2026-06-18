# bin/ — reference tooling

Portable helper programs that implement the *mechanical* half of the system's
capabilities. They are reference implementations: any agent runtime may call them
as-is or reimplement the same contract in another language. The judgment half stays
with the agent (see `../_capabilities/`).

This folder is not scanned as notes (it holds no `.md` notes; `.py` is ignored by the
note tooling).

## Contents

| Tool | Capability | Runtime |
|------|-----------|---------|
| `dataset_tool.py` | `ingest-dataset` | Python 3.8+. CSV/TSV use the stdlib only; `.xlsx` needs `openpyxl`. |

### `dataset_tool.py`
Brings a spreadsheet/CSV into the Library without dumping its contents into context.

```
# Phase 1 — map structure (manifest.md), profile (profile.md), starter index.md
python bin/dataset_tool.py map <source.csv|xlsx> <dest_dir> [--slug NAME]

# Phase 2 — print ONLY a targeted slice (never the whole sheet)
python bin/dataset_tool.py extract <source> [--sheet S] [--columns a,b] [--rows 2:20] [--head N]
```

`map` never writes bulk cell values into `manifest.md`; `profile.md` includes only
column types/stats and at most three sample rows. For `.xlsx` install the extractor
once: `pip install openpyxl` (or `pip install openpyxl --break-system-packages`).

The Python maintenance engine (`../search_and_maintenance.py`) is the other
reference tool — it implements search, dedup detection, token recalc, validation,
pruning, and indexing for `ingest`, `retrieve`, `consolidate`, and `maintain`.

## Worked example
`03_Resources/Datasets/homelab-inventory/` was produced end-to-end by this tool
(map → agent-finalized `index.md` → targeted extract). Safe to delete.
