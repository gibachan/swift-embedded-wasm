---
name: memory-size-table-ops-ref
description: Implementation of memory.size, table.size/grow/fill, and ref.null/is_null/func instructions; includes memory.grow max-page fix
metadata:
  type: project
---

Implemented `memory.size` (0x3F), `table.size` (0xFC 0x10), `table.grow` (0xFC 0x0F), `table.fill` (0xFC 0x11), `ref.null` (0xD0), `ref.is_null` (0xD1), and `ref.func` (0xD2).

**Why:** spectest conformance runner revealed these opcodes caused `invalidInstruction` traps or unimplemented stubs.

**How to apply:** All four files were modified in a consistent pattern — add to `Instruction` enum in `WasmModule.swift`, parse in `WasmParser.swift`, execute in `WasmInterpreter.swift`, validate in `WasmValidator.swift`.

## Key implementation notes

### memory.size (0x3F)
Binary: `0x3F 0x00` — reserved byte follows, identical to `memory.grow` (0x40). Added to parser directly before the 0x40 case. Returns `memory.count / 65536` as `i32`.

### memory.grow max-page fix (pre-existing bug fixed alongside)
The previous `memory.grow` check `Int(delta) > pageSize - currentPages` was comparing delta (page count) against ~65536 (bytes minus currentPages), effectively never enforcing limits. Fixed to:
- Treat delta as `UInt32(bitPattern: delta)` (unsigned interpretation)
- Check `newPages > Int(module.memories.first?.max ?? 65536)`
- This fixed `memory_size` test: 35 pass → 42 pass

### table.grow max-limit check
Tables have a `max: UInt32?` in `TableType`. `tableGrow` now checks `newSize > Int(module.tables[ti].max)` before extending `tables[ti]`. Returns old size on success, -1 on failure.

### ref.null / ref.is_null / ref.func
- `ref.null` (0xD0): reads and discards the reftype byte (0x70 funcref, 0x6F externref); always pushes `.funcref(nil)`
- `ref.is_null` (0xD1): no operand; pops funcref, pushes i32 (1 if nil, 0 otherwise)
- `ref.func` (0xD2): reads u32 funcIdx; validates against `importedFunctionCount + functions.count`; pushes `.funcref(funcIdx)`

### table.fill bounds check
Checks `dstOff <= tables[ti].count && dstOff + fillCount <= tables[ti].count` unconditionally (per spec: zero-length fill with out-of-range dst still traps).

## Test results after implementation
- `memory_size`: 42 pass, 0 fail (was entirely skipped/failing)
- `table_size`: 39 pass, 0 fail (was 32 pass, 7 fail)
- `table_grow`: 24 pass, 0 fail (was 22 pass, 2 fail)
- `table_fill`: 9 pass, 36 skip, 0 fail (externref skips expected)
- Full suite: 52/52 tests pass
- Embedded Swift compile: success (armv7em-none-none-eabi)
