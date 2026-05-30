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
- `f64` full instruction set: const, arithmetic (0xA0–0xA6), comparison (0x61–0x66), unary (0x99–0x9F)
- `call_indirect` with multiple table support and result-type checking
- Global variables (`global.get` / `global.set`); init expressions support `i64.const` and `f64.const`
- Full memory load/store instruction set:
  - Load: `i32.load`(0x28) through `i64.load32_u`(0x35), plus `f32.load`(0x2A) and `f64.load`(0x2B)
  - Store: `i32.store`(0x36) through `i64.store32`(0x3E), plus `f32.store`(0x38) and `f64.store`(0x39)
  - `memory.grow`(0x40)
- `i64.extend_i32_s` (one conversion instruction)
- `table.get` (0x25) / `table.set` (0x26): funcref table element read/write
  - `Value` enum has `.funcref(UInt32?)` case (nil = null reference, UInt32 = function index)
  - `ValueType` enum has `.funcref = 0x70` case
  - funcref locals default-initialized to nil (Wasm spec compliant)
  - Validator: bounds + type checking for table.get/table.set
- Linear memory with data segment initialization
- Host function import via `HostImport` enum (array-based, not `class HostFunctionTable`)
- Type-checking validator (`WasmValidator`) — macOS only
- Spectest runner (`SpectestTests.swift`) with f64 type support added

**Known issues / Embedded-phase TODOs:**
- `memory.size` (0x3F): throws `invalidInstruction` at parse time instead of `unimplemented` at runtime — needs fix
- 32-bit address calculation: `let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)` is unsafe on 32-bit targets where `Int` is 32 bits wide; needs `UInt64` intermediate on Embedded phase

**Not yet implemented:**
- Type conversion instructions (i32.trunc_f32_s, f64.promote_f32, etc.)
- `memory.size` (0x3F) — see known issue above
- Pico (Embedded) phase: fixed-size buffers, zero-copy Code section parsing

**Why:** Incremental implementation strategy — each instruction group is added when needed for Spectest coverage.

**How to apply:** When updating WASM_SPEC.md or PHASE4_INTERPRETER.md, reflect this boundary: f64 arithmetic is now implemented. The main remaining unimplemented group is type conversion instructions.

[[project-architecture]]
[[doc-cross-references]]
