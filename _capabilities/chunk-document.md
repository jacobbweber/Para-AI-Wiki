# Capability: chunk-document

Bring a large source (long article, PDF, transcript, spec) into the vault as a
**three-tier** work so it can be retrieved a slice at a time instead of loaded
whole. This is the token-economy pattern for big content.

## Trigger
An ingested item is large enough that loading it whole would be wasteful (rule of
thumb: more than a few thousand tokens, or any multi-section document).

## Structure produced
```
<destination-folder>/<work-slug>/
├── source.<ext>     # Tier 3 — the original, untouched (or a proxy if binary)
├── index.md         # Tier 2 — OUR YAML front matter + summary + section map
└── chunks/
    ├── 0001.md      # Tier 3 — body split by section/page (~300–800 words each)
    ├── 0002.md
    └── …
```
`<destination-folder>` is the PARA folder chosen by actionability (usually
`03_Resources` for reference, `02_Areas` for ongoing topics).

## Tooling
- The split is mechanical and may be done by any script/util (split on headings or
  page breaks). The reference toolkit treats the work's `index.md` as the note, so
  no special action is required; run `Validate` and `Reindex` after.
- For binary sources, pair with a proxy note (`document_type: Proxy-Note`,
  `target_artifact` → `source.<ext>`).

## Agent steps (judgment)
1. Decide chunk boundaries by meaning — prefer section/heading breaks over blind
   length cuts; keep each chunk self-contained (~300–800 words).
2. Number chunks zero-padded (`0001.md`, `0002.md`) in reading order.
3. Write `index.md` with full schema front matter, a 1–3 sentence `summary`, and a
   **section map**: a list linking each chunk to its heading/topic so a reader can
   jump straight to the right slice. Set `context_tokens` for the index note only
   (the chunks are read on demand); optionally record total tokens in the body.
4. Keep `source.<ext>` verbatim as the ground truth.

## Outputs
- A navigable work whose Tier-2 `index.md` lets retrieval open only the needed chunk.

## Done when
- `index.md` validates, its section map covers every chunk, and `source` is preserved.
