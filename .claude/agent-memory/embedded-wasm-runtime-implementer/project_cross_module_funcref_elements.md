---
name: cross-module-funcref-elements
description: Cross-module linking (register), funcref global init expressions, and expression-based element segments (flags 3-7) implementation
metadata:
  type: project
---

Cross-module linking, funcref global parsing, and expression-based element segments were implemented to improve spectest conformance.

**Why:** `table_copy` had 1117 skips due to the `register` command being unimplemented. `ref_func` tests needed funcref global init expressions and element segment flags 3-7.

**How to apply:** These features enable the spectest conformance runner to handle cross-module imports and expression-based element segments.

## Changes Made

### 1. Cross-Module Linking (`SpectestTests.swift`)
- Added `registeredModules: [String: WasmInterpreter]` to `ConformanceRunner`
- Implemented `handleRegister` to store modules by their "as" name
- Implemented `crossModuleImports(for:)` to build `HostImport` entries from registered modules
- Modified `handleModule` to call `spectestHostImports() + crossModuleImports(for: module)`
- Value-copy captures in closures: `var capturedInterp = regInterp` — safe for pure functions

**Results:** table_copy: skip=1117 → skip=0, pass=1728

### 2. funcref Global Init Expressions (`WasmParser.swift`)
- Added `case 0xD0` (ref.null) and `case 0xD2` (ref.func) to `parseGlobalSection()`
- `ref.null` reads reftype byte, discards it, sets `initValue = .funcref(nil)`
- `ref.func` reads funcIdx, sets `initValue = .funcref(funcIdx)`
- Both forms read the mandatory `end` (0x0B) byte

### 3. Expression-Based Element Segments (`WasmParser.swift`)
- Extended `parseElementSection()` to support flags 3-7
- Added helper `readFuncrefInitExpr()` that reads `ref.null reftype 0x0B` or `ref.func funcidx 0x0B`
- `ElementSegment.functionIndices` changed from `[UInt32]` to `[UInt32?]` (nil = null ref)
- flags 3 (declarative, elemkind 0x00): like passive but declared only
- flags 4 (active, table 0, init_expr list): uses i32.const offset
- flags 5 (passive, reftype byte): like flags 1 but expression-based
- flags 6 (active, explicit table, init_expr list): uses i32.const offset + explicit table index
- flags 7 (declarative, reftype byte): like flags 3 but with reftype instead of elemkind

### Key Design Decision: UInt32? for functionIndices
Changed `ElementSegment.functionIndices` from `[UInt32]` to `[UInt32?]` to represent null references from expression-based segments. The table itself already uses `[UInt32?]` so this was consistent. WasmInterpreter.swift requires no changes since tables are already `[[UInt32?]]`.

## Remaining ref_func Skips (14)
The 14 remaining ref_func skips are pre-existing — they throw `WasmError.invalidInstruction` at runtime for some other reason not related to these changes. The `register` command now passes (+1 from the previous 15 skips).
