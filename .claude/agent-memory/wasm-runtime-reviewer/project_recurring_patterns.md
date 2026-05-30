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

12. **table.get/set negative index handling**: `tableGet`/`tableSet` use `Int(UInt32(bitPattern: idx))` to convert the i32 stack value to a table index. This reinterprets negative i32 as large UInt32 values, which will fail the `< tables[ti].count` bounds check — correct per spec (trap). `callIndirect` uses a different (but equally correct) approach: raw `Int(elemIdx)` with `eIdx >= 0` guard. The UInt32-bitPattern approach is the cleaner pattern.

13. **Value.funcref encoding**: `Value` enum carries `.funcref(UInt32?)` where `nil` = null reference. This is different from WasmKit which uses a separate `Reference` type. The `nil`-means-null encoding is compact and correct for this project's funcref-only table support.

14. **Validator: table.get/set hardcode funcref**: The validator at WasmValidator.swift (case .tableGet, .tableSet) hardcodes `funcref` as the table element type. This is correct only for funcref tables. The spec requires looking up the table's declared element type. Currently this is fine because the parser only supports funcref tables (RefType.funcRef), but if externref tables are added the validator must be updated to look up table[x].refType.

15. **SpectestTests.swift funcref comparison**: The `valueMatches` case for "funcref" checks `expStr == "null"` → `ar == nil`, otherwise `UInt32(expStr)` → `ar == idx`. The wast2json format for funcref values encodes null as the string "null" and non-null as the decimal function index. This is correctly handled.

16. **Bulk memory Int overflow on 32-bit (Embedded-TODO)**: `memory.init`, `memory.copy` compute `Int(UInt32(bitPattern: ...))` for addresses and counts. On 64-bit macOS this is safe (the sum fits in Int64). On 32-bit RP2350, `Int(UInt32(0xFFFF_FFFF))` would overflow Int32, causing a runtime trap. The fix for Embedded is to work in `UInt32` throughout and use `addingReportingOverflow`. Annotated `[macOS-phase-OK, Embedded-TODO]` — same pattern as ea computation in loads/stores (pattern #9).

17. **`data.drop` on active segments**: The spec allows dropping active segments (they are NOT auto-dropped at instantiation in the finalized Wasm 2.0 spec). The `droppedDataSegments` array is initialized to `false` for ALL segments including active ones, which is correct.

18. **memory.init dropped segment empty-array allocation**: `droppedDataSegments[si] ? [] : module.data[si].bytes` creates an empty `[UInt8]()` heap allocation on every call when the segment is dropped. For Embedded, replace with an explicit boolean check and skip the bytes path. `[macOS-phase-OK, Embedded-TODO]`.

19. **memory.copy overlap detection correctness**: The condition `dstOff <= srcOff || dstOff >= srcOff + copyCount` correctly handles both the non-overlapping case and the dst-before-src case. The backward copy path handles dst > src with overlap. This mirrors memmove semantics and is spec-correct.

20. **memory.init n=0 spec behavior**: When n=0, the spec requires `src <= len(seg)` AND `dst <= len(mem)` (i.e., equality is allowed). The check `srcOff + 0 <= segBytes.count` correctly allows src == len(seg) without trapping. The code comment previously described this as "unconditional success" but the code is correct — it does the proper bounds check.
