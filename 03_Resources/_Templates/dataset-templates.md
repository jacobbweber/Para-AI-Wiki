---
uid: YYYYMMDD-HHMMSS
title: Dataset Templates (index / manifest / profile)
document_type: Template
summary: The three files that make up a dataset work; copy the relevant block. See _capabilities/ingest-dataset.md.
tags: [meta, template, dataset, data]
status: Final
sensitivity: internal
schema_version: "1.0"
date_created: 2026-06-14
last_updated: 2026-06-14
last_accessed: 2026-06-14
---

# Dataset templates

A dataset work lives at `03_Resources/Datasets/<slug>/` and has three files plus the
original. Map structure first (manifest), profile it, never dump bulk values into
context. Full rules: `_capabilities/ingest-dataset.md`.

---

## 1) `index.md` front matter (the note)

```yaml
---
uid: YYYYMMDD-HHMMSS
title: 
domain: 80-data-or-subject-domain
topic: 
document_type: Dataset
tags: [dataset]
summary: What this dataset is, its grain, and what questions it answers.
status: Final
sensitivity: internal
schema_version: "1.0"
date_created: YYYY-MM-DD
last_updated: YYYY-MM-DD
last_accessed: YYYY-MM-DD
context_tokens: 0
token_last_reviewed: YYYY-MM-DD
confidence_score: 0.6
source_path: source.xlsx
checksum: 
---
# {{title}}
Links: see `manifest.md` (structure) and `profile.md` (types/samples).
```

---

## 2) `manifest.md` — PHASE 1, structure ONLY (no bulk values)

```markdown
# Manifest — {{dataset}}
- File: source.xlsx · checksum: <sha256> · sheets: <n>

## Sheet: <name>  (rows x cols)
- Header row: <row index>   · Header span: <A1:Z1>
- Data range: <A2:Z9999>
- Merged regions: <list or none>
- Columns: <A: label> | <B: label> | …   (names only, not values)
```

---

## 3) `profile.md` — types, units, samples, anomalies

```markdown
# Profile — {{dataset}}
| Column | Type | Unit | Non-null | Notes |
|--------|------|------|----------|-------|
| <name> | <int/float/date/text> | <unit> | <count> | <anomaly?> |

## Sample rows (2-3 only)
<a few representative rows>

## Anomalies
- <mixed types / blanks / outliers / encoding issues>
```
