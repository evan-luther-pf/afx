# GUI Command Control Plane

## Goal

Make the afx GUI treat product slash commands as typed controls instead of chat messages while preserving ACP prompt-command compatibility for dynamic agent commands.

## Current State

- afx advertises 41 visible slash commands across 11 categories.
- The GUI command picker inserts command text into the composer.
- The GUI handles `/new`, `/clear`, and `/reset` locally.
- ACP handles only `/help`, `/status`, `/permissions`, `/clear`, and `/reset` locally.
- Remaining advertised afx commands reach the language model as ordinary prompt text.
- ACP command discovery currently depends on an active session, but the GUI intentionally starts without creating one.

## Decisions

### Execution classes

Every advertised command has one explicit execution class:

- `control`: open or mutate a native GUI surface.
- `structured`: execute in afx core and return a typed result.
- `prompt`: preserve ACP's standard regular-prompt behavior.

Unknown commands default to `prompt`. Built-in afx commands never implicitly fall through to the model.

### Presentation classes

Commands declare one presentation:

- `model_tab`
- `session_tabs`
- `provider_panel`
- `permissions_panel`
- `help_panel`
- `runtime_panel`
- `form`
- `immediate`
- `transcript`

The GUI remains responsible for visual presentation. afx core remains authoritative for command semantics, validation, persistence, authentication, and security policy.

### Protocol

The initialized ACP response advertises commands before session creation. Each command includes standard ACP fields plus afx metadata:

```json
{
  "name": "providers",
  "description": "choose a model provider and manage its access",
  "category": "Account",
  "_meta": {
    "afx": {
      "execution": "control",
      "presentation": "provider_panel",
      "action": "providers.manage",
      "result": "panel",
      "danger": "none"
    }
  }
}
```

Commands with structured arguments use an ACP-compatible custom input type beginning with `_`.

A namespaced `afx/command/execute` request accepts a command name and structured arguments. It returns one of:

- `state_change`
- `report`
- `clipboard`
- `external_url`
- `transcript`
- `unsupported`

Dynamic prompt commands continue through `session/prompt`.

## Native Surfaces

### Existing persistent controls

- `/model` and `/models` open the bottom model tab.
- `/resume` and `/new` focus the left session tabs or startup state.

### Provider panel

`/providers`, `/login`, and `/logout` open one provider panel. Provider rows expose connection state and actions. OAuth uses the system browser, never an embedded web view. The panel displays waiting, success, failure, retry, and cancel states. Authentication does not create a session.

### Permissions panel

`/permissions` opens native mode controls. `ask` and `auto` are direct choices. `yolo` requires explicit confirmation. `/allowlist` opens the structured rule editor from the same surface.

### Help and runtime panels

- `/help` opens the categorized command center.
- `/status`, `/stats`, `/usage`, `/credits`, and `/version` render structured runtime snapshots.

### Generic forms

Argument-bearing commands without a dedicated surface open a compact generated form. Destructive actions require confirmation. Results render as a toast, panel, or transcript event according to metadata.

## GUI Routing

Picker selection does not insert text by default.

1. `control` opens the declared native surface.
2. `structured` executes immediately or opens its form.
3. `prompt` inserts or submits command text through `session/prompt`.

Typed complete commands use the same router. Product command execution never creates a user message bubble. Transcript-producing workflows may append assistant or system content.

## Implementation Order

1. Advertise the command catalog during ACP initialization.
2. Add execution and presentation metadata to the authoritative slash registry.
3. Add `afx/command/execute` with structured results for core commands.
4. Route GUI picker and typed slash submissions through one command router.
5. Connect existing model and session controls.
6. Add provider, permission, help, and runtime panels.
7. Add generated forms and explicit prompt fallback.
8. Verify startup, OAuth launch, model/session persistence, permission changes, command reports, dynamic prompt commands, and absence of command user bubbles.

## Acceptance

- The command picker is populated before a session exists.
- No built-in afx command is sent to the language model.
- Dynamic prompt commands remain ACP-compatible.
- Model and session commands use the existing physical tabs.
- Provider login opens the system browser and reports state in the provider panel.
- Permission changes are enforced by afx core.
- Read-only reports do not create chat turns.
- GUI restart creates no session.
- First ordinary prompt still creates exactly one session.
