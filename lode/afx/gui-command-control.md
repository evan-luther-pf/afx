# GUI Command Control

## Contract

The afx GUI uses slash syntax as a command launcher, not as an implicit chat transport.

The authoritative slash registry classifies each built-in command by:

- execution: `control`, `structured`, or `prompt`
- GUI presentation
- action identifier
- result presentation
- confirmation requirement

ACP initialization includes the complete GUI-supported command catalog so command discovery works before a session exists. Active sessions may replace it through the standard `available_commands_update` notification.

Unknown or externally supplied commands default to ACP prompt behavior. Built-in afx commands are never implicitly forwarded to the language model.

## Structured execution

`afx/command/execute` accepts a command name and structured string arguments. Current typed results include:

- `state_change`
- `report`
- `unsupported`

Status, statistics, usage, version, and permission mode execute without creating a conversation turn. Permission mutations update both the ACP server baseline and the active session policy.

## Availability

The GUI advertises only commands with working native, structured ACP, or top-level CLI execution. Terminal-only and not-yet-ported workflows are omitted rather than exposed as broken controls.

Direct actions include session rename, Fast mode, local context compaction, semantic handoff fallback, plan mode, recovery continuation, session reset, copy, feedback, and quit. Rename persists through the session display sidecar and index. Fast mode validates the active model capability, updates active state, restores through ACP config options, and reports compact transient feedback.

Background and child-agent activity use the typed `activity` command result. The GUI polls while its Tasks surface is open and renders parent depth, state, elapsed time, background logs, agent messaging, and cancellation. `/agents` and no-argument `/background` both open this native surface; neither shells out to another afx process.

`/tree` reads the active session's durable branch index into a native hierarchy. `/plan` changes the active ACP mode and restores the preceding mode when disabled. `/continue` sends the ACP recovery metadata on an empty prompt. `/handoff` uses the ACP session compaction path.

MCP and skill inventory use the typed `extensions` result. MCP add, remove, enable, and disable mutate the profile configuration through afx's canonical MCP config implementation. Managed skills install and remove through the canonical skill command provider, followed by in-process discovery refresh. Skill enablement is scoped to the ACP process and filters both parent and child prompt catalogs immediately without mutating external skill directories.

## GUI routing

Both picker selection and typed slash submission use the same router.

- Model commands open the native model surface or select an explicit model.
- Session commands use the left session tabs and startup state.
- Provider commands open provider management.
- Permission commands open native mode controls with an in-panel Yolo confirmation.
- Help and runtime reports replace the main panel content.
- Argument-bearing long-tail commands open a generated form.
- Explicit prompt commands retain ACP prompt transport.

Command surfaces fade into and occupy the existing glass window's full content area. They do not use separate windows, centered cards, or nested glass surfaces. The close control stays in the window's upper-right corner; Escape restores conversation content.

Permission requests remain inline above the composer so the conversation and exact tool target stay visible. The GUI returns the opaque ACP option ID unchanged for allow once, allow for session, or deny; the server performs live revalidation before execution.

Changed files are tracked from committed ACP diff updates. The Changes surface renders one diff per path and exposes Keep, path-specific Revert, and Undo Last through the active session's `ChangeTracker`.

## Provider authentication

Provider management launches `afx login <provider>` through the same built binary. afx owns browser launch, OAuth callback handling, credential persistence, and provider activation. The GUI displays waiting, success, failure, and cancellation state. Closing the surface during an active login terminates the child process.

OAuth-capable providers are Vercel AI Gateway, Codex, Grok, Google Antigravity, and Google Gemini CLI. Other providers remain selectable when their credentials are configured through supported profile mechanisms.

## Session invariants

- Opening a command surface never creates a session.
- Read-only reports never append user or assistant messages.
- The first ordinary prompt in startup state creates exactly one session.
- Model changes made before the first prompt remain staged until session creation.
- Loading a saved session restores its persisted provider and model.
