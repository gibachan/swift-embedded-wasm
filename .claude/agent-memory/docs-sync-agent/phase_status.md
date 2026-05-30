---
name: phase-status
description: Current implementation milestone status for Phase 4 (interpreter) — what is implemented, what is pending
metadata:
  type: project
---

As of 2026-05-30, the project is in Phase 4 (macOS development phase).

**Completed (Phase 1-4):**
- Flat bytecode migration (フェーズ 1.5): `block`/`loop`/`if` use jump offsets, no `indirect case`, no heap
- Full parser: Type / Import / Function / Table / Memory / Global / Export / Element / Code / Data sections
- `i32` full instruction set (arithmetic, comparison, bitwise, unary)
- `i64` full instruction set
- `f32` full instruction set (const, arithmetic, comparison, unary)
- `f64.const` — `Value.f64(Double)` representation; f64 arithmetic instructions NOT yet implemented
- `call_indirect` with multiple table support and result-type checking
- Global variables (`global.get` / `global.set`); init expressions support `i64.const` and `f64.const`
- `memory.grow`
- `i64.extend_i32_s` (one conversion instruction)
- Linear memory with data segment initialization
- Host function import via `HostImport` enum (array-based, not `class HostFunctionTable`)
- Type-checking validator (`WasmValidator`) — macOS only
- Spectest runner (`SpectestTests.swift`) with f64 type support added

**Not yet implemented:**
- `f64` arithmetic instructions (f64.add, f64.sub, f64.mul, f64.div, etc.)
- Type conversion instructions (i32.trunc_f32_s, f64.promote_f32, etc.)
- `memory.size`
- Pico (Embedded) phase: fixed-size buffers, zero-copy Code section parsing

**Why:** Incremental implementation strategy — each instruction group is added when needed for Spectest coverage.

**How to apply:** When updating WASM_SPEC.md or PHASE4_INTERPRETER.md, reflect this boundary: f32 arithmetic is implemented, f64 arithmetic is not.

[[project-architecture]]
[[doc-cross-references]]
