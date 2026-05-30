---
name: project-recurring-patterns
description: Recurring correctness pitfalls and design patterns observed across review sessions
metadata:
  type: project
---

## Correctness Patterns

1. **f64.const in function bodies vs. global init exprs** [RESOLVED]: Both parser locations now correctly handle opcode 0x44. `parseFlatBody()` emits `.f64Const(try readF64())`. `Instruction` enum has `case f64Const(Double)`. Interpreter has `case .f64Const(let value): valueStack.append(.f64(value))`. Validator has `case .f64Const: tryPush(.f64)`. Test runner `isSupportedType()` includes "f64".

2. **call_indirect type checking — result type comparison** [RESOLVED]: The interpreter now checks both param types elementwise AND result types elementwise after the count guards. Lines 1131–1136 in WasmInterpreter.swift implement the full structural match per spec.

3. **Element segment flags=2 elemkind**: The `_ = try readByte()` for elemkind silently accepts any byte value. The spec says flags=2 elemkind=0x00 means funcref. Should guard `elemkind == 0x00` or at minimum document the relaxation.

4. **Table bounds in callIndirect**: `eIdx >= 0` is always true for Int in Swift (since Int is signed but the spec treats this as u32). However, the `Int(elemIdx)` cast from an i32 on the stack is correct — negative i32 values become large Int values on 64-bit, failing the `eIdx < tbl.count` check. This is correct behavior per spec.

## Design Patterns

5. **Flat bytecode with pre-computed jump offsets**: Parser emits `block(bt, endPc)`, `loop(bt, startPc)`, `ifElse(bt, elsePc, endPc)` with integer PCs baked in. This is the core architectural choice — avoids indirect enum cases and heap allocation.

6. **isSupportedType() gate in test runner**: `SpectestTests.swift` uses `isSupportedType()` to skip tests involving unsupported types. After adding f64 support, this function must include "f64" or tests using f64 values will continue to be skipped even if f64Const is implemented.

7. **elementsEqual vs. String ==**: All export/import name matching uses `.elementsEqual(x.utf8)` — correct Embedded Swift pattern already in place.

8. **Typed throws throughout**: All public functions use `throws(WasmError)` — consistent with Embedded Swift constraints.

9. **Memory effective address (ea) computation**: Formula is `Int(UInt32(bitPattern: addr)) &+ Int(offset)` where both inputs are u32-ranged. On 64-bit hosts `ea` is always non-negative so `ea >= 0` is vacuously true. On 32-bit Embedded targets, `&+` wraps silently if addr+offset > 0xFFFF_FFFF; the `ea >= 0` guard does not catch this wraparound. The correct fix is to compute in u64 or compare unsigned: `let ea64 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset); guard ea64 + N <= UInt64(memory.count) else { throw .memoryAccessOutOfBounds }`.

10. **Validator store pop order**: Validator pops value first then address (matching interpreter's removeLast() order for a stack). The Wasm spec push order is [addr, value] (addr pushed first, value on top), so removeLast() gives value first — this is correct and consistent between validator and interpreter.

11. **wasmF64Min/Max NaN propagation**: The helpers check `a.isNaN || b.isNaN` and return `.nan`. Per Wasm spec, either operand being NaN causes the result to be a canonical NaN (not the arithmetic NaN). Swift's `.nan` is the canonical quiet NaN, so this is correct for spec purposes even though NaN payloads are not preserved by this path.
