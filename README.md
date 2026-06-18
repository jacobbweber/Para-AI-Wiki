# The Library — A Local-First AI Second Brain

> A privacy-focused knowledge management system where **you** capture thoughts in one place, and an **AI partner** organizes, indexes, connects, and maintains everything else.

This document explains *what* the system is, *how* it works, and *why* it is built this way. It is written for humans. The companion file [`instructions.md`](instructions.md) is the precise operating manual for the AI agent.

---

## 1. The Big Idea

Most note systems fail for the same reason: the human has to do two jobs at once. You have to *think* (the creative, valuable part) **and** you have to *file, tag, link, and maintain* (the tedious, error-prone part). Over months the second job collapses — tags drift, folders sprawl, duplicates pile up, and the system rots.

The Library splits those jobs cleanly:

- **You** do one thing: drop everything you capture into a single inbox.
- **The AI** does everything else: it reads each item, asks you for any missing context, writes rich structured metadata, files it in the right place, links it to related notes, and keeps the whole vault healthy over time.

The result is a knowledge base that gets *more* organized as it grows, not less — because the part that normally rots is automated and audited by a script.

### Three components

| Component | Role | Why |
| --- | --- | --- |
| **Obsidian** | The front end you read and write in. | Plain Markdown files on your disk. No lock-in, works offline, renders links as a graph. |
| **Agenta AI** (local LLM) | The librarian. Continuous access to the vault for reading, indexing, tagging, linking, retrieval, and maintenance. | Runs locally, so your knowledge never leaves your machine to be processed. |
| **Google Drive** | Automated backup and sync. | Disaster recovery and multi-device access. Backup only — not where the thinking happens. |

Everything is **local-first**: the canonical copy of your brain lives on your disk as Markdown. The cloud is a safety net, not the source of truth.

---

## 2. How Knowledge Is Organized — the PARA Method

The Library uses **PARA**, a proven organizing scheme that sorts every note by *how actionable it is right now* rather than by subject. Subject is captured in metadata (see Section 4); the folders capture *actionability*.

```text
D:\Library\
├── README.md              ← this file (human overview)
├── instructions.md        ← operating manual for the AI
├── Map_of_Content.md      ← the master index / navigation hub
├── search_and_maintenance.py   ← the maintenance engine
│
├── 00_Inbox\              ← the ONLY door humans use
├── 01_Projects\           ← active work with a goal and an end date
├── 02_Areas\              ← ongoing responsibilities, no end date
├── 03_Resources\          ← reference material, topics, and TEMPLATES
└── 04_Archive\            ← finished, inactive, or deprecated items
```

### What each folder is for

**`00_Inbox` — the single entry point.**
This is the one and only place a human ever puts a new file. A raw idea, a screenshot, a PDF, a half-formed thought at 2 a.m. — all of it lands here, unstructured and untagged. That is fine. The inbox is *meant* to be messy.

**`01_Projects` — things with a finish line.**
A project has a defined goal and a date by which it should be done. "Launch the home lab cluster by August." "Write the Q3 review." When the goal is met, the project's notes move to the Archive.

**`02_Areas` — things you maintain forever.**
An area is a standard you keep up, with no end date. "Health." "Home network." "Finances." "Garden." Areas are never "finished"; they are tended.

**`03_Resources` — reference and templates.**
Topical knowledge you want to keep but isn't tied to a project or responsibility: articles, how-tos, specs, inspiration. **This folder is also the home for templates** — the blank YAML-ready skeletons the AI copies when creating new notes live in `03_Resources\_Templates\`.

**`04_Archive` — cold storage.**
Completed projects, dormant areas, and deprecated resources. Nothing is ever deleted reflexively; it is archived. The Archive keeps the active vault fast and uncluttered while preserving history for retrieval.

### The golden rule of folders

> **Humans only ever touch `00_Inbox`. The AI owns the other four folders.**

This is the single most important rule in the system, and Section 3 explains why it matters so much.

---

## 3. The One-Door Rule — Why Humans Only Use the Inbox

It is tempting to "just file this one note myself" directly into `03_Resources`. Resist it. Here is the reasoning.

The entire value of the Library comes from **consistent, complete, machine-readable metadata** on every note. Search, retrieval, deduplication, token budgeting, and the knowledge graph all depend on the front matter being correct and uniform. A human filing a note by hand will, inevitably and through no fault of their own, produce *slightly* different metadata each time — a missing field here, a differently-worded tag there, an inconsistent domain name. Each small inconsistency is a tiny crack. Across thousands of notes, the cracks become a broken system.

So the system removes the temptation entirely. Humans have **one** job — capture into the inbox — and the AI guarantees that *every* note that reaches the permanent folders has been processed through the exact same metadata pipeline. The inbox is a quality gate. Nothing crosses it without being made consistent.

This is why the folders feel restrictive. The restriction is the feature.

---

## 4. The Metadata — YAML Front Matter

Every Markdown note begins with a block of **YAML front matter**: structured key-value data between two `---` lines. This is what turns a pile of text files into a queryable, connected brain. The human almost never writes this by hand; the AI generates it.

Here is a real example:

```yaml
---
uid: 20260614-153012
title: VMware vSphere Datastore Best Practices
aliases: [vSphere Datastores, VMFS Tuning]
domain: Information Technology
topic: VMware
subtopic: Data Stores
document_type: Procedure
tags: [vmware, storage, vsphere, vmfs]
ontology: [virtualization, san, raid, capacity-planning]
keywords: [datastore, latency, multipathing, thin-provisioning]
language: en
summary: How to size, lay out, and tune vSphere datastores for performance and resilience.
status: Final
priority: Medium
source: Internal lab notes + VMware docs
author: human
created_by: agenta
model: agenta-local-v1
context_tokens: 1840
token_last_reviewed: 2026-06-14
word_count: 1320
content_hash: 8f3a9c...e21
related: [[20260512-101500]]
parent: [[Map_of_Content]]
moc: Information Technology MOC
confidence_score: 0.92
temperature: 0.2
sensitivity: internal
date_created: 2026-06-14
last_updated: 2026-06-14
last_accessed: 2026-06-14
access_count: 1
last_maintained: 2026-06-14
schema_version: "1.0"
---
```

### The fields, grouped by purpose

The schema is **additive** — fields may be added over time, but existing fields are never removed, so old notes always remain valid.

**Identity** — who this note is.

- `uid` — unique ID, a timestamp (`YYYYMMDD-HHMMSS`). Stable forever, even if the title changes.
- `title` — the human-readable name, used for sorting.
- `aliases` — *(added)* other names this note is known by, so search and links find it even under a different phrasing.

**Classification** — what this note is *about*. This is the ontology layer.

- `domain` — the broadest bucket (e.g., *Information Technology*, *Horticulture*).
- `topic` — the subject inside the domain (e.g., *VMware*, *Gardening*).
- `subtopic` — the specific focus (e.g., *Data Stores*, *Planting Tomatoes*).
- `document_type` — the form or purpose (e.g., *Procedure*, *Brainstorming*, *Proxy-Note*, *Template*).
- `tags` — direct keywords for grouping.
- `ontology` — indirect, cross-domain relationships and related concepts.
- `keywords` — *(added)* salient terms extracted from the body to sharpen search, kept distinct from your curated `tags`.
- `language` — *(added)* content language, for multilingual vaults.

**Relationships** — how this note connects to others. This is what builds the graph.

- `related` — *(added)* explicit links to closely related notes.
- `parent` — *(added)* the note or Map of Content this sits beneath.
- `moc` — *(added)* which Map of Content indexes this note.
- `supersedes` / `superseded_by` — *(added)* lineage when notes are merged or replaced, so history is never lost.
- `merge_candidates` — *(added)* set by the maintenance script when it suspects a duplicate; a to-do flag for the AI to review.
- `cluster_id` — *(added)* a similarity-cluster label the maintenance script assigns to near-duplicate groups.

**Retrieval & token budgeting** — how the AI loads this efficiently.

- `summary` — *(added)* a one-to-three sentence précis the AI can read to judge relevance *without* loading the whole note. Huge cost saver for retrieval.
- `context_tokens` — estimated token weight of the note, so the AI can budget its context window.
- `token_last_reviewed` — when the token estimate was last recalculated.
- `word_count` — *(added)* a cheap companion to `context_tokens`.
- `content_hash` — *(added)* a fingerprint of the body, used to detect changes and exact duplicates without re-reading.
- `embedding_id` — *(added, optional)* pointer to an external vector-store entry if semantic search is layered on later.

**Lifecycle & status** — where this note is in its life.

- `status` — current state (*Idea*, *Needs Deep Research*, *Draft*, *Final*, etc.).
- `priority` — *(added)* attention level, for processing and pruning order.
- `review_due` — *(added)* the next date this note should be re-checked for freshness.
- `pinned` — *(added)* protect a note from automatic archival or pruning.
- `archive_after` — *(added)* an expiry date for transient notes.
- `schema_version` — *(added)* which version of this schema the note follows, so future migrations are safe.

**Provenance & source** — where this knowledge came from.

- `source` — original origin or intellectual history.
- `author` — *(added)* `human`, `ai`, or an external author.
- `created_by` — *(added)* which agent processed it.
- `model` — *(added)* the model used in the last AI pass (telemetry).

**Telemetry** — usage data the system tracks automatically.

- `date_created` — first creation.
- `last_updated` — most recent edit.
- `last_accessed` — last time the note was read or retrieved. Drives pruning decisions.
- `access_count` — *(added)* how many times it has been retrieved.
- `last_maintained` — *(added)* last time the maintenance script touched it.

**AI control & privacy** — how the AI should treat this note.

- `confidence_score` — AI's confidence in the metadata's accuracy or the content's certainty (0–1).
- `temperature` — a directive on how creatively (high) or rigidly (low) the AI should interpret the content.
- `sensitivity` — *(added)* `public` / `internal` / `private` / `secret`. Controls privacy and what may sync to the cloud.
- `do_not_sync` — *(added)* hard exclude from Google Drive backup.

**Proxy fields** — used only on proxy notes (see Section 5).

- `target_artifact` — path to the real non-text file this note stands in for.
- `artifact_type` — *(added)* the kind of file (e.g., `image/jpeg`, `application/xlsx`).
- `artifact_hash` — *(added)* fingerprint of the binary asset, to detect changes.

The full field-by-field reference, including required-vs-optional and exact value formats, lives in [`instructions.md`](instructions.md).

---

## 5. Proxy Notes — Making Images and Spreadsheets Searchable

Obsidian and the AI think in Markdown, but real life is full of PDFs, screenshots, Word docs, and spreadsheets. The Library handles these with **proxy notes**.

A proxy note is a small Markdown file that *stands in for* a non-text file. It carries the full YAML schema — including a human/AI-written `summary` of what the binary file contains — and points to the real asset with the `target_artifact` field:

```yaml
---
uid: 20260614-160500
title: Network Rack Diagram (photo)
document_type: Proxy-Note
summary: Photograph of the server rack showing switch and patch-panel layout as of June 2026.
target_artifact: 03_Resources\Assets\rack_photo_2026-06.jpg
artifact_type: image/jpeg
tags: [homelab, networking, hardware]
# ...full schema continues...
---

Hand-written description of what the diagram shows, so the AI can search and reason
about an image it cannot directly read.
```

Now a photograph is fully indexable, searchable, and linkable — the AI reasons over the text proxy, and the proxy points you to the real file. Nothing in your knowledge base is invisible just because it isn't text.

---

## 6. The Workflows — How Work Actually Flows

### 6.1 Capture (you, anytime)

You drop anything into `00_Inbox`. No metadata, no filing, no decisions. Capture should be frictionless or you won't do it.

### 6.2 Inbox processing (you + AI, scheduled)

A scheduled job kicks off a short collaborative session:

1. The AI presents the next inbox item.
2. It asks you for any context it can't infer ("Is this for the cluster project or general reference?").
3. It generates the complete, schema-correct YAML front matter.
4. It files the note in the correct PARA folder and links it into the graph and the relevant Map of Content.

You provide judgment; the AI provides consistency. The inbox empties, and every graduated note is uniformly structured.

### 6.3 Token review (script + AI, scheduled)

The maintenance script finds notes whose `token_last_reviewed` is older than 60 days, the AI recalculates their `context_tokens`, and the timestamp is refreshed. This keeps the AI's context-window budgeting accurate as notes are edited.

### 6.4 Maintenance & health (script + AI, scheduled)

The `search_and_maintenance.py` script runs broad and precise queries across all front matter and the note bodies to surface:

- **Duplicates and near-duplicates** — clusters of notes covering the same ground, returned as *candidates* for the AI (and you) to review, merge, or collapse.
- **Stale token estimates** — notes overdue for recalculation.
- **Unused notes** — notes whose `last_accessed` is far in the past, flagged as candidates for the Archive.
- **Schema problems** — missing required fields, malformed dates, broken links, and proxy notes whose `target_artifact` no longer exists.
- **Vault statistics** — counts, distributions, and health metrics.

A crucial design choice: **the script finds and reports; it does not decide.** It hands you and the AI a list of candidates. The *judgment* — "merge these two," "archive that one," "these only look similar" — stays with the human, assisted by AI. The script's job is to make sure nothing slips through unnoticed. Section 7 covers it in depth.

### 6.5 Backup (automatic)

Google Drive syncs the vault continuously, honoring the `sensitivity` and `do_not_sync` fields so private notes can be held back from the cloud.

---

## 7. The Maintenance Engine — `search_and_maintenance.py`

This Python script is the system's immune system. It runs on **Python 3.8+** (standard library only) on Windows, macOS, and Linux — no external packages, including for similarity detection.

You drive it with an `--action` argument. The headline capabilities:

**`Search` — query anything, broadly or precisely.**
Search across *any* YAML field, across the body text, or both. Filter by `domain`, `topic`, `status`, `tag`, `document_type`, date ranges, confidence thresholds, and more. Two modes: **Precise** (exact field matches) and **Broad** (fuzzy, partial, case-insensitive matching across many fields at once). This is the same engine the AI uses for retrieval.

**`Duplicates` — find overlapping knowledge.**
Uses text *shingling* and Jaccard/cosine similarity over both the body and key metadata to group notes that say similar things. Returns ranked clusters above a similarity threshold you set, written to a report. You then point the AI at the report to decide whether each cluster should be merged into one note, synthesized into a new note, or left alone.

**`RecalcTokens` — keep budgets honest.**
Recalculates `context_tokens` and `word_count`, refreshes `content_hash`, and stamps `token_last_reviewed`. By default it only touches notes older than the review window (60 days).

**`Prune` — surface dead weight.**
Lists notes whose `last_accessed` exceeds a staleness threshold (and which aren't `pinned`) as archive candidates. With an explicit `-Apply` flag it can move them to `04_Archive`; without it, it only reports.

**`Validate` — enforce the schema.**
Flags missing required fields, malformed dates, invalid enum values, broken `[[wikilinks]]`, and proxy notes whose `target_artifact` is missing on disk.

**`Stats` — see the whole vault.**
A dashboard: note counts per folder, status and domain distributions, total token weight, stale-note counts, and orphan counts.

Every action can write a timestamped report to `.maintenance\` so you (and the AI) have an auditable trail. Full parameter documentation lives at the top of the script and in [`instructions.md`](instructions.md). The script is also built to run safely alongside other programs touching the same files — see Section 8.

---

## 8. Safety, Concurrency & Deployment

The Library is meant to be shared and run unattended, so the maintenance script is built to be safe even when other programs are touching the same files at the same time — your editor, the AI, and a cloud-sync client can all be active at once. This safety is **universal**: it lives entirely inside the script, depends on no external packages, and works the same anywhere Python 3.8+ runs (Windows, macOS, Linux).

### What the script guarantees on its own

**Atomic writes.** When the script updates a note's metadata, it never writes "in place." It writes the new version to a temporary file in the same folder and then atomically swaps it into position. Any other program reading that note sees either the complete old version or the complete new version — never a half-written file. This is what prevents the truncated/corrupted files that careless writers can leave behind.

**Single-instance lock.** Only one maintenance run that *modifies* notes can execute at a time. Before a write-capable action (token recalculation, telemetry, applying duplicate clusters, pruning) the script acquires a lock file at `.maintenance/.lock`; if another run already holds it, the new run exits cleanly instead of colliding. A lock left behind by a crashed run is automatically reclaimed after an hour. Read-only actions (search, stats, validate, reindex) never take the lock, so they never block — atomic writes already guarantee they can't see a torn file.

**Retry with backoff.** If a file is momentarily locked by another program (common when a sync client or editor has it open), the script waits briefly and retries a few times rather than failing outright.

**Optimistic concurrency.** Before saving, the script checks whether the note changed since it read it. If you or the AI edited that note in the meantime, the script declines to overwrite your change and skips the note — the next run picks it up. Maintenance can never clobber a human or AI edit.

### Working with a cloud-sync client (Google Drive, OneDrive, Dropbox…)

The script protects its *own* writes, but a sync client is a separate program with its own behavior. Two settings make the pairing smooth:

1. **Prefer "mirror"/"keep local" mode over "stream"/"files-on-demand."** Streaming modes keep files as placeholders and rehydrate them on access; that on-demand layer is the main source of sync hiccups. Mirroring keeps full local copies and is far more predictable. (Costs disk space.)
2. **Keep the volatile scratch out of sync.** The `.maintenance/` folder (regenerated reports, the index, the lock) and the brief `.tmp` write files don't need to be synced — syncing them just creates churn and extra contention. The bundled `.gitignore` already lists exactly what to exclude; mirror those patterns in your sync client's ignore settings if it supports them.

For the most robust setup of all, treat the synced folder as **backup only**: keep the working vault on a local (non-synced) path and run a scheduled snapshot to the cloud (e.g., `robocopy`, `rclone`, or a zip-and-upload). The cloud then only ever sees a quiet, consistent copy and can never race a live write — which is exactly the "Drive = backup, not source of truth" principle from the top of this document.

### Scheduling

On Windows, schedule it with **Task Scheduler**; on macOS/Linux use `cron`. A nightly token/validation pass and a weekly duplicate/prune pass is a sensible cadence. Because of the single-instance lock, it is safe even if one run is still finishing when the next is triggered.

---

## 9. Integrating This System Into Your Own AI Setup

This system is designed to be **plugged into any AI agent or assistant** — not just
one product. This section is for someone who has the vault on disk and wants their
own AI to operate it. The short version: **point your agent at the operating manual,
give it file access and a shell, and it works.** The longer version explains the
approaches and gives a copy-paste boilerplate.

### 9.1 The mental model — three layers you consume

```
   YOUR SIDE                          PROVIDED BY THIS SYSTEM
 ┌──────────────┐                   ┌──────────────────────────────────────────┐
 │ your AI agent│ ── reads ───────► │ CONTRACT   instructions.md · _capabilities/│
 │ + interface  │                   │            · schema in _Templates/         │
 │ (you build)  │ ── runs ────────► │ TOOLING    search_and_maintenance.py · bin/ │
 │              │ ── reads/writes ► │ DATA       the vault (00_Inbox … 04_Archive)│
 └──────────────┘                   └──────────────────────────────────────────┘
```

You bring the **agent** (any LLM-driven assistant) and the **interface** (chat, a
button, a cron trigger — however your users invoke it). The system provides the
**contract** (what to do), the **tooling** (deterministic operations), and the
**data layout**. Nothing here assumes a specific AI vendor.

### 9.2 What your agent needs to be able to do

| Capability | Why | Required? |
|---|---|---|
| **Read files** in the vault | read notes, the manual, capability specs | Yes |
| **Write files** in the vault | create/edit notes | Yes (to ingest/maintain) |
| **Run a shell command** | call the tooling (search, validate, dedup, recalc) | Recommended |
| **Be given a system prompt / instructions** | load the operating manual | Yes |

Runtime prerequisite on the machine: **Python 3.8+** (standard library only) for
`search_and_maintenance.py` and `bin/dataset_tool.py`. Only `.xlsx` datasets need an
extra package (`pip install openpyxl`); CSV and everything else need nothing extra.
Obsidian is optional, for human browsing.

If your agent **cannot run a shell**, it can still operate the vault by reading and
writing files directly (the tooling is an accelerator, not a hard dependency) — it
just won't have automated search/validation/dedup at scale.

### 9.3 Three ways to integrate (pick one)

**A — Instructions injection (simplest; "just use these instructions").**
Put the operating manual into your agent's system prompt (or load it at session
start), and grant file + shell access. The agent reads `_capabilities/<x>.md` on
demand. This is the whole integration for most setups — see the boilerplate in §9.4.

**B — Capability/skill registration.**
If your framework has a notion of skills/tools/slash-commands, register each file in
`_capabilities/` as a skill (its filename = the skill, its body = the instructions)
and expose the two tooling entry points as callable tools. Triggers map to specs:
"process the inbox" → `ingest`, "find X" → `retrieve`, "weekly cleanup" → `maintain`,
"this is a spreadsheet" → `ingest-dataset`, etc.

**C — Programmatic / headless.**
Run the deterministic tooling directly from a script or scheduler (no LLM needed for
those parts): `python search_and_maintenance.py --action Validate|RecalcTokens|Reindex|Stats`
on a cron. Bring in the LLM only for judgment steps (ingest classification,
consolidate decisions). Good for unattended maintenance.

### 9.4 Boilerplate — drop this into your AI system

Replace `{VAULT_PATH}` with the absolute path to this folder. This is enough to make
a capable file+shell agent operate the vault correctly:

```text
You operate a local, file-based knowledge vault at {VAULT_PATH}. It is a
PARA-organized, schema-controlled Markdown knowledge base with a maintenance tool.
You have read/write access to that folder and can run shell commands.

OPERATING MANUAL (authoritative — read and follow it exactly):
  {VAULT_PATH}/instructions.md

CAPABILITY PLAYBOOKS (read the relevant one before each operation):
  {VAULT_PATH}/_capabilities/  →  ingest, retrieve, consolidate, maintain,
                                   chunk-document, ingest-dataset

TOOLING (deterministic; you invoke these, you do not reimplement them):
  python {VAULT_PATH}/search_and_maintenance.py --action <Search|Duplicates|
        RecalcTokens|Prune|Validate|Stats|Touch|Reindex> [params]
  python {VAULT_PATH}/bin/dataset_tool.py <map|extract> ...

RULES OF ENGAGEMENT (non-negotiable):
  1. Humans add files only to 00_Inbox/. You own 01_Projects, 02_Areas,
     03_Resources, 04_Archive.
  2. Every note you create carries the FULL YAML front matter defined in
     instructions.md §3. Reuse tags from 03_Resources/_Templates/tag-authority.md.
  3. Retrieve with progressive reveal: read summaries → one note/chunk → only the
     needed slice. Never bulk-read the tree.
  4. Find, don't decide destructively: merges, archives, deletes, and prunes need
     human confirmation. The tooling reports candidates; you propose; the human approves.
  5. Note writes are atomic and single-instance-locked by the tooling. If you write
     files yourself, honor {VAULT_PATH}/.maintenance/.lock and write atomically.
  6. Never store secrets, government IDs, financial-account numbers, health data, or
     home addresses unless the user explicitly asks.

START: read instructions.md, then act on the user's request using the capability
that fits.
```

For a **single task** (e.g. a headless "process my inbox" job) you can be even
terser:

```text
Operate the vault at {VAULT_PATH} per its instructions.md. Process every item in
00_Inbox/ using _capabilities/ingest.md. Ask me only the questions you can't infer.
```

### 9.5 Quick integration checklist

1. Put the vault folder on disk (or in your repo). Keep `.maintenance/`, `*.tmp`,
   and `.lock` out of cloud sync / version control (see the bundled `.gitignore`).
2. Ensure Python 3.8+ is installed (plus `openpyxl` only if you'll ingest `.xlsx`).
3. Give your agent file read/write access to the folder and the ability to run shell
   commands.
4. Load the §9.4 boilerplate as the agent's system prompt (Approach A), or register
   the `_capabilities/` specs as skills (Approach B).
5. **Verify the wiring:** have the agent (or you) run
   `python {VAULT_PATH}/search_and_maintenance.py --action Stats` and `--action Validate`.
   Clean output = you're connected.
6. Build your interface (chat loop, commands, schedule) — that part is yours.

### 9.6 What you build vs. what's provided

You build the **interface and triggers** (how users invoke the agent, any UI, when
maintenance runs). Everything else — the operating rules, the schema, the capability
playbooks, and the deterministic tooling — is provided and runtime-agnostic. Swap the
AI vendor or reimplement the tooling in another language; the contract is unchanged.

---

## 10. Maps of Content — Navigating by Hand

Metadata and the graph are how the *AI* navigates. **Maps of Content (MOCs)** are how *you* navigate. `Map_of_Content.md` is the master hub — a hand-curated (AI-assisted) page of links to your most important notes and to domain-level sub-maps. Think of it as the table of contents for your brain. As a domain grows, the AI can spin off a dedicated MOC for it (e.g., an *Information Technology MOC*) and link it from the master map.

---

## 11. Quick Start

1. **Open the vault in Obsidian.** Point Obsidian at `D:\Library`.
2. **Capture.** Throw your first few notes, ideas, and files into `00_Inbox`.
3. **Process the inbox** with the AI when prompted — answer its questions and let it file everything.
4. **Browse** via `Map_of_Content.md` and the Obsidian graph view.
5. **Let maintenance run** on a schedule, and review the candidate reports it produces.

That's the whole loop: *you capture, the AI organizes, the script keeps it healthy.*

---

## 12. Design Principles (the "why" in one place)

- **Local-first.** Your brain lives on your disk in plain Markdown. No lock-in, full privacy, works offline.
- **One door for humans.** A single inbox guarantees uniform metadata and prevents slow decay.
- **Separation of labor.** Humans bring judgment and context; the AI brings consistency and tireless upkeep.
- **Everything is indexable.** Proxy notes pull images and binaries into the searchable graph.
- **Additive, never destructive.** The schema only grows; nothing is deleted reflexively — only archived.
- **Find, don't decide.** The maintenance script surfaces candidates; humans and AI make the calls.
- **Auditable.** Telemetry and maintenance reports make the system's behavior transparent over time.

---

*Human overview ends here. For the AI's exact operating rules, see [`instructions.md`](instructions.md). For the maintenance commands, see [`search_and_maintenance.py`](search_and_maintenance.py).*
