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

Direct actions include session rename, Fast mode, local context compaction, session reset, copy, feedback, and quit. Rename persists through the session display sidecar and index. Fast mode validates the active model capability, updates active state, restores through ACP config options, and reports compact transient feedback.

Background, agents, credits, and workspace commands bridge to the built afx binary and render their captured output in the main command surface. Unsupported workflows remain registered for terminal use but are not advertised to the GUI.

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

## Provider authentication

Provider management launches `afx login <provider>` through the same built binary. afx owns browser launch, OAuth callback handling, credential persistence, and provider activation. The GUI displays waiting, success, failure, and cancellation state. Closing the surface during an active login terminates the child process.

OAuth-capable providers are Vercel AI Gateway, Codex, Grok, Google Antigravity, and Google Gemini CLI. Other providers remain selectable when their credentials are configured through supported profile mechanisms.

## Session invariants

- Opening a command surface never creates a session.
- Read-only reports never append user or assistant messages.
- The first ordinary prompt in startup state creates exactly one session.
- Model changes made before the first prompt remain staged until session creation.
- Loading a saved session restores its persisted provider and model.
