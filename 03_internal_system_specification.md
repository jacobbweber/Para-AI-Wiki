# Internal System Specification

> **Status:** ✅ Implemented · **Last-updated:** 2026-06-12
> **Maps-to:** `src/agent_loop.py`, `src/llm_router.py`, `src/integrations/task_dispatcher.py`, `src/integrations/task_board.py`, `src/engine/{dag_runner,langgraph_runner,supervisor}.py`, `src/integrations/{memory,scheduler,knowledge_base,vault_watcher,librarian}.py`, `src/api_server.py`, `src/db.py`
> **Depends-on:** [01 ADD](../01_architecture_vision/01_architecture_definition_document.md); detailed per-subsystem truth lives in `src/specs/*.md`.

Deep-dive technical blueprint of the core engines, execution states, and data
pipelines — *how* to build, maintain, and optimize the OS execution loops.

---

## 1. Technical Component Overview

Core engines and their runtime entry points:

- **ReAct agent loop** (`agent_loop.execute_agent_loop`): the universal execution
  primitive for both interactive chat and background cards. Phases: context
  handoff check → LLM call → parse all tool calls (`findall`) → per-call validate
  /allowlist/approval-gate/dispatch → feed results back → loop until a tool-free
  final answer or the circuit breaker.
- **Turn Runner** (`task_dispatcher.run_task_dispatcher_loop`): the read-write
  pull loop. Reads `agent_engine` config each tick; claims cards atomically;
  runs sequentially (one card / one LLM link) by default or up to
  `max_parallel_agents` concurrently when `parallel_agents` is on.
- **LLM router** (`llm_router.generate_response`): provider-agnostic OpenAI-style
  streaming POST; resolves base_url per provider; records tokens/latency;
  enforces Fortress budget.
- **Workflow engines:** `dag_runner` (ephemeral, parallel branches, semaphore 5)
  and `langgraph_runner` (durable, checkpointed, resumable) — sharing ONE node
  executor (`run_node_action`). No third engine permitted.
- **Daemon supervisor** (`engine/supervisor.py`): launches/pauses/resumes/kills
  background OS processes via `psutil`; monitor loop reaps exits.
- **Background services** booted in the FastAPI lifespan: vault watcher (10s),
  task dispatcher (10s), supervisor monitor (2s), scheduler (60s, if enabled).

## 2. State Management & Lifecycle Engine

**Card lifecycle (the system's primary state machine)** — `task_board`:

```
BACKLOG (queued) ──claim──▶ IN_PROGRESS ──success──▶ DONE
                                 ├─ human needed (approval/budget) ──▶ BLOCKED ──unblock──▶ BACKLOG
                                 └─ retryable error ──▶ BACKLOG (≤3) ──▶ FAILED
```

- Claims use `BEGIN IMMEDIATE` write-lock transactions (no double-claim).
- Failure classification (`task_dispatcher._classify_failure`): budget/approval
  → `BLOCKED` (human must act); everything else → retry (3-strike circuit breaker).
- Status set validated server-side (`task_board.VALID_STATUSES`).

**Process lifecycle** (`supervisor`): `RUNNING → PAUSED → RUNNING`, `→ TERMINATED`,
or natural `COMPLETED/FAILED`; orphans from prior runs reset to `TERMINATED` on boot.

**Workflow run lifecycle** (`langgraph`/`dag`): `running → paused (human gate) →
completed | failed`; LangGraph persists checkpoints so a paused thread survives
restarts.

**Session lifecycle** (`agent_loop`): per-WebSocket chat history; when estimated
tokens exceed `max_context_tokens × threshold`, the session-handoff compressor
summarizes, archives to `vaults/handoffs/`, and rebuilds the message list.

**Profile lifecycle** (`profile_manager` + `api_server.restart_background_tasks`):
switching a profile cancels loops, re-inits all per-profile DBs, re-seeds the
vault skeleton + `SOUL.md`, reloads plugins, and restarts loops.

## 3. Feature Definitions & Logic Blocks

| Feature | Logic block | Spec |
|---|---|---|
| Conversational agent | ReAct loop + tool gating + room/markdown stream | `src/specs/react_agent_loop.md` |
| Kanban task engine | pull dispatch, BLOCKED state, parallel toggle | `src/specs/kanban_task_board.md` |
| Conversation memory | short-term store, recall-N, decay | `src/specs/memory_dream_loop.md` |
| Dream loop | idle consolidation → vault note | `src/specs/memory_dream_loop.md` |
| Knowledge RAG | FTS5 + nomic vector hybrid fusion | `src/specs/knowledge_base_rag.md` |
| Knowledge Vault + Librarian | taxonomy, front matter, Tier-0/1 retrieval | `src/specs/knowledge_vault.md` |
| LLM routing + providers | Ollama/LM Studio, model discovery | `src/specs/llm_routing_cost.md` |
| DAG workflows | topological parallel node graph | `src/specs/dag_pipeline_foundry.md` |
| LangGraph workflows | durable checkpointed threads | `src/specs/langgraph_engine.md` |
| Daemon supervisor | process control + telemetry | `src/specs/daemon_supervisor.md` |
| Profiles | workspace virtualization | `src/specs/profile_management.md` |
| Fortress | budget guard + YOLO + approval gates | `src/specs/llm_routing_cost.md` |
| Plugins | dynamic skill packs + tool dispatch | (this doc + `plugins/manager.py`) |
| System schematic | live self-model visualization | `src/specs/dashboard_v3.md` |

## 4. Internal API & IPC Specifications

**Tool-call protocol (model ↔ tools):** XML in the assistant stream —
`<tool_call name="plugin_id.tool" args='{"k":"v"}' />` — parsed with `findall`
(all calls per turn). Results return as `<tool_response name="...">...</tool_response>`.
Args must be a JSON object; parse failures return a self-correcting error string.

**Plugin contract** (`plugins/base.py`): a plugin subclasses `BasePlugin` and
decorates methods with `@tool(name, description, parameters)`; the manager
auto-discovers tools, builds prompt definitions, and dispatches with type
coercion. Enablement is per-plugin in the registry; agents may restrict via
`whitelisted_tools`.

**HTTP/WS surface:** see [05 Web Frontend](../03_ui_ux_frontend/05_web_frontend_specification.md)
§ and `src/specs/api_server.md` for the full route catalog. Key IPC:
`/ws/chat` (chat + `{type:'chat',content,model}` overrides + approval responses),
`/ws/logs` (telemetry stream), `/api/tasks*`, `/api/vault/{capture,lookup,search,file}`,
`/api/config/llm{,/models}`, `/api/workflows*`, `/api/langgraph/*`, `/api/supervisor/*`.

**Cross-loop IPC:** background loops broadcast state JSON to UI WebSockets via the
`ConnectionManager`; the telemetry `log_message` is monkey-patched to also push to
`/ws/logs`. DAG/LangGraph human gates resolve via future-backed maps.

**DB access contract:** every connection goes through `db.connect()` (WAL,
`busy_timeout=5000`, `synchronous=NORMAL`). No raw `sqlite3.connect` in modules.

## 5. Error Handling & Failure Recovery Modes

- **LLM transport:** connect-timeout 15s, no read-timeout (streaming); failures
  return sentinel strings (`[SYSTEM ERROR …]`, `❌ [Fortress Alert]…`) which the
  loop surfaces immediately rather than parsing as output.
- **Background card failures:** classified to BLOCKED (human) vs retry; 3 strikes
  → FAILED with the crash logged to telemetry and broadcast to the UI.
- **Circuit breaker:** ReAct turn cap (5 / 50 YOLO) returns a partial answer
  rather than looping forever.
- **Workflow nodes:** per-node `max_retries`/`retry_delay`/`timeout`; an `error`
  source-handle routes failures, otherwise the run fails with node context.
- **Supervisor:** spawn failures recorded as `FAILED`; orphan cleanup on boot;
  recursive child-tree kill.
- **Indexer/embeddings:** embedding fetch failures degrade to keyword-only search
  (never crash indexing); front-matter parse failures fall back to plain-document
  indexing.
- **WebSocket resilience:** UI auto-reconnects with backoff; dead sockets pruned
  on broadcast.
- **Infra recovery:** `restart: always` + systemd-managed dockerd revive
  containers after WSL idle-out; `.env` host mapping regenerated each start.
