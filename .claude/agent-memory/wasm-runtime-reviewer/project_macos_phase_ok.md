---
name: project-macos-phase-ok
description: Items currently permitted in macOS phase but requiring replacement in Embedded Phase 5+
metadata:
  type: project
---

All items below are [macOS-phase-OK, Embedded-TODO] and should be tracked for Phase 5+ migration:

1. `typealias HostFunction = ([Value], [UInt8]) -> [Value]` — heap closure; replace with `@convention(c)` function pointer + opaque context pointer in Embedded phase
2. `var memory: [UInt8]` — dynamic Array; replace with fixed-size buffer or UnsafeMutableRawBufferPointer
3. `var valueStack: [Value]` — dynamic Array; replace with fixed-capacity stack buffer
4. `var frames: [Frame]` — dynamic Array; replace with fixed-depth call stack
5. `var tables: [[UInt32?]]` — nested dynamic Array; replace with fixed-size flat structure
6. `var globals: [Value]` — dynamic Array; acceptable if count bounded at parse time
7. `String` usage in `HostImport.function(String, String, HostFunction)` — replace with [UInt8] in Embedded phase
8. `[UInt8]` arrays for module/name bytes in imports/exports — acceptable per project design (already uses byte comparison)
9. `indirect case` not currently used in Instruction enum (good — flat bytecode approach avoids it)
10. `var droppedDataSegments: [Bool]` — dynamic Array of Bools; replace with fixed-size bitfield or static array in Embedded phase
11. `droppedDataSegments[si] ? [] : module.data[si].bytes` — creates empty `[UInt8]()` heap allocation for dropped segments; replace with explicit boolean check in hot path
12. `Int(UInt32(bitPattern: ...))` for bulk memory address/count arithmetic — safe on 64-bit macOS; on 32-bit Embedded would overflow for values > Int32.max. Fix: use `UInt32` arithmetic with `addingReportingOverflow` for Phase 5
