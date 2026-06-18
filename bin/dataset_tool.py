#!/usr/bin/env python3
"""
dataset_tool.py — reference implementation of the `ingest-dataset` capability.

Portable, dependency-light tool for bringing a spreadsheet/CSV into the Library
WITHOUT dumping its contents into an agent's context. Two phases:

  map     Phase 1 — write manifest.md (structure ONLY), profile.md (types/samples),
          and a starter index.md (our YAML). No bulk cell values are emitted.
  extract Phase 2 — print ONLY a targeted slice (columns / row range / head).

Runtimes: Python 3.8+. CSV/TSV need only the standard library. XLSX needs openpyxl
(`pip install openpyxl`); if it's missing, .xlsx maps still record what they can and
say which extractor would unlock full structure.

This is a REFERENCE implementation: any agent OS may reimplement the same contract
in any language. The contract is the files produced (manifest/profile/index) and the
"never load bulk values" rule — see ../_capabilities/ingest-dataset.md.

Usage:
  python dataset_tool.py map     <source.csv|xlsx> <dest_dir> [--slug NAME]
  python dataset_tool.py extract <source.csv|xlsx> [--sheet S] [--columns a,b]
                                 [--rows 2:20] [--head N]
"""
import argparse, csv, hashlib, os, sys, datetime, statistics

# ----------------------------- helpers --------------------------------------

def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(65536), b""):
            h.update(blk)
    return h.hexdigest()

def infer_type(values):
    """Best-effort column type from a sample of string values (non-empty)."""
    vals = [v for v in values if v is not None and str(v).strip() != ""]
    if not vals:
        return "empty"
    def is_int(s):
        try: int(str(s).replace(",", "")); return True
        except ValueError: return False
    def is_float(s):
        try: float(str(s).replace(",", "")); return True
        except ValueError: return False
    def is_date(s):
        s = str(s).strip()
        for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%d/%m/%Y", "%Y/%m/%d", "%m-%d-%Y"):
            try: datetime.datetime.strptime(s, fmt); return True
            except ValueError: pass
        return False
    if all(is_int(v) for v in vals):   return "integer"
    if all(is_float(v) for v in vals): return "float"
    if all(is_date(v) for v in vals):  return "date"
    return "text"

def numeric_stats(values):
    nums = []
    for v in values:
        try: nums.append(float(str(v).replace(",", "")))
        except (ValueError, TypeError): pass
    if not nums:
        return None
    s = {"min": min(nums), "max": max(nums), "mean": round(statistics.mean(nums), 3)}
    return s

# ----------------------------- readers --------------------------------------

def read_csv(path):
    """Return (sheet_name, header, rows) for a CSV/TSV. rows = list of list[str]."""
    delim = "\t" if path.lower().endswith((".tsv", ".tab")) else ","
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as f:
        reader = csv.reader(f, delimiter=delim)
        data = [row for row in reader]
    if not data:
        return [("Sheet1", [], [])]
    header, rows = data[0], data[1:]
    return [("Sheet1", header, rows)]

def read_xlsx(path):
    """Return list of (sheet_name, header, rows). Requires openpyxl."""
    try:
        import openpyxl
    except ImportError:
        return None
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    sheets = []
    for ws in wb.worksheets:
        grid = [[("" if c is None else c) for c in row]
                for row in ws.iter_rows(values_only=True)]
        if not grid:
            sheets.append((ws.title, [], [])); continue
        header, rows = grid[0], grid[1:]
        sheets.append((ws.title, [str(h) for h in header], rows))
    return sheets

def load(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in (".csv", ".tsv", ".tab"):
        return read_csv(path), None
    if ext in (".xlsx", ".xlsm"):
        sheets = read_xlsx(path)
        if sheets is None:
            return None, "openpyxl not installed (pip install openpyxl) — needed for .xlsx"
        return sheets, None
    return None, f"Unsupported extension: {ext} (use .csv/.tsv/.xlsx)"

# ----------------------------- map (phase 1) --------------------------------

def col_letter(i):
    s = ""
    i += 1
    while i:
        i, r = divmod(i - 1, 26)
        s = chr(65 + r) + s
    return s

def write_manifest(dest, src_name, checksum, sheets):
    lines = [f"# Manifest — {src_name}", "",
             f"- File: `{src_name}` · checksum (sha256): `{checksum}`",
             f"- Sheets: {len(sheets)}", "",
             "> Structure only. No bulk cell values are recorded here.", ""]
    for name, header, rows in sheets:
        ncol = max([len(header)] + [len(r) for r in rows]) if (header or rows) else 0
        nrow = len(rows)
        last = f"{col_letter(max(ncol-1,0))}{nrow+1}" if ncol else "—"
        lines += [f"## Sheet: {name}  ({nrow} data rows x {ncol} cols)",
                  f"- Header row: 1   · Header span: A1:{col_letter(max(ncol-1,0))}1" if ncol else "- (empty sheet)",
                  f"- Data range: A2:{last}" if ncol else "",
                  "- Columns (names only):",
                  ]
        for i, h in enumerate(header):
            lines.append(f"  - {col_letter(i)}: {h}")
        lines.append("")
    _put(os.path.join(dest, "manifest.md"), "\n".join(lines))

def write_profile(dest, src_name, sheets):
    lines = [f"# Profile — {src_name}", ""]
    for name, header, rows in sheets:
        lines += [f"## Sheet: {name}", "",
                  "| Column | Type | Non-null | Stats (min/max/mean) |",
                  "|--------|------|----------|----------------------|"]
        ncol = max([len(header)] + [len(r) for r in rows]) if (header or rows) else 0
        for i in range(ncol):
            colname = header[i] if i < len(header) else col_letter(i)
            colvals = [r[i] if i < len(r) else "" for r in rows]
            nonnull = sum(1 for v in colvals if str(v).strip() != "")
            t = infer_type(colvals)
            st = numeric_stats(colvals) if t in ("integer", "float") else None
            stat = f"{st['min']}/{st['max']}/{st['mean']}" if st else "—"
            lines.append(f"| {colname} | {t} | {nonnull}/{len(rows)} | {stat} |")
        lines += ["", "### Sample rows (first 3)", ""]
        if header:
            lines += ["| " + " | ".join(str(h) for h in header) + " |",
                      "|" + "|".join("---" for _ in header) + "|"]
            for r in rows[:3]:
                cells = [str(r[i]) if i < len(r) else "" for i in range(len(header))]
                lines.append("| " + " | ".join(cells) + " |")
        # anomalies
        anom = []
        widths = set(len(r) for r in rows)
        if len(widths) > 1:
            anom.append(f"ragged rows (widths: {sorted(widths)})")
        if anom:
            lines += ["", "### Anomalies", *[f"- {a}" for a in anom]]
        lines.append("")
    _put(os.path.join(dest, "profile.md"), "\n".join(lines))

def write_index_stub(dest, src_name, slug, checksum, sheets):
    today = datetime.date.today().isoformat()
    total_rows = sum(len(r) for _, _, r in sheets)
    uid = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    fm = f"""---
uid: {uid}
title: {slug.replace('-', ' ').title()}
aliases: []
domain:
topic:
subtopic:
document_type: Dataset
tags: [dataset]
ontology: []
keywords: []
language: en
summary:
status: Draft
priority: Medium
source: {src_name}
author: human
created_by: agent
model:
context_tokens: 0
token_last_reviewed: {today}
word_count: 0
content_hash:
embedding_id:
related: []
parent:
moc:
supersedes: []
superseded_by:
merge_candidates: []
cluster_id:
confidence_score: 0.5
temperature: 0.2
sensitivity: internal
do_not_sync: false
review_due:
pinned: false
archive_after:
schema_version: "1.0"
date_created: {today}
last_updated: {today}
last_accessed: {today}
access_count: 0
last_maintained:
document_role: Dataset
source_path: {src_name}
checksum: {checksum}
row_count: {total_rows}
sheet_count: {len(sheets)}
---

# {slug.replace('-', ' ').title()}

<!-- AGENT: finalize domain/topic/subtopic, tags (from tag-authority), and summary. -->
Structure → `manifest.md` · types & samples → `profile.md` · original → `{src_name}`.

## What this is
(one paragraph: the dataset's grain and what questions it answers)
"""
    _put(os.path.join(dest, "index.md"), fm)

def _put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)

def cmd_map(args):
    sheets, err = load(args.source)
    if err:
        print("ERROR:", err); return 2
    slug = args.slug or os.path.splitext(os.path.basename(args.source))[0].lower().replace("_", "-")
    dest = args.dest_dir
    os.makedirs(dest, exist_ok=True)
    checksum = sha256_of(args.source)
    src_name = "source" + os.path.splitext(args.source)[1].lower()
    write_manifest(dest, src_name, checksum, sheets)
    write_profile(dest, src_name, sheets)
    write_index_stub(dest, src_name, slug, checksum, sheets)
    print(f"Mapped {args.source}")
    print(f"  -> {os.path.join(dest, 'manifest.md')}")
    print(f"  -> {os.path.join(dest, 'profile.md')}")
    print(f"  -> {os.path.join(dest, 'index.md')}  (agent: finalize YAML)")
    print(f"  sheets={len(sheets)} checksum={checksum[:12]}…")
    print(f"  NEXT: move the original to {os.path.join(dest, src_name)} and finalize index.md")
    return 0

# ----------------------------- extract (phase 2) ----------------------------

def cmd_extract(args):
    sheets, err = load(args.source)
    if err:
        print("ERROR:", err); return 2
    # pick sheet
    sheet = None
    for name, header, rows in sheets:
        if args.sheet is None or name == args.sheet:
            sheet = (name, header, rows); break
    if sheet is None:
        print("ERROR: sheet not found:", args.sheet); return 2
    name, header, rows = sheet
    # row range
    if args.rows:
        a, _, b = args.rows.partition(":")
        a = int(a) if a else 1
        b = int(b) if b else len(rows) + 1
        rows = rows[max(a-1, 0):b-1]
    elif args.head:
        rows = rows[:args.head]
    # columns
    cols = list(range(len(header)))
    if args.columns:
        want = [c.strip() for c in args.columns.split(",")]
        cols = [header.index(w) for w in want if w in header]
        if len(cols) != len(want):
            print("WARN: some columns not found; available:", header)
    sel_header = [header[i] for i in cols]
    print("Sheet:", name, "| columns:", sel_header, "| rows:", len(rows))
    print("| " + " | ".join(str(h) for h in sel_header) + " |")
    print("|" + "|".join("---" for _ in sel_header) + "|")
    for r in rows:
        print("| " + " | ".join(str(r[i]) if i < len(r) else "" for i in cols) + " |")
    return 0

# ----------------------------- cli ------------------------------------------

def main():
    p = argparse.ArgumentParser(description="Dataset ingest reference tool (map / extract).")
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("map", help="Phase 1: write manifest/profile/index (no bulk values).")
    m.add_argument("source"); m.add_argument("dest_dir"); m.add_argument("--slug")
    m.set_defaults(func=cmd_map)
    e = sub.add_parser("extract", help="Phase 2: print only a targeted slice.")
    e.add_argument("source")
    e.add_argument("--sheet"); e.add_argument("--columns")
    e.add_argument("--rows", help="row range like 2:20 (1-based, data rows)")
    e.add_argument("--head", type=int)
    e.set_defaults(func=cmd_extract)
    args = p.parse_args()
    sys.exit(args.func(args))

if __name__ == "__main__":
    main()
