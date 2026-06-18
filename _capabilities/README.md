# Capabilities — runtime-agnostic skill specs

This folder defines **what the system can do**, as a set of capability specs that
are independent of any particular AI runtime. They are the contract; *your agent
(or anyone's) writes the interface layer on its own side.*

## Why this exists

The Library is designed to be driven by an AI agent, but it must not depend on any
one agent product. So the operating knowledge is split into three portable layers:

1. **Contract (instructions + schema)** — [`../instructions.md`](../instructions.md)
   and the schema in [`../03_Resources/_Templates/`](../03_Resources/_Templates/):
   the rules, the YAML fields, the routing logic. Plain Markdown.
2. **Tooling (reference implementation)** — [`../search_and_maintenance.py`](../search_and_maintenance.py):
   deterministic operations (search, dedup detection, token recalc, validation,
   pruning, indexing). Pure-Python stdlib, no agent dependency. A different runtime
   may reimplement these in any language; the I/O contract is what matters.
3. **Capabilities (this folder)** — one spec per operation, each stating its
   purpose, inputs, the tooling it calls, the *judgment* steps a model must do, its
   outputs, and its done-conditions.

## The agnostic model

```
  your agent runtime  ──drives──►  CAPABILITY SPEC  ──calls──►  TOOLING (.py)
   (you build this)                (this folder)               (reference impl)
        │                                │                          │
        └─ surfaces to user,            └─ defines the contract:    └─ does the
           decides when to invoke,         inputs/steps/outputs        deterministic
           supplies judgment                                            file work
```

A capability spec never says "use tool X in product Y." It says: *given these
inputs, run this deterministic command (or an equivalent), then apply this
judgment, and produce this result.* Anything an LLM-style agent needs to act is in
the spec; anything machine-deterministic is in the tooling. The interface — slash
commands, buttons, a chat loop, a cron trigger — is entirely yours to build.

## Division of labor (the invariant)

- **Tooling does the mechanical, deterministic work** — enumerating files, parsing
  YAML, computing hashes/tokens, similarity math, moving files, regenerating the
  machine index. Consistent and reproducible.
- **The agent does the judgment** — classification, authority-controlled tagging,
  writing the summary/abstract, deciding merge vs. keep-separate, deciding what to
  prune. Meaning, not mechanics.

Keep that line and the system stays portable: swap the agent, swap the tooling
language, the contract is unchanged.

## The capabilities

| Spec | Purpose |
|------|---------|
| [`ingest.md`](ingest.md) | Turn a raw inbox item into a filed, fully-tagged note. |
| [`retrieve.md`](retrieve.md) | Find the minimum-sufficient content via progressive reveal. |
| [`consolidate.md`](consolidate.md) | Detect and resolve duplicate / overlapping notes. |
| [`maintain.md`](maintain.md) | Scheduled health pass: tokens, validation, pruning, audit. |
| [`chunk-document.md`](chunk-document.md) | Split a large source into index + chunks (three-tier). |
| [`ingest-dataset.md`](ingest-dataset.md) | Map a spreadsheet's structure, then extract only what's needed. |

Each spec is self-contained. Read the one you need; you do not need the others to
implement it.

## Conventions referenced by the specs

- **Tooling entry point:** `python search_and_maintenance.py --action <Action> [params]`
  (Python 3.8+, standard library only; runs on Windows, macOS, and Linux).
- **Schema:** every note carries the YAML front matter defined in
  `instructions.md` §3. Required fields are non-negotiable.
- **Write safety:** all note writes are atomic and single-instance-locked by the
  tooling; a custom reimplementation should preserve those guarantees (see
  `../README.md` §8).
- **Meta folders:** names starting with `_` (like this one) or `.` are *not* notes
  and are skipped by the tooling's note scan.
