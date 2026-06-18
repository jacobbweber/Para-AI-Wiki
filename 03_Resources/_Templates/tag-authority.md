---
uid: 20260614-tagauth
title: Tag Authority List
document_type: Reference
summary: The canonical, controlled vocabulary for the `tags` field. Reuse a term from here before inventing a new one; add new terms here when you do.
tags: [meta, taxonomy, tags]
status: Final
sensitivity: internal
schema_version: "1.0"
date_created: 2026-06-14
last_updated: 2026-06-14
last_accessed: 2026-06-14
---

# Tag Authority List

`tags` are **authority-controlled**: a small, consistent vocabulary beats a large,
drifting one for plain-text search. The rule for every note:

> **Reuse an existing term before inventing one. If you must invent, add it here
> (alphabetical, lowercase, kebab-case) in the same action.**

This file is the single source of truth for the controlled vocabulary. Keep it
alphabetical. Prefer specific, singular-ish nouns. Retire or merge near-duplicates
during `consolidate`.

## How tags relate to other fields
- `domain` / `topic` / `subtopic` — the ontological *placement* (one each).
- `tags` — controlled cross-cutting keywords from THIS list (many).
- `ontology` — indirect/related concepts and cross-domain links (free-er).
- `keywords` — auto-extracted salient terms from the body (not controlled).

## Canonical terms
Seeded from prior research plus general-purpose categories. Prune what you don't use.

```
admin, agent-memory, agentic-ai, ai, architecture, automation, backup,
brainstorming, career, checklist, cloud, code, configuration, contracts,
data, dataset, decision, documentation, finance, gardening, hardware, health,
home-lab, howto, infrastructure, knowledge-base, knowledge-graph, llm,
maintenance, meta, ml, networking, note-taking, onboarding, ontology,
personal, planning, procedure, productivity, project-management,
prompt-engineering, python, rag, reference, research, retrieval, security,
storage, taxonomy, template, testing, tooling, troubleshooting, vector-db,
virtualization, vmware, wiki, workflow
```

## Maintenance
- Adding a term: insert it alphabetically above, in the same edit where you first use it.
- Merging: when two terms mean the same thing, pick the survivor, repoint notes
  during `consolidate`, and delete the loser here.
- Audit: `python ../../search_and_maintenance.py --action Stats` shows tag-bearing
  notes; a future tooling pass can diff used tags against this list to flag drift.
