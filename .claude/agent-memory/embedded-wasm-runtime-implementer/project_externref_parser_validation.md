---
name: externref-parser-validation
description: externref type, table [[Value]] refactor, UTF-8 validation, LEB128 canonical check, trailing bytes detection
metadata:
  type: project
---

## externref implementation and parser validation improvements

### Changes implemented

**WasmModule.swift:**
- Added `ValueType.externref = 0x6F` to the ValueType enum
- Changed `Instruction.refNull` → `Instruction.refNull(RefType)` to carry the reftype
- Added `Value.externref(UInt32?)` case to the runtime Value enum
- Tables type changed conceptually from `[[UInt32?]]` to `[[Value]]` (done in interpreter)

**WasmInterpreter.swift:**
- `tables` field changed from `[[UInt32?]]` to `[[Value]]`
- Table initialization: null slots use `.funcref(nil)` for funcref tables, `.externref(nil)` for externref tables
- Active element segments applied at init now store `.funcref(funcIdx)` (not raw UInt32?)
- `table.get`: returns Value directly from table (funcref or externref)
- `table.set`: accepts any reference Value (funcref or externref)
- `table.fill`: accepts any reference Value
- `table.grow`: accepts any reference Value, validates it's a ref type via switch
- `table.init`: stores `.funcref(elems[i])` converting UInt32? to Value
- `table.copy`: works unchanged (Value to Value copy)
- `refNull(RefType)`: pushes `.funcref(nil)` or `.externref(nil)` based on RefType
- `refIsNull`: handles both `.funcref` and `.externref` via switch
- `callIndirect`: extracts `.funcref(let optFuncIdx)` from table slot, traps on nil or non-funcref
- `pushFrame` locals init: `case .externref: locals.append(.externref(nil))`

**WasmParser.swift:**
- `ref.null` (0xD0): now reads reftype byte and emits `.refNull(refType)` with proper RefType
- Global section `ref.null`: now emits `.funcref(nil)` or `.externref(nil)` based on parsed RefType
- Custom section (id=0): now calls `parseCustomSection(size:)` which validates the section name UTF-8
- Added `validateUTF8(_ bytes: [UInt8])` method with full overlong/surrogate/range checks
- Added trailing bytes check: `guard stream.isExhausted else { throw .unexpectedContent }`

**WasmError.swift:**
- Added `malformedUTF8` — invalid UTF-8 in custom section name
- Added `unexpectedContent` — trailing bytes after last section

**LEB128.swift:**
- ULEB128 canonical check: terminator byte == 0x00 with shift > 0 throws `integerRepresentationTooLong`
- SLEB128 canonical check: terminator == 0x00 when prevByte bit6==0, or terminator == 0x7F when prevByte bit6==1

**WasmValidator.swift:**
- `refNull(RefType)`: pushes `.funcref` or `.externref` based on RefType
- `refIsNull`: pops top of stack (must be funcref or externref), pushes i32
- `tableGrow`, `tableFill`, `tableGet`, `tableSet`: elem type determined by table's declared refType (funcref vs externref)

**SpectestTests.swift:**
- `isSupportedType`: added `"externref"`
- `convertValue`: added `case "externref"` 
- `valueMatches`: added `case "externref"`

### Test results
- `utf8-custom-section-id`: 176 pass (was 0 before)
- `table_fill`: 45 pass, 0 skip (was ~67 skipped)
- `table_get`: 16 pass, 0 skip
- `table_set`: 26 pass, 0 skip
- `table_grow`: 47 pass, 11 skip (64-bit tables still skip)
- `binary-leb128`: 58 pass, 33 skip
- `binary`: 96 pass, 31 skip
- Embedded Swift compile: passes

**Why:** LEB128 canonical check needed for binary-leb128 spec tests; UTF-8 validation needed for utf8-custom-section-id; externref + [[Value]] table for table_fill/get/set/grow externref tests.

**How to apply:** When implementing future table/ref operations, remember tables store `Value` not `UInt32?`. The `callIndirect` pattern-matches `.funcref(let idx)` from the table slot.
