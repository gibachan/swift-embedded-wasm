Read Documentations/OVERVIEW.md

# ⚠️ Critical Rules

## No Commits Without Permission

**Never run `git commit` without explicit prior approval from the user.**

- Do not auto-commit after completing a task
- Only commit when explicitly instructed with "commit this"
- Sub-agents (e.g., `embedded-wasm-runtime-implementer`) must not commit either
- At workflow completion, always ask "Shall I commit?" and wait for confirmation

# Rules for Claude

## Formatting
After modifying any Swift source files under `Sources/` or `Tests/`, always run `make format` to apply code formatting.

# About the Project

## Overview

This project incrementally implements a WebAssembly Runtime (Interpreter) for Raspberry Pi Pico using Embedded Swift.

Goals:

- Deepen understanding of Embedded Swift
- Understand the internals of a WebAssembly Runtime
- Learn interpreter implementation techniques
- Research Runtime design leveraging Swift's type safety
- Practice safe embedded design using actors
- Build a scriptable device that integrates with an iOS app

The project intentionally avoids rushing to "completion" and instead emphasizes:

> Implementing gradually while understanding how the Runtime works

## Target Audience Profile

- Proficient in Swift
- Beginner in embedded environments (Raspberry Pi Pico / RP2350, cross-compilation, memory constraints, etc.)
- Beginner in WebAssembly (binary format, stack machine, runtime structure, etc.)

## Support Policy

- For Embedded / Wasm topics, include explanations alongside implementation guidance
- Swift knowledge may be assumed (no need to explain basic Swift syntax or the type system)
- Include the background and reasoning behind decisions
- Learning is one of the goals, so prioritize building understanding

---

## VM Design Policy

When implementing the WASM VM, follow the design guidelines in **`Documentations/SWIFT_VM_DESIGN.md`**.
That document contains all implementation decision criteria: type design, error design, interpreter loop, generics policy, and comparisons with WasmKit.

## Embedded Swift Compliance Policy

The WASM VM implementation must be designed with **Embedded Swift build constraints in mind from the start**, even during the macOS development phase.
For detailed constraints, patterns, and rationale, see Sections 8–10 of `Documentations/SWIFT_VM_DESIGN.md`.

### Required Checks at Implementation Time

| Check | Not Allowed | Allowed |
|---|---|---|
| No reference types | `class GlobalStore { ... }` | `private var globals: [Value]` + `mutating` methods |
| No existentials | `any Protocol` | Generic constraints `<T: Protocol>` |
| No `String ==` comparisons | `name == "increment"` | `nameBytes.elementsEqual("increment".utf8)` |
| No untyped `throws` | `func f() throws` | `func f() throws(WasmError)` |

Note: `indirect case` previously used to store child instructions for `block` / `loop` / `if` instructions has been removed as part of the migration to flat bytecode (jump-offset instruction sequences) completed in Phase 1.5.

### Common Policy Across Implementation Phases

Even in the macOS phase, implement to match Embedded Swift constraints from the start.

- Do not create intermediate copies in hot paths (e.g., `Array(xxx.suffix(n))`)
- Do not use `String ==` comparisons (use `[UInt8]` byte comparisons instead)
- Always use typed throws: `throws(WasmError)`
- Mark locations where dynamic `Array<T>` allocation is structurally unavoidable (e.g., frame `locals`) with `// TODO: Embedded Phase 5`
- Validation should be omitted in Embedded builds and implemented only for non-Embedded (macOS) via `#if !hasFeature(Embedded)`

---

## Sub-Agent Workflow

This project uses four sub-agents defined in `.claude/agents/`. They follow a structured loop for implementing and reviewing WASM Runtime components.

### Agents

| Agent | Role |
|---|---|
| `embedded-wasm-runtime-implementer` | Implements WASM Runtime components with Embedded Swift constraints in mind |
| `wasm-embedded-researcher` | Researches reference implementations (wasm3, WasmKit) and Embedded Swift constraints when needed during implementation |
| `wasm-runtime-reviewer` | Reviews implemented code for correctness, Embedded Swift compatibility, and design consistency |
| `wasm-runtime-tester` | Verifies implementation changes by running the three test perspectives: `swift test`, `make compile`, and BLE example build |
| `docs-sync-agent` | Updates documentation to reflect implementation changes after a task is complete |

### Test Perspectives

`wasm-runtime-tester` performs testing from the following three perspectives:

1. **`swift test` (macOS unit tests)** — Verifies that logic behaves as specified
2. **`make compile` (Embedded Swift compilation check)** — Verifies that the code compiles under Embedded Swift constraints (generates `.o` files; Pico SDK not required)
3. **BLE example `make build` (Embedded Swift link check)** — Verifies that compilation and linking both succeed (`Examples/RaspberryPiPicoW-BLE/Embedded/`; Pico SDK required)

### Workflow

1. **Implement** — Launch `embedded-wasm-runtime-implementer` for the implementation task. If technical research is needed mid-implementation, it delegates to `wasm-embedded-researcher`.
2. **Test** — After implementation, launch `wasm-runtime-tester` to verify the changes pass all three test perspectives.
3. **Review** — Launch `wasm-runtime-reviewer` to review the changes.
4. **Revise** — If the review identifies valid issues, launch `embedded-wasm-runtime-implementer` to address them, then re-run `wasm-runtime-tester` and `wasm-runtime-reviewer`. Repeat until no further changes are needed.
5. **Sync docs** — Once implementation is stable, launch `docs-sync-agent` to update affected documentation as needed.

---

## Reference Resources

### wasm3 (local)

The wasm3 source code is available as a Git Submodule at `ThirdParty/wasm3/`.
When referencing the WebAssembly Runtime implementation, use this local copy without network access.

Key files:

| File | Contents |
|---|---|
| `ThirdParty/wasm3/source/m3_core.h` | Type definitions and core data structures |
| `ThirdParty/wasm3/source/m3_env.h` | VM environment and module structure |
| `ThirdParty/wasm3/source/m3_exec.c` | Interpreter main loop |
| `ThirdParty/wasm3/source/m3_parse.c` | Binary parser |
| `ThirdParty/wasm3/source/m3_compile.c` | Compilation and intermediate representation |
