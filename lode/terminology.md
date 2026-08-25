# Terminology

- **afx** - The upstream native Zig coding-agent runtime and CLI.
- **afx** - The terminal-first orchestration coding-agent harness maintained in this repository.
- **agent profile** - A Markdown file under `.afx/agents/` or `~/.afx/agents/` defining a named role, instructions, model preferences, tool allowlist, and spawn policy.
- **task** - The model-facing tool that creates role-backed child sessions for independent work.
- **hub** - The model-facing tool for inspecting, waiting on, messaging, or cancelling an explicit child ID.
- **todo** - Session-persistent phased work state stored outside conversation history.
- **tool allowlist** - The role policy that filters tool advertisement, validation, and execution.
- **spawn allowlist** - The role policy controlling which named profiles a child may create through `task`.
- **spawn depth** - The child-creation depth enforced by the host; afx defaults to two levels.
- **lode** - Repository-owned Markdown describing current system knowledge for future human and agent sessions.
