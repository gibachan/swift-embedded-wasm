---
name: project-architecture
description: Key locations of interpreter switch, value stack, parser, and module data structures
metadata:
  type: project
---

- Main interpreter switch: `Sources/WasmRuntime/WasmInterpreter.swift` — `runIterative()` function, switch on `Instruction` enum
- Value stack: `var valueStack: [Value]` inside `runIterative()` — shared across all frames
- Frame stack: `var frames: [Frame]` — Frame owns `locals: [Value]`, `labels: [Label]`, `ip: Int`
- Instruction enum: `Sources/WasmRuntime/WasmModule.swift` — `enum Instruction`
- Value enum: `Sources/WasmRuntime/WasmModule.swift` — `enum Value { case i32(Int32); case i64(Int64); case f32(Float); case f64(Double) }`
- Parser: `Sources/WasmRuntime/WasmParser.swift` — `parseFlatBody()` for instruction body, section parsers above it
- WasmError: `Sources/WasmRuntime/WasmError.swift`
- Validator (macOS-only): `Sources/WasmRuntime/WasmValidator.swift` — gated on `#if !hasFeature(Embedded)`
- Tables: `var tables: [[UInt32?]]` in `WasmInterpreter` — changed from single table to multi-table in this iteration
- HostFunction type: `typealias HostFunction = ([Value], [UInt8]) -> [Value]` — [macOS-phase-OK, Embedded-TODO] heap closure
