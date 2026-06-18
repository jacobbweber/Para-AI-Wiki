#!/usr/bin/env python3
"""
search_and_maintenance.py — search & maintenance engine for the Library.

Pure-Python (standard library only). Runs on Python 3.8+ on Windows, macOS, and
Linux. This is the single reference tool for the deterministic operations behind the
ingest / retrieve / consolidate / maintain capabilities (see _capabilities/).

Philosophy: FIND, DON'T DECIDE. Destructive/structural changes (merge, archive) only
report candidates unless you pass --apply. Metadata refreshes (recalc-tokens, etc.)
write by default but support --dry-run.

Safety: note writes are ATOMIC (temp file + os.replace), BOM-free, retried on
transient locks, single-instance-locked for write actions, and use optimistic
concurrency (skip if the file changed since it was read).

Usage:
  python search_and_maintenance.py --action <Action> [params]

Actions: Search | Duplicates | RecalcTokens | Prune | Validate | Stats | Touch | Reindex

Examples:
  python search_and_maintenance.py --action Search --query "datastore latency" --mode Broad
  python search_and_maintenance.py --action Search --field domain --value "Information Technology" --mode Precise
  python search_and_maintenance.py --action Duplicates --threshold 0.45 --report
  python search_and_maintenance.py --action RecalcTokens --older-than-days 60
  python search_and_maintenance.py --action Prune --stale-days 365           # report only
  python search_and_maintenance.py --action Prune --stale-days 365 --apply   # archive
  python search_and_maintenance.py --action Validate --report
  python search_and_maintenance.py --action Touch --path "01_Projects/note.md"
"""
import argparse, csv, hashlib, json, math, os, re, sys, tempfile, time
from datetime import datetime, timedelta, date

# ----------------------------- constants ------------------------------------
SCHEMA_VERSION   = "1.0"
SYSTEM_FILES     = {"README.md", "instructions.md", "Map_of_Content.md"}
REQUIRED_FIELDS  = ["uid", "title", "domain", "topic", "document_type", "tags",
                    "summary", "status", "context_tokens", "token_last_reviewed",
                    "confidence_score", "sensitivity", "schema_version",
                    "date_created", "last_updated", "last_accessed"]
VALID_STATUS      = {"Idea", "Needs Deep Research", "Draft", "In Review", "Final", "Deprecated"}
VALID_SENSITIVITY = {"public", "internal", "private", "secret"}
NON_NOTE_NAMES    = {"source.md", "manifest.md", "profile.md"}

FM_RE = re.compile(r"^---\r?\n(.*?)\r?\n---\r?\n?(.*)$", re.S)

# ----------------------------- resilient I/O --------------------------------
def with_retry(fn, attempts=6, delay_ms=120):
    """Run fn(), retrying transient lock errors with backoff. FileNotFound is fatal."""
    for a in range(1, attempts + 1):
        try:
            return fn()
        except FileNotFoundError:
            raise
        except (PermissionError, OSError):
            if a == attempts:
                raise
            time.sleep(delay_ms * a / 1000.0)

def read_text_retry(path):
    txt = with_retry(lambda: open(path, "r", encoding="utf-8", errors="replace").read())
    if not txt:
        return ""
    return txt.lstrip("﻿")  # strip UTF-8 BOM if present

def write_atomic(path, content):
    """Write UTF-8 (no BOM), LF endings, atomically (temp in same dir + os.replace)."""
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".smtmp_", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        with_retry(lambda: os.replace(tmp, path))   # atomic on POSIX & Windows
        tmp = None
    finally:
        if tmp and os.path.exists(tmp):
            try: os.remove(tmp)
            except OSError: pass

def enter_lock(lock_path, stale_minutes=60):
    """Single-instance lock via exclusive create. Reclaim if stale. Returns bool."""
    for _ in range(3):
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, ("pid=%d\nstarted=%s\n" % (os.getpid(), datetime.now().isoformat())).encode())
            os.close(fd)
            return True
        except FileExistsError:
            try:
                mtime = datetime.fromtimestamp(os.path.getmtime(lock_path))
                if mtime < datetime.now() - timedelta(minutes=stale_minutes):
                    os.remove(lock_path)
                    continue
            except OSError:
                pass
            return False
    return False

def exit_lock(lock_path):
    if lock_path and os.path.exists(lock_path):
        try: os.remove(lock_path)
        except OSError: pass

# ----------------------------- text helpers ---------------------------------
def string_hash(text):
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()

def normalize(text):
    if text is None:
        return ""
    t = text.replace("\r\n", "\n").replace("\r", "\n")
    return "\n".join(line.rstrip() for line in t.split("\n")).strip()

def token_estimate(text):
    if not text or not text.strip():
        return 0
    chars = len(text)
    words = len([w for w in re.split(r"\s+", text) if w])
    return int(round(max(chars / 4.0, words * 0.75)))

def word_count(text):
    if not text or not text.strip():
        return 0
    return len([w for w in re.split(r"\s+", text) if w])

def clean_scalar(v):
    if v is None:
        return ""
    v = v.strip()
    if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
        v = v[1:-1]
    return v

# ----------------------------- front matter ---------------------------------
def parse_front_matter(fm_text):
    """Minimal YAML: scalars, inline lists [a, b], block lists ('- item'). Ordered."""
    m = {}
    lines = re.split(r"\r?\n", fm_text)
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r"^\s*#", line) or line.strip() == "":
            i += 1; continue
        km = re.match(r"^([A-Za-z0-9_\-]+):\s*(.*)$", line)
        if km:
            key, val = km.group(1), km.group(2)
            if val == "":
                lst = []
                while i + 1 < len(lines):
                    bm = re.match(r"^\s*-\s*(.*)$", lines[i + 1])
                    if not bm:
                        break
                    lst.append(clean_scalar(bm.group(1))); i += 1
                m[key] = lst if lst else ""
            else:
                im = re.match(r"^\[(.*)\]$", val)
                if im:
                    inner = im.group(1).strip()
                    m[key] = [clean_scalar(x) for x in inner.split(",")] if inner else []
                else:
                    m[key] = clean_scalar(val)
        i += 1
    return m

def format_yaml_value(value):
    if isinstance(value, list):
        return "[" + ", ".join(str(x) for x in value) + "]"
    return str(value)

def update_front_matter_fields(file_path, updates, preview=False):
    """Surgically update/insert fields; atomic, BOM-free; optimistic-concurrency."""
    raw = read_text_retry(file_path)
    m = FM_RE.match(raw)
    if not m:
        warn("  No front matter; skipped: %s" % file_path)
        return False
    stamp_at_read = os.path.getmtime(file_path)
    fm, body = m.group(1), m.group(2)
    for k, v in updates.items():
        rendered = format_yaml_value(v)
        pat = re.compile(r"(?m)^" + re.escape(k) + r":.*$")
        if pat.search(fm):
            fm = pat.sub(lambda _: "%s: %s" % (k, rendered.replace("\\", "\\\\")), fm)
        else:
            fm = fm.rstrip() + "\n" + "%s: %s" % (k, rendered)
    out = "---\n" + fm.strip() + "\n---\n" + body
    if preview:
        print("  [DryRun] would update %s: %s" % (os.path.basename(file_path), ", ".join(updates.keys())))
        return True
    # compare-and-swap: don't clobber a concurrent edit
    if os.path.getmtime(file_path) != stamp_at_read:
        warn("  Skipped (changed by another writer during update): %s" % file_path)
        return False
    write_atomic(file_path, out)
    return True

# ----------------------------- note loading ---------------------------------
class Note:
    __slots__ = ("path", "rel", "name", "folder", "fm", "body", "normbody", "shingles", "hash")
    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))

def get_notes(vault, with_archive=False, with_templates=False):
    notes = []
    for dirpath, dirnames, filenames in os.walk(vault):
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, vault).replace("\\", "/")
            # exclusions (mirror the contract)
            if rel.startswith(".maintenance"):
                continue
            if fn in SYSTEM_FILES and "/" not in rel:
                continue
            if re.search(r"(^|/)\.[^/]+/", rel):                       # any dot-folder
                continue
            if re.search(r"(^|/)_(?!Templates(/|$))[^/]*/", rel):       # _meta except _Templates
                continue
            if not with_archive and re.match(r"^04_Archive(/|$)", rel):
                continue
            if not with_templates and re.search(r"(^|/)_Templates(/|$)", rel):
                continue
            if re.search(r"(^|/)chunks/", rel):                         # chunk content
                continue
            if fn in NON_NOTE_NAMES:                                    # source/manifest/profile
                continue
            if re.search(r"(^|/)bin/", rel):                            # reference tooling dir
                continue
            raw = read_text_retry(full)
            fm, body = {}, raw
            m = FM_RE.match(raw)
            if m:
                fm = parse_front_matter(m.group(1)); body = m.group(2)
            notes.append(Note(path=full, rel=rel, name=fn, folder=rel.split("/")[0],
                              fm=fm, body=body, normbody=normalize(body)))
    return notes

def fmv(note, key):
    return note.fm.get(key)

def date_older_than(date_str, days):
    if not date_str or not str(date_str).strip():
        return True
    try:
        d = parse_date(str(date_str))
    except Exception:
        return True
    return d < datetime.now() - timedelta(days=days)

def parse_date(s):
    s = s.strip()
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S", "%m/%d/%Y", "%d/%m/%Y", "%Y/%m/%d", "%m-%d-%Y"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            pass
    return datetime.fromisoformat(s)  # last resort; raises if invalid

# ----------------------------- similarity -----------------------------------
def shingles(text, k=3):
    clean = re.sub(r"\s+", " ", re.sub(r"[^a-z0-9\s]", " ", text.lower())).strip()
    words = [w for w in clean.split(" ") if w]
    if len(words) < k:
        return set(words)
    return {" ".join(words[i:i + k]) for i in range(len(words) - k + 1)}

def jaccard(a, b):
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a) + len(b) - inter
    return round(inter / union, 4) if union else 0.0

# ----------------------------- console / reports ----------------------------
def info(m): print(m)
def warn(m): print(m)
def ok(m):   print(m)

def print_table(rows, cols):
    if not rows:
        return
    widths = {c: max(len(c), *(len(str(r.get(c, ""))) for r in rows)) for c in cols}
    print("  ".join(c.ljust(widths[c]) for c in cols))
    print("  ".join("-" * widths[c] for c in cols))
    for r in rows:
        print("  ".join(str(r.get(c, "")).ljust(widths[c]) for c in cols))

def save_report(maint_dir, base, data):
    os.makedirs(maint_dir, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-") + ("%03d" % (datetime.now().microsecond // 1000))
    csv_path = os.path.join(maint_dir, "%s_%s.csv" % (base, stamp))
    json_path = os.path.join(maint_dir, "%s_%s.json" % (base, stamp))
    if data:
        try:
            with open(csv_path, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=list(data[0].keys()))
                w.writeheader(); w.writerows(data)
            ok("  Report: %s" % csv_path)
        except Exception:
            pass
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, default=str)
    ok("  Report: %s" % json_path)

# ----------------------------- actions --------------------------------------
def action_search(a, vault):
    notes = get_notes(vault, a.include_archive, a.include_templates)
    results = []
    for n in notes:
        if a.field:
            fv = fmv(n, a.field)
            if fv is None:
                continue
            hay = "\n".join(fv) if isinstance(fv, list) else str(fv)
            if a.regex:
                hit = re.search(a.value or "", hay) is not None
            elif a.mode == "Precise":
                hit = (a.value in fv) if isinstance(fv, list) else (hay.casefold() == (a.value or "").casefold())
            else:
                hit = (a.value or "").casefold() in hay.casefold()
            if not hit:
                continue
        if a.domain and str(fmv(n, "domain") or "").casefold() != a.domain.casefold(): continue
        if a.topic and str(fmv(n, "topic") or "").casefold() != a.topic.casefold(): continue
        if a.subtopic and str(fmv(n, "subtopic") or "").casefold() != a.subtopic.casefold(): continue
        if a.status and str(fmv(n, "status") or "").casefold() != a.status.casefold(): continue
        if a.document_type and str(fmv(n, "document_type") or "").casefold() != a.document_type.casefold(): continue
        if a.sensitivity and str(fmv(n, "sensitivity") or "").casefold() != a.sensitivity.casefold(): continue
        if a.tag and not _list_has(fmv(n, "tags"), a.tag): continue
        if a.ontology and not _list_has(fmv(n, "ontology"), a.ontology): continue
        if a.keyword and not _list_has(fmv(n, "keywords"), a.keyword): continue
        if a.min_confidence is not None and a.min_confidence >= 0:
            c = fmv(n, "confidence_score")
            if c is None or _to_float(c) is None or _to_float(c) < a.min_confidence:
                continue
        if not _date_ok(n, "date_created", a.created_after, a.created_before): continue
        if not _date_ok(n, "last_updated", a.updated_after, a.updated_before): continue
        if a.accessed_before and not _before(fmv(n, "last_accessed"), a.accessed_before): continue
        if a.query:
            fm_text = "\n".join("%s %s" % (k, " ".join(v) if isinstance(v, list) else str(v)) for k, v in n.fm.items())
            hay = {"Body": n.body, "FrontMatter": fm_text}.get(a.search_in, fm_text + "\n" + n.body)
            if a.regex:
                hit = re.search(a.query, hay) is not None
            elif a.mode == "Precise":
                hit = a.query in hay
            else:
                hit = all(t.casefold() in hay.casefold() for t in re.split(r"\s+", a.query) if t)
            if not hit:
                continue
        results.append({
            "Title": fmv(n, "title"), "UID": fmv(n, "uid"), "Folder": n.folder,
            "Domain": fmv(n, "domain"), "Topic": fmv(n, "topic"), "Status": fmv(n, "status"),
            "Type": fmv(n, "document_type"), "Tokens": fmv(n, "context_tokens"),
            "Confidence": fmv(n, "confidence_score"), "Updated": fmv(n, "last_updated"),
            "Summary": fmv(n, "summary"), "Rel": n.rel,
        })
    info("\n%d match(es) [%s]:\n" % (len(results), a.mode))
    print_table(results, ["Title", "Folder", "Domain", "Topic", "Status", "Tokens", "Updated", "Rel"])
    if a.report and results:
        save_report(a._maint, "search", results)
    return results

def _list_has(v, val):
    return isinstance(v, list) and any(str(x).casefold() == val.casefold() for x in v)

def _to_float(x):
    try: return float(str(x))
    except (ValueError, TypeError): return None

def _date_ok(n, field, after, before):
    val = fmv(n, field)
    if after and val:
        try:
            if parse_date(str(val)) < parse_date(after): return False
        except Exception: pass
    if before and val:
        try:
            if parse_date(str(val)) > parse_date(before): return False
        except Exception: pass
    return True

def _before(val, before):
    if not val: return True
    try:
        return parse_date(str(val)) <= parse_date(before)
    except Exception:
        return True

def action_duplicates(a, vault):
    notes = get_notes(vault, a.include_archive, a.include_templates)
    info("Scanning %d notes for similarity (threshold %s, shingle %d)..." % (len(notes), a.threshold, a.shingle))
    for n in notes:
        n.shingles = shingles(n.normbody, a.shingle)
        n.hash = string_hash(n.normbody)
    # exact duplicates by body hash
    by_hash = {}
    for n in notes:
        by_hash.setdefault(n.hash, []).append(n)
    exact = [g for g in by_hash.values() if len(g) > 1]
    # pairwise near-duplicates
    pairs = []
    for i in range(len(notes)):
        for j in range(i + 1, len(notes)):
            an, bn = notes[i], notes[j]
            sim = jaccard(an.shingles, bn.shingles)
            bonus = 0.0
            if fmv(an, "domain") and fmv(an, "domain") == fmv(bn, "domain"): bonus += 0.03
            if fmv(an, "topic") and fmv(an, "topic") == fmv(bn, "topic"): bonus += 0.03
            ta, tb = fmv(an, "tags"), fmv(bn, "tags")
            if isinstance(ta, list) and isinstance(tb, list):
                shared = len([t for t in ta if t in tb])
                if shared: bonus += min(0.06, shared * 0.02)
            score = round(min(1.0, sim + bonus), 4)
            if score >= a.threshold:
                pairs.append((an, bn, score))
    # union-find clustering
    parent = {n.rel: n.rel for n in notes}
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x
    for an, bn, _ in pairs:
        ra, rb = find(an.rel), find(bn.rel)
        if ra != rb: parent[ra] = rb
    clusters = {}
    for an, bn, _ in pairs:
        root = find(an.rel)
        clusters.setdefault(root, set()).update([an.rel, bn.rel])
    by_rel = {n.rel: n for n in notes}
    report, cid = [], 0
    for root, members in clusters.items():
        cid += 1
        cluster_id = "cluster-%s-%03d" % (datetime.now().strftime("%Y%m%d"), cid)
        peak = max((s for an, bn, s in pairs if an.rel in members and bn.rel in members), default=0)
        for rel in members:
            nn = by_rel[rel]
            report.append({"ClusterId": cluster_id, "PeakScore": peak, "Title": fmv(nn, "title"),
                           "UID": fmv(nn, "uid"), "Domain": fmv(nn, "domain"),
                           "Topic": fmv(nn, "topic"), "Tokens": fmv(nn, "context_tokens"), "Rel": rel})
        if a.apply:
            for rel in members:
                nn = by_rel[rel]
                others = [fmv(by_rel[r], "uid") for r in members if r != rel and fmv(by_rel[r], "uid")]
                update_front_matter_fields(nn.path, {
                    "cluster_id": cluster_id, "merge_candidates": others,
                    "last_maintained": date.today().isoformat()}, preview=a.dry_run)
    print()
    if exact:
        warn("EXACT-CONTENT duplicates (identical body):")
        for g in exact:
            warn("  [%d] %s" % (len(g), "  |  ".join(n.rel for n in g)))
        print()
    ncl = len(set(r["ClusterId"] for r in report))
    info("%d near-duplicate cluster(s):" % ncl)
    print_table(sorted(report, key=lambda r: (r["ClusterId"], r["Rel"])),
                ["ClusterId", "PeakScore", "Title", "Domain", "Topic", "Tokens", "Rel"])
    warn("\nThese are CANDIDATES only. Hand them to the AI: MERGE / SYNTHESIZE-NEW / KEEP-SEPARATE.")
    if a.apply: ok("cluster_id + merge_candidates stamped onto notes for AI review.")
    if a.report:
        save_report(a._maint, "duplicates", report)
    return report

def action_recalc_tokens(a, vault):
    notes = get_notes(vault, a.include_archive, a.include_templates)
    today = date.today().isoformat()
    touched = []
    for n in notes:
        if not date_older_than(fmv(n, "token_last_reviewed"), a.older_than_days):
            continue
        toks, words, h = token_estimate(n.body), word_count(n.body), string_hash(n.normbody)
        if update_front_matter_fields(n.path, {
                "context_tokens": toks, "word_count": words, "content_hash": h,
                "token_last_reviewed": today, "last_maintained": today}, preview=a.dry_run):
            touched.append({"Title": fmv(n, "title"), "NewTokens": toks, "Words": words, "Rel": n.rel})
    ok("Recalculated %d note(s) older than %d days%s." % (len(touched), a.older_than_days, " [DryRun]" if a.dry_run else ""))
    print_table(touched, ["Title", "NewTokens", "Words", "Rel"])
    if a.report and touched:
        save_report(a._maint, "recalc_tokens", touched)
    return touched

def action_prune(a, vault):
    notes = get_notes(vault)  # active only
    cands = []
    for n in notes:
        if str(fmv(n, "pinned")).lower() == "true":
            continue
        if date_older_than(fmv(n, "last_accessed"), a.stale_days):
            cands.append({"Title": fmv(n, "title"), "UID": fmv(n, "uid"), "Folder": n.folder,
                          "LastAccessed": fmv(n, "last_accessed"), "Status": fmv(n, "status"),
                          "Rel": n.rel, "Path": n.path})
    warn("%d note(s) not accessed in %d+ days (archive candidates):" % (len(cands), a.stale_days))
    print_table(cands, ["Title", "Folder", "LastAccessed", "Status", "Rel"])
    if a.apply and cands:
        today = date.today().isoformat()
        for c in cands:
            sub = os.path.dirname(c["Rel"])
            dest_dir = os.path.join(vault, "04_Archive", sub) if sub else os.path.join(vault, "04_Archive")
            os.makedirs(dest_dir, exist_ok=True)
            update_front_matter_fields(c["Path"], {"last_maintained": today})
            with_retry(lambda: os.replace(c["Path"], os.path.join(dest_dir, os.path.basename(c["Rel"]))))
            print("  Archived: %s" % c["Rel"])
        ok("Moved %d note(s) to 04_Archive." % len(cands))
    elif cands:
        warn("\nReport only. Re-run with --apply (after human approval) to archive.")
    if a.report and cands:
        save_report(a._maint, "prune_candidates", [{k: c[k] for k in ("Title", "UID", "Folder", "LastAccessed", "Status", "Rel")} for c in cands])
    return cands

def action_validate(a, vault):
    notes = get_notes(vault, a.include_archive, a.include_templates)
    known = set()
    for n in notes:
        for key in ("uid", "title"):
            v = fmv(n, key)
            if v: known.add(str(v))
        known.add(os.path.splitext(n.name)[0])
    for sf in SYSTEM_FILES:
        known.add(os.path.splitext(sf)[0])
    issues = []
    def add(sev, msg, n):
        issues.append({"Severity": sev, "Issue": msg, "Title": fmv(n, "title"), "Rel": n.rel})
    for n in notes:
        if not n.fm:
            add("ERROR", "Missing front matter entirely", n); continue
        for req in REQUIRED_FIELDS:
            v = n.fm.get(req)
            if v is None or str(v).strip() == "":
                add("ERROR", "Missing required field: %s" % req, n)
        st = fmv(n, "status")
        if st and st not in VALID_STATUS: add("WARN", "Unknown status: %s" % st, n)
        se = fmv(n, "sensitivity")
        if se and se not in VALID_SENSITIVITY: add("WARN", "Unknown sensitivity: %s" % se, n)
        sv = fmv(n, "schema_version")
        if sv and sv != SCHEMA_VERSION: add("INFO", "schema_version %s != %s" % (sv, SCHEMA_VERSION), n)
        for df in ("date_created", "last_updated", "last_accessed", "token_last_reviewed", "review_due", "archive_after"):
            dv = fmv(n, df)
            if dv:
                try: parse_date(str(dv))
                except Exception: add("ERROR", "Unparseable date in %s : %s" % (df, dv), n)
        cf = _to_float(fmv(n, "confidence_score"))
        if cf is not None and (cf < 0 or cf > 1): add("WARN", "confidence_score out of 0..1: %s" % fmv(n, "confidence_score"), n)
        if fmv(n, "document_type") == "Proxy-Note":
            ta = fmv(n, "target_artifact")
            if not ta:
                add("ERROR", "Proxy-Note missing target_artifact", n)
            else:
                full = ta if os.path.isabs(ta) else os.path.join(vault, ta)
                if not os.path.exists(full):
                    add("ERROR", "target_artifact not found on disk: %s" % ta, n)
        link_text = n.body
        for rf in ("related", "parent", "moc", "superseded_by"):
            rv = fmv(n, rf)
            if rv:
                link_text += "\n" + ("\n".join(rv) if isinstance(rv, list) else str(rv))
        for lm in re.finditer(r"\[\[([^\]\|]+)(\|[^\]]+)?\]\]", link_text):
            target = lm.group(1).split("#")[0].strip()
            if target:
                leaf = re.split(r"[\\/]", target)[-1]
                if target not in known and leaf not in known:
                    add("WARN", "Broken wikilink: [[%s]]" % target, n)
    errs = [i for i in issues if i["Severity"] == "ERROR"]
    warns = [i for i in issues if i["Severity"] == "WARN"]
    infos = [i for i in issues if i["Severity"] == "INFO"]
    print()
    info("Validation across %d notes: %d errors, %d warnings, %d info." % (len(notes), len(errs), len(warns), len(infos)))
    if issues:
        print_table(sorted(issues, key=lambda x: (x["Severity"], x["Rel"])), ["Severity", "Issue", "Title", "Rel"])
    else:
        ok("  Clean. No schema problems found.")
    if a.report and issues:
        save_report(a._maint, "validation", issues)
    return issues

def action_stats(a, vault):
    notes = get_notes(vault, with_archive=True)
    active = [n for n in notes if n.folder != "04_Archive"]
    stale = [n for n in active if date_older_than(fmv(n, "token_last_reviewed"), a.older_than_days)]
    orphans = [n for n in active if (not isinstance(fmv(n, "related"), list) or not fmv(n, "related"))
               and not str(fmv(n, "moc") or "").strip()]
    total_tokens = sum(int(fmv(n, "context_tokens")) for n in active
                       if _to_float(fmv(n, "context_tokens")) is not None)
    info("\n================  VAULT STATS  ================")
    print("  Notes total ........ %d" % len(notes))
    print("  Active ............. %d" % len(active))
    print("  Archived ........... %d" % (len(notes) - len(active)))
    print("  Total tokens ....... %d" % total_tokens)
    print("  Stale token est. ... %d (> %dd)" % (len(stale), a.older_than_days))
    print("  Orphans (no links) . %d" % len(orphans))
    def group(label, fn):
        info("\n  By %s:" % label)
        counts = {}
        for n in active:
            counts[str(fn(n) or "")] = counts.get(str(fn(n) or ""), 0) + 1
        for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
            print("    %-22s %d" % (k, v))
    info("\n  By folder:")
    fcounts = {}
    for n in active: fcounts[n.folder] = fcounts.get(n.folder, 0) + 1
    for k in sorted(fcounts): print("    %-14s %d" % (k, fcounts[k]))
    group("status", lambda n: fmv(n, "status"))
    group("domain", lambda n: fmv(n, "domain"))
    group("document_type", lambda n: fmv(n, "document_type"))
    group("sensitivity", lambda n: fmv(n, "sensitivity"))
    print("==============================================\n")

def action_touch(a, vault):
    if not a.path:
        raise SystemExit("Touch requires --path <note.md>")
    full = a.path if os.path.isabs(a.path) else os.path.join(vault, a.path)
    if not os.path.exists(full):
        raise SystemExit("Note not found: %s" % full)
    raw = read_text_retry(full)
    m = re.search(r"(?m)^access_count:\s*(\d+)", raw)
    count = int(m.group(1)) if m else 0
    update_front_matter_fields(full, {"last_accessed": date.today().isoformat(),
                                      "access_count": count + 1}, preview=a.dry_run)
    ok("Touched: %s (access_count -> %d)" % (a.path, count + 1))

def action_reindex(a, vault):
    notes = get_notes(vault, with_archive=True, with_templates=a.include_templates)
    index = [{
        "uid": fmv(n, "uid"), "title": fmv(n, "title"), "folder": n.folder,
        "domain": fmv(n, "domain"), "topic": fmv(n, "topic"), "subtopic": fmv(n, "subtopic"),
        "document_type": fmv(n, "document_type"), "status": fmv(n, "status"),
        "tags": ";".join(fmv(n, "tags")) if isinstance(fmv(n, "tags"), list) else "",
        "ontology": ";".join(fmv(n, "ontology")) if isinstance(fmv(n, "ontology"), list) else "",
        "context_tokens": fmv(n, "context_tokens"), "confidence": fmv(n, "confidence_score"),
        "sensitivity": fmv(n, "sensitivity"), "last_updated": fmv(n, "last_updated"),
        "last_accessed": fmv(n, "last_accessed"), "summary": fmv(n, "summary"), "rel": n.rel,
    } for n in notes]
    os.makedirs(a._maint, exist_ok=True)
    with open(os.path.join(a._maint, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=2, default=str)
    if index:
        with open(os.path.join(a._maint, "index.csv"), "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(index[0].keys())); w.writeheader(); w.writerows(index)
    ok("Indexed %d notes -> %s" % (len(index), os.path.join(a._maint, "index.json")))
    return index

# ----------------------------- dispatch -------------------------------------
WRITE_ACTIONS = {"RecalcTokens", "Touch"}
ACTIONS = {"Search": action_search, "Duplicates": action_duplicates,
           "RecalcTokens": action_recalc_tokens, "Prune": action_prune,
           "Validate": action_validate, "Stats": action_stats,
           "Touch": action_touch, "Reindex": action_reindex}

def main():
    p = argparse.ArgumentParser(description="Library search & maintenance engine (Python).")
    p.add_argument("--action", required=True, choices=list(ACTIONS.keys()))
    p.add_argument("--vault-path", default=os.path.dirname(os.path.abspath(__file__)))
    p.add_argument("--query"); p.add_argument("--field"); p.add_argument("--value")
    p.add_argument("--mode", choices=["Broad", "Precise"], default="Broad")
    p.add_argument("--search-in", choices=["Body", "FrontMatter", "Both"], default="Both")
    p.add_argument("--regex", action="store_true")
    p.add_argument("--domain"); p.add_argument("--topic"); p.add_argument("--subtopic")
    p.add_argument("--status"); p.add_argument("--document-type"); p.add_argument("--sensitivity")
    p.add_argument("--tag"); p.add_argument("--ontology"); p.add_argument("--keyword")
    p.add_argument("--min-confidence", type=float, default=None)
    p.add_argument("--created-after"); p.add_argument("--created-before")
    p.add_argument("--updated-after"); p.add_argument("--updated-before"); p.add_argument("--accessed-before")
    p.add_argument("--threshold", type=float, default=0.40)
    p.add_argument("--shingle", type=int, default=3)
    p.add_argument("--older-than-days", type=int, default=60)
    p.add_argument("--stale-days", type=int, default=365)
    p.add_argument("--include-archive", action="store_true")
    p.add_argument("--include-templates", action="store_true")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--report", action="store_true")
    p.add_argument("--path")
    a = p.parse_args()

    vault = os.path.abspath(a.vault_path)
    if not os.path.isdir(vault):
        raise SystemExit("VaultPath not found: %s" % vault)
    a._maint = os.path.join(vault, ".maintenance")

    needs_lock = a.action in WRITE_ACTIONS or (a.action in ("Prune", "Duplicates") and a.apply)
    if a.dry_run:
        needs_lock = False
    lock_path = None
    if needs_lock:
        os.makedirs(a._maint, exist_ok=True)
        lock_path = os.path.join(a._maint, ".lock")
        if not enter_lock(lock_path):
            warn("Another maintenance write is already running (lock held at %s)." % lock_path)
            warn("Exiting without changes to avoid a conflict. Retry once it finishes.")
            return
    try:
        ACTIONS[a.action](a, vault)
    finally:
        if lock_path:
            exit_lock(lock_path)

if __name__ == "__main__":
    main()
