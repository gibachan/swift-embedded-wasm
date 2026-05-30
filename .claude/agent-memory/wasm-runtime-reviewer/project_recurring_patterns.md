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

21. **memory.fill n=0 spec behavior**: Same as pattern #20 — bounds check applies unconditionally. `dstOff + 0 <= memory.count` correctly allows dst == memory.count without trapping. Interpreter correctly uses `Int(UInt32(bitPattern:))` for all three operands, consistent with memoryCopy/memoryInit pattern.

22. **table.init active segment dropping**: Active element segments are marked as dropped (`droppedElementSegments[i] = true`) during `init()` after being applied to tables, per Wasm spec §4.5.4. Passive segments remain `false` (available for table.init). Dropped segment acts as length-0 segment — any `srcOff + copyCount > 0` traps.

23. **table.copy overlap handling**: When dst table == src table (di == si), copy direction follows memmove semantics: `dstOff <= srcOff || dstOff >= srcOff + copyCount` → forward; otherwise backward. When different tables, no aliasing is possible, always forward. This is spec-correct.

24. **table.init/tableCopy error types**: These table bulk operations use `.undefinedElement` for all out-of-bounds conditions (matching the existing convention for table traps vs `.memoryAccessOutOfBounds` for memory). The spectest runner accepts any WasmError as a valid trap signal, so this is fine functionally.

25. **droppedElementSegments parallel to droppedDataSegments**: Same `[Bool]` pattern, initialized to `false` for passive segments and `true` for active segments (post-instantiation). Consistent with existing data segment pattern. Flagged `[macOS-phase-OK, Embedded-TODO]` for fixed-size buffer replacement.

26. **Passive element segment (flags=1) parser**: `_ = try readByte()` for elemkind silently consumes any byte. Per spec, flags=1 elemkind=0x00 means funcref. No guard on the value, same as the existing flags=2 case. Acceptable but leaves a potential correctness gap if non-funcref elemkind bytes appear.

27. **trunc bounds for signed f64→i32 (i32.trunc_f64_s)**: Lower bound is `a > -2147483649.0` (strict), not `a >= -2147483648.0`. This is correct because f64 values in (-2147483649.0, -2147483648.0) are non-integer and truncate toward zero to -2147483648 = INT32_MIN (valid). -2147483649.0 truncates to -2147483649 < INT32_MIN (trap). The asymmetry between the f32 and f64 lower bounds is deliberate and spec-correct.

28. **trunc bounds for f32→i32 signed (i32.trunc_f32_s)**: Lower bound is `a >= -2147483648.0` (non-strict). This is correct because there is no f32 between -2147483648.0 and the next more-negative f32 (-2147483904.0), and -2147483904.0 would truncate below INT32_MIN. The strict-vs-non-strict distinction between f64 and f32 cases is critical.

29. **unsigned trunc lower bound uses `a > -1.0` not `a >= 0.0`**: Values in (-1, 0) truncate toward zero to 0 (valid for unsigned). The code then guards `a < 0.0 ? 0 : UInt32/UInt64(a)` to prevent Swift runtime trap on negative UInt conversion.

30. **i64TruncF64S comment inaccuracy**: Code says "Values in (-9223372036854777856.0, -9223372036854775808.0)" but these are consecutive f64 values — no f64 exists in the interior of that range. The code `a >= -9223372036854775808.0` is correct; only the comment is slightly misleading. The code accepts exactly -2^63 and rejects the next more-negative f64.

31. **i64TruncF32S with Int64(-2^63)**: Calling `Int64(Float(-9223372036854775808.0))` is safe in Swift because -2^63 is exactly representable as both Float and Int64. The bounds check `a >= -9223372036854775808.0` passes for this exact value, and the resulting conversion is valid.

32. **Saturating trunc boundary overlap (i32TruncSatF32S)**: For `a == -2147483648.0` (exactly INT32_MIN), both the saturation path (`a <= -2147483648.0 → Int32.min`) and the else path (`Int32(a) = Int32.min`) give identical results. The overlap is harmless and correct.

33. **tableGrow missing overflow guard**: Unlike `memoryGrow` (which has `let overflows = n > Int.max / pageSize`), `tableGrow` at line 2116 does `let newSize = tables[ti].count + n` without an overflow check. On 32-bit Embedded targets this can cause a Swift runtime trap. `[macOS-phase-OK, Embedded-TODO]` — add `guard n <= Int.max - tables[ti].count else { return -1 }`.

34. **ref.null reftype byte consumed but not validated**: Parser line 839 reads the reftype byte (`_ = try readByte()`) without checking it. `ref.null externref` (0xD0 0x6F) is silently treated as funcref. Acceptable for MVP funcref-only support.

35. **Validator tableGrow/tableFill dead ternary**: `module.tables[ti].refType == .funcRef ? .funcref : .funcref` — both branches are identical. This is the same pattern as tableGet/tableSet (recurring pattern #14). Acceptable until externref is added, but should be cleaned up or documented as intentional.

36. **tableFill bounds check correctness**: `guard dstOff <= tables[ti].count && dstOff + fillCount <= tables[ti].count` — the first condition is subsumed by the second for all non-negative fillCount. The expression is logically correct (no bug) but the first clause is redundant. This mirrors the spec comment "n=0 is valid only when dst <= table_size" which is also enforced by the second clause. A minor clarity issue only.

37. **Declarative element segments (flags=3, flags=7) stored as isPassive=true**: Marking declarative segments as passive causes droppedElementSegments[i] to start as false, allowing erroneous table.init on them at runtime. The Wasm spec treats declarative segments as pre-dropped (inaccessible to table.init). The correct fix is to initialize droppedElementSegments[i]=true for declarative segments just as active segments are. In practice the spectest conformance runner skips modules that fail, so this is unlikely to be caught by current tests.

38. **Cross-module HostFunction closure mutation semantics**: The crossModuleImports HostFunction closure captures `var capturedInterp` by value. Since WasmInterpreter is a struct, mutations inside callExport (e.g. globals updated by the called function) are lost after each call through the closure. The closure always calls from the snapshot state captured at module-load time. For pure functions this is correct; for stateful exports this silently discards mutations.

39. **`try? capturedInterp.callExport(...)` silently swallows errors**: Any WasmError thrown by a cross-module call is mapped to `[]` (empty return). For assert_return tests this causes a false-pass (returns [] which may match a [] expected result) or a value mismatch fail rather than a trapped-as-expected result. The behavior is acceptable for the skip-heavy spectest runner but could mask real implementation bugs.

40. **`unexpectedContent` guard is dead code**: `parse()` uses `while !stream.isExhausted { ... }` which only exits when the stream IS exhausted. The `guard stream.isExhausted else { throw .unexpectedContent }` immediately after is always true and never throws. The spec requires trailing-byte detection but the implementation cannot detect it via this guard. Section parsers also don't verify they consume exactly `size` bytes — section-internal padding corrupts subsequent reads.

41. **`tableSet` runtime type mismatch not enforced**: The interpreter's `tableSet` accepts any `.funcref` or `.externref` value without checking against the table's declared `refType`. The validator (macOS-only) catches this at compile time. In Embedded (no validator), storing externref into a funcref table is silently allowed at runtime.

42. **`call_indirect` with externref table correctly traps**: Pattern match `case .funcref(let optFuncIdx) = tbl[eIdx]` fails for `.externref(...)`, throwing `.undefinedElement`. This is correct per spec.

43. **LEB128 canonical check covers 0x00 and 0x7F terminators for SLEB128**: The canonical check `if byte == 0x00 && prevSign == 0` and `if byte == 0x7F && prevSign != 0` is applied in both the overflow and normal terminator paths. However, the single-byte path has no `byteCount > 1` guard issue since single-byte decodes go through the while loop then the post-loop check — byteCount=1 so the guard is `> 1` → not entered. Single-byte encodings are always canonical.

44. **tableInit copies funcref indices as .funcref(optIdx)**: Element segments store `[UInt32?]` (funcref indices), and `tableInit` converts each to `.funcref(elems[srcOff + i])`. This is correct for funcref tables. For externref tables (hypothetical), the copy would incorrectly store `.funcref` values. Not a current bug since externref element segments are not parsed.

45. **externref test coverage gap**: The `isSupportedType` in SpectestTests includes "externref", and `convertValue` / `valueMatches` handle externref. But current element segment parsing only supports funcref indices — externref element segments are not parseable, so spectest externref tests involving non-null externref values in tables will fail or skip at module load time.

46. **flags=5 element segment misclassified as declarative** [RESOLVED]: Fixed — WasmParser.swift case 5 now uses `isDeclarative: false`. WasmInterpreter.swift comment updated to list only flags=3 and flags=7 as declarative. flags=5 (passive + init_expr list) is now correctly available to table.init at runtime.

47. **Section-size mismatch check correctly excludes custom sections (id=0)**: `parseCustomSection(size:)` handles its own exact byte accounting internally (reads exactly `size` bytes). The outer `if id != 0` guard is correct asymmetry. Custom section overread is caught by `guard remaining >= 0` inside `parseCustomSection`.

48. **`dataCountRequired` check scans parsed instruction arrays (not raw bytes)**: The post-parse scan for `memoryInit`/`dataDrop` in code bodies is correct and Embedded-safe (uses explicit for-loops, not closures). The `outerLoop:` labeled break avoids redundant full scans.

49. **`default:` branch in section switch is dead code but harmless**: After the `id > 12` guard, all ids 0–12 are handled by named cases. The `default:` branch (which skips `size` bytes) is unreachable. Annotated with a comment; no functional issue.

50. **Section ordering: `lastNonCustomSectionId` correctly allows non-consecutive ids**: The check `id < lastNonCustomSectionId → outOfOrder` and `id == lastNonCustomSectionId → duplicate` correctly implements ascending-with-gaps requirement. Custom sections (id=0) bypass this entirely.
