# Engineering Practices

- Keep afx behavior unchanged unless a change is intentionally shared. Product-specific behavior branches through `src/core/product.zig` and compile-time build options.
- Preserve the static Zig binary. Declarative profiles and skills are files; dynamic external capabilities use MCP rather than an embedded scripting runtime.
- Add built-in tools through `src/builtins/tools.zig` and enforce restrictions at advertisement, validation, and execution boundaries.
- Persist private session state through existing verified session capabilities instead of parallel storage systems.
- Prefer flat, boring tool contracts. Reliability degrades with nesting, heterogeneous argument shapes, and clever encodings; validation remains a harness responsibility.
- Research the existing owner module before editing. `src/main.zig` is composition, `src/core/` owns runtime contracts/state, `src/tools/` owns tool implementations, and `src/ui/` owns rendering.
- Verify permanent behavior with focused tests, a fresh native build, and a real binary interaction. Full CI remains the release gate.
- Update the lode when architecture, contracts, terminology, or durable practices change. Describe current behavior rather than completed-work history.

Related: [AFX architecture](afx/summary.md).
