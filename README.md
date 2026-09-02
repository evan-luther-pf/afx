<p align="center">
  <img src="docs/hero.png" alt="afx" width="960">
</p>

<p align="center">
  <strong>A fast coding agent for your terminal.</strong><br>
  <a href="https://evan-luther-pf.github.io/afx/">Documentation</a>
</p>

<p align="center">
  <a href="https://github.com/evan-luther-pf/afx/releases/latest"><img src="https://img.shields.io/github/v/release/evan-luther-pf/afx?style=flat&colorA=222222&colorB=58A6FF" alt="Latest release"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/changelog-read-E05735?style=flat&colorA=222222" alt="Changelog"></a>
  <a href="https://github.com/evan-luther-pf/afx/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/evan-luther-pf/afx/ci.yml?style=flat&colorA=222222&colorB=3FB950" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/evan-luther-pf/afx?style=flat&colorA=222222&colorB=58A6FF" alt="License"></a>
  <a href="https://ziglang.org"><img src="https://img.shields.io/badge/Zig-F7A41D?style=flat&colorA=222222&logo=zig&logoColor=white" alt="Zig"></a>
</p>

afx is a local coding agent that lives in your terminal. It can read and change a repository, run commands, search the web, use your language server and debugger, remember sessions, and split larger jobs across focused agents.

It is designed to feel direct: one native binary, a clear terminal interface, real permission controls, and no framework between you and the work.

> [!NOTE]
> afx is experimental. Review changes before shipping them.

## Install

Download the archive for your platform from the [latest release](https://github.com/evan-luther-pf/afx/releases/latest), extract it, and place `afx` somewhere on your `PATH`.

```sh
mkdir -p ~/.local/bin
mv afx ~/.local/bin/afx
afx
```

Build from source with Zig 0.16 or newer:

```sh
git clone https://github.com/evan-luther-pf/afx.git
cd afx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/afx
```

macOS and Linux builds are published for Apple Silicon, Intel, and ARM64 where supported.

## Start

Open a repository and run:

```sh
cd your-project
afx
```

Then ask for the outcome you want:

```text
Explain how authentication works.
Fix the failing tests and verify the result.
Search the web for the current API behavior, then update this integration.
Make a plan for this refactor.
```

Use `/model` to choose a model, `/providers` to manage accounts and keys, `/sessions` to resume work, and `/help` to see every command.

## What it does

- Reads, searches, edits, and writes local files
- Runs commands and keeps long-running terminal sessions alive
- Shows the agent's current intent in the live activity bar
- Uses LSP for definitions, references, diagnostics, and safe renames
- Drives native debuggers through DAP
- Searches and reads the public web with cited sources
- Connects to MCP servers and installed skills
- Saves sessions, branches, plans, checkpoints, and todo state
- Runs independent work in parallel through focused task agents
- Supports Codex, Gemini, Anthropic, Grok, AI Gateway, and compatible providers
- Plays audio chimes, bells, and emits OSC desktop notifications on turn completion and approvals
- Configurable status line with toggles for context, session, workspace, cost, and git segments
- Copies model-facing context and request payloads with /dump for debugging
- Duplicates sessions into new independent copies with /fork
- Exports sessions to self-contained HTML files with /export [path]

## Hashline editing

The default `edit` tool binds every patch to the exact file snapshot afx displayed. Reads and searches return headers such as `[src/main.zig#A1B2]` with stable original line numbers. An edit with a stale tag, an unseen anchor, an overlapping range, or a changed target is rejected before disk mutation.

Hashline patches can replace tight ranges, target complete syntax blocks, insert at line gaps, move or remove files, and move captured text through persistent named registers. Multi-file patches are prepared together, preserve line endings and UTF-8 BOMs, and recover safely when unrelated lines changed after the read.


## Context management: checkpoint and rewind

afx provides `checkpoint` and `rewind` tools for managing model-facing context during exploratory investigations:

- `checkpoint`: Mark the current position in the session tree as an active checkpoint before an investigation.
- `rewind`: Discard exploratory conversation turns after the checkpoint at turn end, replacing them with a concise findings report.

The full exploratory history remains preserved on disk and visible in the full transcript (`Ctrl+O`) and session tree views.
## A terminal interface that stays out of the way

Common reads remain compact. Commands, edits, searches, tasks, and debugger work expand into bounded OMP-style cards. Search cards show the query, answer, sources, model, and token usage without hiding the evidence.

afx keeps ordinary work in terminal scrollback. Full-screen views are reserved for interactions that genuinely need them, such as permission review, menus, and agent management.

## Inline images

In terminals that support graphics (iTerm2, WezTerm, Ghostty, and kitty), image attachments render inline while their row is on screen; scrollback keeps the textual `[Image #N]` badge. Inside tmux or unsupported terminals, badges are always used. Toggle with the `Images` setting in `/settings`. The full-transcript review screen uses badges.

## Custom themes

afx auto-detects dark and light terminal backgrounds and supports user-defined color themes. Themes live at `~/.afx/themes/<name>.json`:

```json
{
  "name": "magenta",
  "colors": {
    "accent": "#FF00FF",
    "border": "240",
    "text": "#FFFFFF",
    "muted": "245",
    "dim": "240",
    "error": "#FF5555",
    "warning": "#FFB86C",
    "success": "#50FA7B",
    "diff_added_marker": "#50FA7B",
    "diff_removed_marker": "#FF5555"
  }
}
```

Color values accept 24-bit hex strings (`"#RRGGBB"`), 256-color palette indices (`0`–`255`), or `""` for the terminal default. Missing tokens fall back to the built-in dark or light palette. Select a theme in `/settings` or override it using the `FX_THEME` environment variable.

## Debugging and context inspection

Run `/dump` to copy the full model-facing context (system prompt, model configuration, tool definitions, and message history) to the clipboard and write a raw JSON request sidecar to temporary storage; note that the sidecar file can contain sensitive information or secrets, so protect or remove it accordingly.

## Keyboard shortcuts

- `Ctrl+O`: Open the full transcript review screen. Switch between Review and Full detail with `←`/`→`, scroll with `PgUp`/`PgDn` or mouse wheel, search with `/` (`n`/`N` jump to next/previous match), and press `Esc` to close search or exit.
- `Ctrl+R`: Interactive prompt history search in the composer. Filter past entries incrementally, navigate matches with `Up`/`Down` or `Ctrl+R`, press `Enter` to recall into the composer without submitting, or press `Esc` to restore the draft.
- `Alt+E`: Open the current composer draft in `$VISUAL` or `$EDITOR`. On editor exit, replaces the draft with the edited contents.
- `Ctrl+X`: Open the subagent manager to view, monitor, pause, or resume parallel background agents.
- `Ctrl+G`: Reload into a downloaded update when ready.

## Subagent manager

Press `Ctrl+X` to open the subagent manager and inspect live and archived parallel agents.

- **Roster overview**: Roster rows display live status alongside compact resource metrics (cumulative token count, estimated USD spend, and elapsed time since last activity). On narrow terminal widths, trailing metrics truncate gracefully without line wrapping. Missing metrics render with em-dash (`—`) placeholders.
- **Aggregate header**: The header aggregates cumulative token usage and estimated spend across all active child agents.
- **Detailed metrics**: Inspecting an individual child reveals its full resource block, including cumulative input and output tokens, estimated cost in USD, total request and turn counts, tool-call count, model context-window fill percentage, and last activity timestamp.
Run `/hotkeys` to see every active shortcut and its binding status. Customize keybindings in `~/.afx/keybindings.json`:

```json
{
  "composer.external_editor": "alt+e",
  "composer.history_search": "ctrl+r",
  "app.subagents": ["ctrl+x", "alt+x"]
}
```

Assigning an empty array `[]` disables a shortcut.

## Magic keywords

afx supports magic keywords in prompt text. Including a keyword injects a hidden, per-turn instruction into the model request while preserving the raw keyword text in the visible user message and session history. Magic keywords are always enabled in v1 without a separate settings toggle, and recognized keywords render highlighted in bold accent color in the composer.

### Supported keywords

- `ultrathink`: Injects a hidden turn instruction directing the model to reason carefully step-by-step through constraints, failure modes, and verification before acting.
- `orchestrate`: Injects a hidden turn instruction directing the model to map the full task scope, decompose independent work into parallel subagents via `task`, and verify each phase before advancing.

### Matching rules

- Exact lowercase spelling only (`ultrathink`, `orchestrate`). Uppercase or title-case variations are ignored.
- Must appear as a standalone word. Sentence punctuation and quotes adjacent to the word (such as commas, quotes, exclamation marks, or parentheses) are allowed.
- Adjacency to letters, digits, underscores, slashes, backslashes, hyphens, or dots does not match (for example, `orchestrated`, `orchestrate.ts`, `foo/ultrathink`, and `ultrathink-mode` are not treated as keywords).
- Occurrences inside backtick code spans (`` `ultrathink` ``) and fenced code blocks are ignored.
- Multiple distinct keywords in the same prompt inject their respective notices once. Repeated occurrences of the same keyword inject the notice once.

### Examples

- `ultrathink before refactoring the auth session tokens`: highlights `ultrathink` and injects careful step-by-step reasoning guidance for the turn.
- `orchestrate the full migration across core packages`: highlights `orchestrate` and injects parallel decomposition guidance for the turn.

## Permissions

afx starts in `auto` mode. Routine development work can proceed, while unresolved sensitive actions receive a bounded review. Use `ask` when you want approval prompts for sensitive actions or `yolo` only in an environment you already trust.

Project settings live in `.afx.json`. Private settings, credentials, skills, agents, and saved sessions live under `~/.afx/`.


## Chat bridge

afx includes a headless chat bridge daemon that connects chat platforms (Slack, Telegram, iMessage) to local AFX sessions.

### Commands

```sh
afx bridge start                        # start in foreground
afx bridge start --daemon               # start daemon in background
afx bridge start --connector fake       # start with deterministic fake connector
afx bridge stop                         # stop running bridge daemon
afx bridge status                       # check daemon status
afx bridge status --json                # structured status output
afx bridge pair <connector>             # generate pairing code for authorization
```

### In-chat slash commands

When chatting with the bridge bot, standard control commands are supported:

- `/new` — start a fresh session
- `/resume <id>` — resume a saved session by id
- `/status` — display current model, mode, and session info
- `/model <id> [effort]` — change model and reasoning effort
- `/permissions <ask|auto>` — set permission mode
- `/cancel` — cancel the currently running turn
- `/usage` — show token usage
- `/help` — list available commands

### Configuration

Bridge settings live in `~/.afx/bridge.json` (mode 0600):

```json
{
  "workspace": "/path/to/project",
  "permission_mode": "ask",
  "max_concurrent_sessions": 4,
  "connectors": {
    "slack": {
      "app_token_env": "SLACK_APP_TOKEN",
      "bot_token_env": "SLACK_BOT_TOKEN",
      "allow_users": ["U12345678"]
    }
  }
}
```
## Updates

afx checks [GitHub Releases](https://github.com/evan-luther-pf/afx/releases) for new versions. When an update is ready, press `Ctrl+G` to reload into it.

```sh
afx upgrade
afx upgrade --channel stable
afx upgrade --channel dev
```

Stable updates follow versioned GitHub releases. The optional development channel follows the moving `dev` prerelease.

## Documentation

Read the [plain HTML documentation](https://evan-luther-pf.github.io/afx/) for setup, providers, permissions, sessions, tools, agents, updates, and project configuration.

Contributor and implementation details remain in [CONTRIBUTING.md](CONTRIBUTING.md).

## Lineage

afx takes interface inspiration from [Pi](https://github.com/badlogic/pi-mono) and [Oh My Pi](https://github.com/can1357/oh-my-pi). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for included notices.

## License

[Apache-2.0](LICENSE)
