# OMP High-Leverage Review for AFX

Implementation status: interactive plan mode, Codex-native V2 `/compact`, SnapCompact, focused `/handoff`, native LSP and DAP tools, checkpoint/rewind, structured/isolated subagents, the lightweight rulebook, replay-safe Gateway credential rotation, and durable session branches are implemented. Compaction order is Codex-native V2, local SnapCompact for vision models, semantic handoff, then mechanical fallback.

Reviewed against OMP 17.4.2, representative OMP source and implementation docs, current Pi documentation, and the AFX source tree.

## Priority order

1. **Interactive plan mode** — implemented: enforce read-only planning, then require an explicit transition into execution.
2. **Semantic compaction, SnapCompact, and `/handoff`** — implemented: retain Codex-native V2 first, then locally archive discarded history into durable bitmap frames for vision models, with semantic and mechanical fallbacks.
3. **Native LSP tool** — implemented: definitions, references, diagnostics, and safe rename using project language servers.
4. **Checkpoint/rewind** — implemented: one durable active boundary forces auto-continuation until `rewind`, then collapses exploratory conversation into a required retained findings report without reverting files.
5. **Structured and isolated subagents** — implemented: schema-validated one-off results and Git-worktree isolation with dirty-baseline capture, durable patches, stale checks, explicit application, and unconditional cleanup.
6. **Rulebook with lightweight enforcement** — implemented: project/user `.afx/rules/*.md`, descriptions and globs, always-apply injection, `rule://` reads, and once-per-session post-edit reminders.
7. **Credential fallback routing** — implemented: replay-safe quota/auth failures rotate configured Gateway credential sources with session affinity, per-source cooldown, durable recovery-route identity, and preferred-route restoration.
8. **Session tree** — implemented: searchable interactive user/assistant rows, durable parent-linked leaves and labels, cross-leaf selection, prompt prefilling, ask-turn reopening, optional generated branch summaries, append-only navigation, and branch-local todo/checkpoint restoration.
9. **DAP/debugger** — implemented: one persistent native DAP root session, built-in and JSON-configured adapters, lifecycle/events, breakpoints, execution control, stack/variable inspection, evaluation, disassembly, memory, modules, raw requests, output, and cleanup.
10. **Project memory consolidation** — skipped while OMP keeps memory disabled by default.
11. **Lean reviewer/advisor** — reuse AFX's reviewer agent at phase boundaries instead of porting OMP's continuous watchdog runtime.

## Why these differ from Pi

Pi now includes session trees and model-generated compaction, so those are not OMP-only. OMP extends the Pi baseline with integrated planning enforcement, LSP write-through, checkpoint/rewind tools, task orchestration and isolation, runtime rule injection, advisor models, autonomous memory, and multi-credential recovery. Pi deliberately favors a small core plus TypeScript extensions and does not provide a built-in execution permission boundary; AFX already has a native permission engine and can integrate the highest-value mechanisms directly.

## Minimal AFX implementation paths

### Interactive plan mode

Reuse the existing mode registry, ACP read-only plan policy, permission engine, `ask` UI, and model/profile switching. Add interactive `/plan`, expose only inspection tools plus `todo`, present the plan for approval, then restore execution tools. Avoid a second proposal-device framework.

### Semantic compaction and SnapCompact

Codex-native V2 remains first. When it is unavailable, SnapCompact serializes discarded history locally, bounds tool noise, renders provider-shaped PNG frames through the bundled X.org 8x13 font, persists the source and frames in the compaction entry, and reattaches them during context reconstruction. Vision-ineligible models and directed `/handoff [focus]` requests use semantic compaction; mechanical compaction remains the terminal fallback.

### LSP

Implemented at OMP architectural and action parity: persistent workspace/server clients, background framed readers, concurrent requests, push/pull diagnostics, document synchronization, project readiness, reference retries, failure backoff, idle reaping, graceful restart/shutdown, root-marker and project-local discovery, user/project JSON configuration, multi-server routing, optional running `lspmux` use, workspace diagnostics and symbols, semantic `rename_file`, code-action resolve/commands, contextual locations, ordered resource operations, server `workspace/applyEdit`, atomic rollback, `/undo`, and ordinary file-tool write-through. AFX intentionally accepts JSON configuration rather than OMP's additional YAML syntax; the server configuration capabilities are otherwise equivalent.

### Checkpoint/rewind

Persist one checkpoint boundary. Require a non-empty rewind report and use durable state replacement to keep history through the checkpoint plus one retained report. The canonical event log preserves abandoned frames without requiring a session DAG immediately.

### Structured and isolated agents

Implemented on top of AFX’s existing durable child state machine rather than adding a second orchestrator. `task` persists caller schemas and strict/permissive policy in the child configuration, forces contracted work to one-off mode, validates final JSON with the existing native JSON Schema engine, and delivers structured validation metadata. `isolated: true` creates a detached Git worktree containing committed and in-flight parent state, stores a baseline digest and manifest, captures only the child delta, retains a patch artifact, applies only after an unchanged-baseline check and explicit approved `apply: true`, routes the child session to the worktree, and cleans the worktree during normal completion, failure, cancellation, and restart reconciliation.

### Rulebook

Implemented without OMP’s heavier TTSR runtime. Project `.afx/rules/*.md` overrides same-name user `~/.afx/rules/*.md`; bounded no-follow discovery parses `description`, `globs`, and `always_apply`. Always rules enter static system context, optional rules are advertised by name/description/globs, the read-only `rule` tool resolves `rule://<name>`, and successful edit/write results append matching reminders once per session. AFX intentionally ships no opinionated default rule set and performs no regex/AST stream interruption.

### Recovery routing

Implemented without OMP’s auth broker or multi-account database. Gateway sources keep session affinity while healthy; replay-safe quota/auth failures block only the failed source, rotate before waiting, persist the active source in recovery checkpoints, and restore the preferred source after cooldown. Transient rate limits remain ordinary retries.

### Session tree

Implemented as a bounded snapshot DAG that preserves OMP’s behavior while reusing AFX’s session picker and state-replacement machinery. Each leaf stores a parent ID, fork turn, label, canonical digest, durable snapshot, and branch-local todo/checkpoint sidecars; active-leaf updates are crash-reconciled against the canonical session. `/tree` provides searchable user/assistant rows, user-prompt prefilling, assistant-point navigation, cross-leaf branching, ask-turn reopening, labels, direct branch/switch commands, and optional generated summaries of abandoned suffixes. Navigation resets provider recovery, credential routing, permission grants, and subagent delivery without touching files.

### Memory

Use one project-scoped Markdown memory and `/memory consolidate`; inject a small bounded summary next session. No embeddings, graph store, remote backend, or background pipeline initially.

### Advisor

Run one opt-in read-only reviewer at todo phase completion, accept at most one concrete concern, render it as a card, and require an explicit continuation. No continuous transcript follower or automatic resume initially.

### DAP

Implemented after LSP using the same native process and bounded `Content-Length` framing conventions, with DAP-specific request/response/event handling. AFX keeps one root session, caches stop/thread/frame state and breakpoints, gates advanced requests through adapter responses, and tears down the process tree explicitly. Built-ins cover lldb-dap, debugpy, dlv, gdb, and rdbg; project/user JSON can override argv. OMP’s unrelated profiling, report-bundle, raw-SSE, and system-diagnostics menu remains out of scope.

## Already present in AFX; do not duplicate

- Durable `task`, `hub`, agent profiles, and child sessions.
- Persistent `todo`.
- Scoped nested `AGENTS.md` delivery.
- MCP and skills.
- Approval modes and permission enforcement.
- Large tool-result handles and bounded previews.
- Background process lifecycle and cancellation.
- Replay-safe provider recovery.
- Prompt queueing and advanced terminal rendering.

## Ponytail cuts

Do not port OMP's full extension marketplace, full TTSR stream interruption, persistent multi-language eval kernels, multiple memory backends, auth broker/gateway, nine isolation backends, or encrypted session sharing until a concrete AFX workflow requires them.

## Sources

- https://github.com/can1357/oh-my-pi
- https://github.com/can1357/oh-my-pi/blob/main/docs/advisor-watchdog.md
- https://github.com/can1357/oh-my-pi/blob/main/docs/tree.md
- https://github.com/can1357/oh-my-pi/blob/main/docs/compaction.md
- https://github.com/can1357/oh-my-pi/tree/main/packages/snapcompact
- https://stencil.so/blog/snapcompact
- https://github.com/can1357/oh-my-pi/blob/main/docs/tools/checkpoint.md
- https://github.com/can1357/oh-my-pi/blob/main/docs/rulebook-matching-pipeline.md
- https://github.com/can1357/oh-my-pi/tree/main/packages/coding-agent/src/lsp
- https://github.com/can1357/oh-my-pi/blob/main/docs/tools/debug.md
- https://pi.dev/docs/latest/sessions
- https://pi.dev/docs/latest/compaction
- https://pi.dev/docs/latest/security
- https://pi.dev/docs/latest/extensions
