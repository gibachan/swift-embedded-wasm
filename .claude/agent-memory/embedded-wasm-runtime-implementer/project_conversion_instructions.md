---
name: conversion-instructions
description: Implementation details and Wasm spec boundary conditions for numeric conversion instructions (trunc, convert, reinterpret, wrap, demote, promote, saturating trunc)
metadata:
  type: project
---

Implemented all 24 standard conversion opcodes (0xA7–0xBF) and 8 saturating trunc opcodes (0xFC 0x00–0x07). Changes span 4 files: WasmError.swift, WasmModule.swift, WasmParser.swift, WasmInterpreter.swift, and WasmValidator.swift.

**Why:** spectest `conversions` was `pass=8 skip=611` before; after implementation it is `pass=619 skip=0 fail=0`.

## Key Wasm Spec Boundary Conditions (non-obvious)

### Unsigned trunc lower bound
- Trap condition is NOT `a < 0.0` — it is `a <= -1.0`.
- Values in `(-1, 0)` truncate toward zero to 0, which IS valid as u32/u64.
- Correct guard: `a > -1.0` (strict).
- Swift safety: `UInt32(a)` / `UInt64(a)` with `a` in `(-1, 0)` will crash at runtime. Must use `a < 0.0 ? 0 : UInt32(a)`.

### Signed i32 trunc from f64 lower bound
- `a >= -2147483648.0` is WRONG: f64 can represent values like `-2147483648.9` which truncates toward zero to `-2147483648` (INT32_MIN) — valid.
- Correct guard: `a > -2147483649.0`.
- f32 signed i32 trunc does NOT have this issue because `-2147483648.0` is the exact representable f32 boundary.

### Signed i64 trunc bounds
- `-9223372036854775808.0` (= -2^63) IS exactly representable in both f32 and f64 and equals INT64_MIN → valid.
- Guard `a >= -9223372036854775808.0 && a < 9223372036854775808.0` works for both f32 and f64.

### Saturating trunc unsigned: NaN / negative handling
- Saturating: values in `(-1, 0)` should clamp to 0 (minimum), not UInt32.max.
- Changed condition from `a <= -1.0` → `a < 0.0` for saturation NaN/negative branch.
- This ensures values in `(-1, 0)` always clamp to 0 safely without calling `UInt32(a)`.

## New WasmError case
`invalidConversionToInteger` — Wasm trap for trunc with NaN/Inf/out-of-range operand.

## New Instruction cases (WasmModule.swift, enum Instruction)
i32WrapI64, i32TruncF32S/U, i32TruncF64S/U, i64ExtendI32U, i64TruncF32S/U, i64TruncF64S/U,
f32ConvertI32S/U, f32ConvertI64S/U, f32DemoteF64, f64ConvertI32S/U, f64ConvertI64S/U, f64PromoteF32,
i32ReinterpretF32, i64ReinterpretF64, f32ReinterpretI32, f64ReinterpretI64,
i32TruncSatF32S/U, i32TruncSatF64S/U, i64TruncSatF32S/U, i64TruncSatF64S/U.

**How to apply:** When reviewing or extending trunc operations, remember the `> -1.0` lower bound for unsigned and `> -2147483649.0` for i32.trunc_f64_s. Always guard against Swift's runtime crash on `UInt(negativeFloat)`.
