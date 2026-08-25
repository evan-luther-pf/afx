# AFX Architecture

afx is a native Zig terminal-first orchestration coding-agent harness. Product constants in `src/core/product.zig` select its name, private state paths, project configuration, skill and agent roots, prompt identity, and terminal wordmark.

## Orchestration

- `task` resolves bundled or Markdown-defined roles and creates child sessions.
- `hub` lists the current durable agent tree and coordinates explicit IDs without replacing the underlying subagent manager.
- `todo` persists phased task state in the active saved session.
- Spawn-capable roles remain persistent; leaf roles run one-off.

## Peer Communication

`hub list` projects a bounded roster from the existing relationship index. Persistent agents may send durable queued turns to any non-archived agent under the same canonical root; direct parent and descendant behavior remains unchanged. Peer authorization locks both ancestry paths before committing, while cross-root sends and sibling inspection, lifecycle, configuration, and relationship mutations remain denied.

Peer messages reuse the existing exact-once operation receipts and work queue, so retries and host restarts cannot duplicate delivery. The recipient receives hidden turn guidance containing the sender ID for optional replies, while the persisted message remains unchanged. Root-user context and root-user messages are removed from peer-authored turns so assistant coordination cannot establish user authority. One-off agents remain visible but non-messageable.

Common orchestration retries are intentionally tolerant at the tool boundary: a flat `todo init` defaults to a `Work` phase, task-targeted todo operations may carry redundant phase context, and cancelling an idle persistent child is an idempotent success. These cases remain strict about task identity, message contents, ancestry, and authority; tolerance removes model-shape noise without broadening capabilities.

## Agent Discovery

`afx agents` lists bundled, project, and user profiles as concise text; `afx agents --json` emits the same flat catalog for scripts. `/agents` opens a fullscreen native editor built on the settings surface. Project profiles override user profiles, bundled names cannot be shadowed or edited, and unknown-agent failures list the available names.

The editor cycles profiles with Tab and edits custom `model`, `effort`, `permission_mode`, `tools`, and `spawns` frontmatter fields in place. Writes replace the profile atomically, preserve its instruction body, and immediately reload the parsed profile. The same **Agents** category remains visible through `/settings`; effective spawn depth and the default 30-second `hub` wait timeout are informational.

## Role Policy

Agent profiles may declare `tools` and `spawns`. Tool restrictions are enforced three times: gateway advertisement, tool-call validation, and execution. Spawn names are enforced by `task`; the host independently enforces ancestry depth. afx defaults to depth two through `AFX_MAX_SPAWN_DEPTH`; `-1` disables the cap.

At the depth cap, child admission removes `task` and raw `subagent` from the effective tool set. Built-in `scout` and `reviewer` roles receive read-only tools and cannot spawn.

## Chat Presentation

Compact tool groups remain the primary transcript grammar: one summary followed by `├`/`└` action branches. Completed `task` calls specialize their branch into a bounded list of dispatched agent names and roles. Line-by-line display renders completed `todo` calls as total progress plus a bounded five-row window centered on active or blocked work, including phase names when multiple phases exist.

The settings are independent: **Tool display: compact/visual** persists through `visual_tool_blocks`, while **Display: line-by-line/fullscreen** persists through `fullscreen_display`. Compact and line-by-line remain the defaults. Visual tool display retains up to five physical command-output rows plus process status beneath command branches. Fullscreen display pins the composer to the terminal bottom from session start, removes `todo` updates from transcript groups, and projects only the latest incomplete todo state above the composer. The sticky projection updates in place and disappears when all tasks are completed or dropped.

## Plan Mode

`/plan` or a prompt beginning with `make a plan` enters a session-scoped interactive mode backed by the existing read-only tool projection. The queued prompt captures the mode, so later UI changes cannot widen an active planning turn. Runtime validation rejects any non-planning tool even if a provider emits an unadvertised call. When planning is complete, guidance requires one native `ask_user_question` review with exact **Approve and execute**, **Revise plan**, and **Cancel plan** choices. Approval is observed by the harness, restores the permission mode active before planning after the turn settles, and stages the execution continuation in the composer. `/plan off` exits without execution and `/plan status` reports state.

## Semantic Compaction

`/compact` and `/handoff [focus]` use an ordered native → semantic → mechanical fallback. Codex sessions first append `compaction_trigger` to a normal Responses stream with the `remote_compaction_v2` feature header, require a completed stream containing one compaction item, retain real user input messages, and persist the resulting opaque replacement-history JSON in the durable compacted-summary entry. Request projection replays that state only through the Codex-specific message field, followed by the latest verbatim turn; durable codec and resume paths preserve it across process restarts.

When native V2 is unavailable or fails, AFX makes one tools-disabled side request through the selected provider and commits its bounded intent, decisions, constraints, files, failures, todo state, verification, blockers, and next actions. Provider failure or empty output falls back again to the local mechanical compactor. All generated summaries remain non-authoritative context with root-user evidence marked incomplete.

## Turn Guidance

The exact standalone lowercase keyword `ultrathink` adds hidden careful-reasoning guidance and uses the selected model's last advertised reasoning effort for one turn.

The exact standalone lowercase keyword `orchestrate` adds a hidden completion-focused orchestration contract only when `task` is present in the effective tool projection. The contract keeps trivial work local, batches substantial independent slices, requires non-overlapping ownership and complete child acceptance criteria, uses `todo` and peer `hub` coordination, centralizes validation in the parent, and prevents yielding between unfinished phases. This follows OMP's high-leverage behavior while omitting its tool-template engine and persistent settings.

Detected magic-keyword occurrences in the prompt bar use the same theme-aware grayscale animation at the shared 50 ms frame phase without affecting layout or cursor geometry. An idle prompt independently arms that scheduler; no active model or tool shimmer is required. The queued prompt retains its captured session settings, so later turns return to the configured effort. Matching ignores code spans, fenced code, paths, symbols, comments, and markup to avoid accidental activation.

## Extensibility Direction

Skills, agent profiles, and MCP are current extension points, but they are not the complete long-term user-extensibility model. afx must support user-authored executable plugins or scripts without recompiling the binary. The host contract, language/runtime, packaging, lifecycle hooks, and trust boundary remain intentionally undecided until the concrete plugin workflows are specified; the design must not reduce extensibility to Markdown or require every extension to be a separate MCP product.

## Persistence

afx uses private state under `~/.afx/`. Project defaults come from `.afx.json`, project skills from `.afx/skills`, and project agent profiles from `.afx/agents`. Control records persist role policy and depth so resumed children retain the same authority.

## Invariants

- A child cannot gain tools or permission mode beyond captured host authority.
- Hidden tools remain blocked even when a provider emits an unadvertised call.
- Named spawn policy and depth are durable session state.
- The afx product target remains buildable and testable from the shared native Zig source tree.

Related: [terminology](../terminology.md), [practices](../practices.md).
