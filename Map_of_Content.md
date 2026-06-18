---
uid: 20260614-000000
title: Map of Content
document_type: MOC
summary: Master navigation hub for the Library. Hand-curated (AI-assisted) index of key notes and domain sub-maps.
tags: [moc, index, navigation]
status: Final
sensitivity: internal
schema_version: "1.0"
date_created: 2026-06-14
last_updated: 2026-06-14
last_accessed: 2026-06-14
---

# 🗺️ Map of Content

The master index of the Library. This is how a **human** navigates the vault by hand; the AI navigates by metadata and the graph. Keep this page curated — link only notable notes and domain-level sub-maps, not everything.

> New here? Start with the [[README]] for how the system works, or [[instructions]] for the AI's operating rules.

---

## By Life Area (PARA)

### 🎯 Projects — active work with a deadline
*Things with a goal and an end date. Archived on completion.*

- _No active projects yet. Process the [[00_Inbox]] to populate._

### 🔁 Areas — ongoing responsibilities
*Standards you maintain with no end date.*

- [[knowledge-system-research]] — design research behind this system (carried from the prior E:\AI build).

### 📚 Resources — reference, topics & templates
*Knowledge to keep. Templates live in `03_Resources/_Templates/`.*

- Templates: [[note-template]], [[proxy-note-template]]

### 🗄️ Archive — cold storage
*Completed, dormant, or deprecated. Preserved for history.*

- _Nothing archived yet._

---

## By Domain
*Domain-level sub-maps spin off here as each area grows. The AI creates a dedicated MOC (e.g., "Information Technology MOC") once a domain has enough notes to warrant one.*

- _Domains will appear here as the vault fills out._

---

## Maintenance Pulse
*Quick links to the latest health reports (written to `.maintenance/`).*

- Run `python search_and_maintenance.py --action Stats` for a live dashboard.
- Run `--action Validate --report` and `--action Duplicates --report` to refresh candidate lists.

---

*This hub is curated by the AI during inbox processing and maintenance. When a note is notable, it gets a link here; when a domain matures, it gets its own sub-MOC.*
