# Capability: ingest

Turn a raw item the human dropped in `00_Inbox/` into a filed, fully-tagged note in
the correct PARA folder. This is the only path by which content enters the
permanent vault.

## Trigger
A file exists in `00_Inbox/`, or the human asks to "process the inbox."

## Inputs
- One inbox item (text note, or a non-text asset → see `chunk-document` / `ingest-dataset`).
- Optional human context answering non-inferable questions (destination, project linkage, sensitivity).

## Tooling
- `python search_and_maintenance.py --action Search --query "<key terms>" --mode Broad`
  → check for existing related/duplicate notes before filing.
- `python search_and_maintenance.py --action Validate --report` → after writing, confirm schema integrity.
- The agent writes the note file itself (atomic write per write-safety convention);
  the tooling does not author note bodies.

## Agent steps (judgment)
1. Read the item. If it is non-markdown (image, pdf, xlsx…), branch to the proxy/
   chunk/dataset path instead of inlining it.
2. Infer every inferable field (see schema). Identify the few non-inferable gaps and
   ask the human one batched, minimal set of questions — never ask what you can infer.
3. Classify: `domain` / `topic` / `subtopic`. Reuse existing values (search first);
   draw tags from the authority list (`03_Resources/_Templates/tag-authority.md`),
   reusing before inventing.
4. Decide the PARA destination by *actionability*: deadline+goal → `01_Projects`;
   ongoing duty → `02_Areas`; reference/topic/template → `03_Resources`; done/dead → `04_Archive`.
5. Write the full YAML front matter (all required fields) + a 1–3 sentence `summary`.
   Compute `uid`, `context_tokens`, `word_count`, `content_hash`, dates per schema.
6. Link it into the graph (`related`, `parent`, `moc`) and update `Map_of_Content.md`
   if the note is notable.
7. Move/author the file into the destination folder; remove the inbox original.

## Outputs
- One schema-valid note in the correct PARA folder.
- Updated `Map_of_Content.md` (if notable); empty(er) inbox.

## Done when
- `Validate` reports no errors for the new note, and the inbox item is gone.
