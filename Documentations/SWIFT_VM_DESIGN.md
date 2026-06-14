# Swift Wasm VM Design

This document defines the design policy for implementing a Wasm VM in Swift,
along with constraints and patterns specific to the Embedded Swift environment.
It is informed by the wasm3 investigation (`Documentations/PHASE2_WASM3.md`) and aims for
a design that leverages Swift's language features while remaining compatible with Embedded constraints.

---

## 1. Core Design Principles

### Principle 1: Design for Understanding
Do not aim for speed or completeness from the start. Prioritize code where the role and
responsibility of each component is clearly legible. Optimize only after understanding the mechanics.

### Principle 2: Maximize Swift Type Safety
Redesign parts that wasm3 handles without types (due to C constraints) — `union` / `void*` / `const char*` —
using Swift's enum, generics, and protocols in a type-safe way.

### Principle 3: Align with Embedded Swift Constraints from the Start
Maintain a common source from macOS to Pico, and implement to Embedded Swift constraints from day one.

- No intermediate array copies in hot paths (`Array(xxx.suffix(n))`)
- No `String ==` comparisons (use `[UInt8]` byte comparison instead)
- Always use typed throws (`throws(ErrorType)`)
- Mark unavoidable dynamic allocations with `// TODO: Embedded Phase 5`

Only the validator (`WasmValidator`) is conditionally compiled with `#if !hasFeature(Embedded)`.
Embedded builds assume trusted input (developer-controlled binaries) and skip type checking.

### Principle 4: Build Incrementally
Implement one instruction at a time with verifiable granularity (following the `Documentations/OVERVIEW.md` policy).

---

## 2. Component Architecture

```text
┌─────────────────────────────────────────────────┐
│                  WasmRuntime                    │
│  ┌──────────┐  ┌───────────┐  ┌─────────────┐  │
│  │  Parser  │  │ Validator │  │ Interpreter │  │
│  └──────────┘  └───────────┘  └─────────────┘  │
│  ┌──────────────────────────────────────────┐   │
│  │              WasmModule                  │   │
│  │  FunctionType[] / Function[] / Global[]  │   │
│  │  [UInt8] memory / DataSegment[]          │   │
│  └──────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────┐   │
│  │           HostFunctionTable              │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

| Component | Role |
|-----------|------|
| `WasmParser` | Converts Wasm binary to `WasmModule` |
| `WasmValidator` | Validates module type consistency (enabled only via `#if !hasFeature(Embedded)`) |
| `WasmInterpreter` | Executes the module (Stack Machine). Tracks `data.drop` / `elem.drop` state via `droppedDataSegments: UInt64` / `droppedElementSegments: UInt64` bitmaps |
| `WasmModule` | Parsed Wasm module (functions, memory, globals). `DataSegment.offset: Int32?` (nil = passive, non-nil = active write offset) |
| Linear Memory | `var memory: [UInt8]` (held by the interpreter). Responsible for bounds checking |
| Host Function Table | `[HostFunction]` array (indexed in import declaration order) |

---

## 3. Type Design

### 3.1 Wasm Value Type

wasm3 holds values as `union { i32; i64; f32; f64 } + u8 type`, with type mismatches caught at runtime.
Swift expresses this type-safely using an enum with associated values.

The implementation separates `Value` (runtime value) from `ValueType` (type code).

```swift
// Runtime value (WasmModule.swift: enum Value)
enum Value: Sendable, Equatable {
    case i32(Int32)
    case i64(Int64)
    case f32(Float)
    case f64(Double)
    case funcref(UInt32?)   // nil = null reference; UInt32 = function index
    case externref(UInt32?) // nil = null reference; UInt32 = opaque host index
}
```

### 3.2 Wasm Type Codes

```swift
// Type code (WasmModule.swift: enum ValueType)
enum ValueType: UInt8 {
    case i32      = 0x7F
    case i64      = 0x7E
    case f32      = 0x7D
    case f64      = 0x7C
    case funcref  = 0x70  // reference to a function
    case externref = 0x6F // opaque host reference
}
```

### 3.3 Function Signature

```swift
// WasmModule.swift: struct FunctionType
struct FunctionType: Sendable {
    let params: [ValueType]
    let results: [ValueType]
}
```

### 3.4 Error Type

wasm3 uses `M3Result = const char*` (NULL = success, non-NULL = error message).
Swift unifies parse-time errors and runtime traps in a type-safe `Error` enum.

```swift
// WasmError.swift: enum WasmError
enum WasmError: Error, Equatable, Sendable {
    // --- Parser ---
    case invalidMagic
    case unexpectedEnd
    case invalidInstruction(UInt8)
    case leb128Error(LEB128Error)
    // ... other parse errors

    // --- Interpreter (trap equivalents) ---
    case stackUnderflow
    case typeMismatch
    case memoryAccessOutOfBounds
    case divisionByZero
    case unreachableReached
    case indirectCallTypeMismatch
    // ... other runtime errors
}
```

Typed throws (`throws(WasmError)`) are used throughout to avoid `any Error` existentials.
This also satisfies the Embedded Swift constraint against existential types.

---

## 4. Validation Policy

wasm3 has no validation phase; type checking is unimplemented. This project uses `#if !hasFeature(Embedded)`.

### Non-Embedded Build (macOS development / debug)

**Full validation enabled.**

- Function signature type consistency checking
- Per-instruction stack type checking (type stack tracking)
- Invalid Wasm detected as `WasmError` before execution

```swift
// WasmParser.swift
#if !hasFeature(Embedded)
try WasmValidator(module: module).validate()
#endif
```

```swift
// WasmValidator.swift
#if !hasFeature(Embedded)
struct WasmValidator {
    func validate() throws(WasmError) { ... }
}
#endif
```

Goal: catch bad Wasm binaries and implementation bugs early during development.

### Embedded Build (Pico)

**Validation skipped.**

- Magic number / version check (always performed in the parser)
- No type stack tracking (saves RAM and load time)
- Assumes trusted input (developer-controlled binaries)

---

## 5. Interpreter Loop

wasm3 dispatches via **Threaded Code** (function pointer array + tail calls), but tail-call
optimization is not guaranteed in Embedded Swift.

This project uses a `switch`-based implementation.

### Phase 1: Switch-Based (implemented)

```swift
switch instruction {
case .i32Const(let value):
    valueStack.append(.i32(value))
case .i32Add:
    let b = valueStack.removeLast()
    let a = valueStack.removeLast()
    // ...
case .call(let funcIdx):
    try pushFrame(funcIdx: Int(funcIdx), argCount: argCount)
}
```

High readability, easy to debug, and guaranteed Embedded Swift compatibility.
The `switch` exhaustiveness check means the compiler catches missing cases when new instructions are added.

### Phase 1.5: Migration to Flat Bytecode (complete)

The previous implementation stored `block` / `loop` / `if` instructions with nested arrays of child instructions.

```swift
// Old implementation (indirect case = malloc required)
indirect case block(BlockType, [Instruction])
indirect case ifElse(BlockType, thenBody: [Instruction], elseBody: [Instruction])
```

`indirect case` compiles in Embedded Swift but requires `malloc` at link time.

**Adopted solution: Flat Bytecode + jump offsets (implemented)**

```swift
// Current implementation (no malloc required)
case block(BlockType, Int)       // endPc: index of instruction after blockEnd
case loop(BlockType, Int)        // startPc: first body instruction (br returns here)
case ifElse(BlockType, Int, Int) // elsePc, endPc
case blockEnd                    // end-of-body marker for block/loop/if
case jump(Int)                   // unconditional jump to PC (skips else body)
```

All instructions are laid out in a flat array; block/loop/if carry their jump target PC directly.
The parser computes and embeds offsets at parse time.
The same approach is used by CPython bytecode and JavaScriptCore, making it educationally valuable.

### Phase 2: Zero-Copy Code Section — `FunctionHandle` (implemented, Embedded builds)

In Embedded builds (`#if hasFeature(Embedded)`), the parser no longer expands instructions into
`[Instruction]` at load time. Instead it stores a `FunctionHandle` — a compact byte-range descriptor
that allows the interpreter to re-parse the function body on demand.

```swift
// Embedded build: WasmModule.code is [FunctionHandle], not [FunctionBody]
struct FunctionHandle: Sendable {
    let codeOffset: UInt32            // byte offset of instruction stream in rawBytes
    let codeSize: UInt32              // byte length of instruction stream
    let locals: [ValueType]           // local variable types (TODO: fixed buffer in Phase 4)
    let hasBulkMemoryInstruction: Bool
    let jumpTable: [JumpEntry]        // pre-computed block/loop/if targets
}
```

`WasmModule.rawBytes` holds the original Wasm binary. When the interpreter calls a function, it
constructs a sub-parser over the stored byte range and calls the shared `parseFlatBody()` to
obtain a `[Instruction]` array. This eliminates the per-function `[Instruction]` allocation at
load time, replacing it with a per-call allocation (acceptable until Phase 4 removes it entirely).

### Phase 2.5: Jump Table Pre-computation (implemented, Embedded builds)

To support Phase 4's on-the-fly decoder, `FunctionHandle` includes a `jumpTable: [JumpEntry]`
built at parse time. This table maps each `block`/`loop`/`if` opcode to its byte-offset targets
within `rawBytes`, eliminating the need to scan forward through raw bytes at runtime.

```swift
struct JumpEntry: Sendable {
    let instrOffset: UInt32  // absolute byte position of the block/loop/if opcode in rawBytes
    let target1: UInt32      // block: byte after end opcode (br-continuation)
                             // loop:  first byte of loop body (br restarts here)
                             // if/else: byte of else clause start (or byte after end if no else)
    let target2: UInt32      // if/else: byte after end opcode (br-continuation)
                             // block/loop: 0 (unused)
}
```

**Pre-order invariant**: entries are stored in the order the `block`/`loop`/`if` opcodes appear
in the byte stream (parent before children). Phase 4's on-the-fly decoder advances a monotonically
increasing integer cursor by 1 each time it encounters a control-flow opcode. This gives O(1)
lookup without search.

The parser variant `parseFlatBodyTracked()` (Embedded-only, in `WasmParser.swift`) builds both the
temporary `[Instruction]` array and the `[JumpEntry]` table in a single pass, using the same
backpatch strategy as `parseFlatBody` for control-flow PCs.

### Phase 4 (planned): True On-the-Fly Decode

Phase 4 will replace the lazy-decode path (re-parse to `[Instruction]` on each call) with a
`ip: UInt32` byte offset that advances through `rawBytes` directly. The `jumpTable` pre-built
in Phase 2.5 provides O(1) target resolution for `br`/`br_if`/`br_table`.

The remaining `[JumpEntry]` allocation will also be replaced with a fixed-size buffer, and
`CallFrame` will track a byte-offset `ip` instead of an instruction-array index.

Consider only when Phase 4 hardware execution is the target. Not needed for spectest validation.

---

## 6. Linear Memory

### Current Implementation

```swift
// WasmInterpreter.swift
var memory: [UInt8]
```

Dynamically allocated `[UInt8]`. `pico_stdlib` provides `posix_memalign`/`free`,
so this links correctly on the `pico-ble` target. Bounds checking is explicit.

```swift
// Example bounds check
let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
guard ea >= 0 && ea + 4 <= memory.count else { throw .memoryAccessOutOfBounds }
```

### Phase 5+ Issues

- `memory.grow`'s dynamic `realloc` requires care on RAM-constrained Pico
- Pure bare-metal (without `pico_stdlib`) requires replacement with a fixed-size buffer
- On 32-bit targets (Pico / RP2350), `Int` is 32-bit wide, requiring `UInt64` intermediate arithmetic for effective address calculation

```swift
// TODO: Embedded Phase 5 — 32-bit target overflow protection
let ea64 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset)
guard ea64 + UInt64(accessWidth) <= UInt64(memory.count) else { throw .memoryAccessOutOfBounds }
let ea = Int(ea64)
```

---

## 7. Host Function Design

wasm3 uses signature strings like `"v(ii)"` for runtime type checking.
This project registers host functions as closures and manages them in an array indexed by import order.

```swift
// WasmInterpreter.swift
typealias HostFunction = ([Value], [UInt8]) -> [Value]

enum HostImport {
    case function(String, String, HostFunction) // (module, name, body)
    case memory(String, String, UInt32)          // (module, name, pages)
}
```

`WasmInterpreter.init()` matches `hostImports` against import declarations in order
and stores them as a `[HostFunction]` array for O(1) index access.

Benefits:
- No `class` — Embedded Swift compatible
- Array instead of `Dictionary` (`[String: ...]`) avoids dynamic hash computation
- Module/function name comparison uses `elementsEqual` byte comparison (avoids `String ==`)

```swift
// Usage
let hostImports: [HostImport] = [
    .function("env", "gpio_put") { args, _ in
        // GPIO operation
        return []
    }
]
let interpreter = try WasmInterpreter(module: module, hostImports: hostImports)
```

---

## 8. Embedded Swift Constraints and Patterns

Embedded Swift has significantly fewer available features than regular Swift (macOS/iOS).

### 8.1 Unavailable Features

#### Existential Types (`any Protocol`)

Existentials — treating a protocol type as a value — are unavailable.

```swift
// NG: not available in Embedded Swift
func process(_ stream: any ByteStream) { ... }

// OK: use generic constraints instead
func process<S: ByteStream>(_ stream: inout S) { ... }
```

**Reason**: Existentials require protocol witness tables at runtime, which Embedded Swift lacks.

#### Reflection

Runtime type information via `Mirror` or `type(of:)` is unavailable.
Use enum associated values or generics for static type discrimination.

#### Foundation Framework

`import Foundation` is unavailable.

| Unavailable | Alternative |
|-------------|-------------|
| `Data` | `[UInt8]` / `UnsafeBufferPointer<UInt8>` |
| `String` (dynamic) | `StaticString` / byte arrays |
| `URL` | string literals / static constants |
| `Date` | `UInt64` (tick count etc.) |

#### Dynamic Memory Allocation

Dynamic operations on `Array<T>` such as `append` compile fine but require `malloc` at link time.
Environments with `pico_stdlib` work; pure bare-metal (no stdlib) results in a link error.

```
[Compile] .swift → .o  ← Array.append compiles (just embeds the malloc reference)
[Link]    .o → .elf   ← "undefined reference to '_malloc'" if malloc is not provided
```

Similarly, `indirect case` compiles but requires `malloc` at link time.

#### `String ==` Comparison

`String` equality involves Unicode normalization, whose tables are absent from Embedded Swift.
Compiles fine but causes a link error.

```swift
// NG: link error
module.exports.first { $0.name == "increment" }

// OK: byte-level comparison
module.exports.first { $0.nameBytes.elementsEqual("increment".utf8) }
```

#### Untyped Error (`any Error`)

`func f() throws` (untyped) uses `any Error` existential — avoid it.

### 8.2 Recommended Patterns

#### Generic Abstraction

```swift
protocol ByteStream {
    mutating func consume() throws(LEB128Error) -> UInt8
}

// S's concrete type is resolved at compile time → static dispatch
func decode<S: ByteStream>(from stream: inout S) throws(LEB128Error) -> UInt32 { ... }
```

#### Typed `throws` (Swift 6)

```swift
// OK: specify concrete error type
func consume() throws(LEB128Error) -> UInt8

// NG: uses any Error internally
func consume() throws -> UInt8
```

#### Zero-Copy Reads with `UnsafeBufferPointer`

```swift
struct BufferStream: ByteStream {
    let buffer: UnsafeBufferPointer<UInt8>
    var offset: Int

    mutating func consume() throws(LEB128Error) -> UInt8 {
        guard offset < buffer.count else { throw .insufficientBytes }
        defer { offset += 1 }
        return buffer[offset]
    }
}
```

#### Prefer Value Types (struct / enum)

Classes (reference types) cause heap allocation. Use value types that fit on the stack.

```swift
// NG: heap allocation
class WasmModule { ... }

// OK: stack allocation
struct WasmModule { ... }
```

---

## 9. Performance Optimization

### `@inlinable`: Required for Generic Functions

Embedded Swift cannot dynamically resolve protocol witness tables.
Generic functions must be specialised at compile time; `@inlinable` is required for calls across module boundaries.

```swift
@inlinable
public func decodeULEB128<T: FixedWidthInteger & UnsignedInteger, S: ByteStream>(
    from stream: inout S
) throws(LEB128Error) -> T { ... }
```

| | `@inlinable` | `@inline(__always)` |
|---|---|---|
| Purpose | Expose implementation across module boundary / allow specialisation | Force expansion at call site |
| Compiler discretion | Compiler decides whether to inline | Always inlined, no exceptions |
| Primary use | Generic functions / module boundaries | Very small functions in tight loops |

### Avoid Temporary Array Allocation in Hot Paths

In code called on every instruction (like the interpreter loop), intermediate array allocations accumulate heap pressure.

```swift
// NG: heap allocation on every br/return
let results = Array(valueStack.suffix(arity))
valueStack.removeSubrange(base...)
valueStack.append(contentsOf: results)

// OK: in-place slide, zero allocation
let src = valueStack.count - arity
for i in 0..<arity { valueStack[base + i] = valueStack[src + i] }
valueStack.removeSubrange((base + arity)...)
```

`pushFrame` has also been migrated to read arguments directly from `valueStack`
using `argCount: Int`, eliminating the `Array(valueStack.suffix(argCount))` intermediate copy.

### Cache Computed Properties Referenced in Hot Paths

```swift
// NG: scans imports on every call
var importedFunctionCount: Int {
    imports.reduce(0) { n, imp in if case .function = imp { return n + 1 }; return n }
}

// OK: computed once at init, stored as a let property
let importedFunctionCount: Int
```

`WasmModule` already computes `importedFunctionCount` at `init` time and stores it as `let`.

### Use `&<<` (Overflow Shift)

Regular left shift (`<<`) on signed integers traps on overflow.
Use `&<<` for intentional bit manipulation.

```swift
// NG: may trap on overflow
result |= T(byte & 0x7F) << shift

// OK: treats the bit pattern as-is
result |= T(byte & 0x7F) &<< shift
```

---

## 10. Memory Layout and Debugging

### `@frozen` Enums and Structs

Embedded Swift may require types to have a fixed memory layout.
Consider `@frozen` for publicly exposed types.

### Stack Size

The Pico's default stack size is a few KB. Avoid deep recursion and large stack variables.

### Debugging

`print` is unavailable (or routes to UART) in Embedded environments.

- Use target-specific output functions (UART writes etc.) for debug output
- Inlined functions do not appear in stack traces
- `assert` / `precondition` behaviour depends on the target's trap implementation

---

## 11. Comparison with wasm3

| Aspect | wasm3 (C) | This project (Swift) |
|--------|-----------|----------------------|
| Error type | `const char*` (NULL = success) | `enum WasmError: Error` (parser + interpreter unified) |
| Value storage | `union + u8 type` | `enum Value` with associated values |
| Validation | None (stub) | `#if !hasFeature(Embedded)`: full (`WasmValidator`) / Embedded: skipped |
| Host function registration | String signature `"v(ii)"` | `HostFunction` closure array (managed by import order) |
| Opcode dispatch | Threaded Code (function pointer + tail call) | `switch` on `Instruction` enum |
| Control flow representation | Nested function calls | Flat bytecode + jump offsets (Phase 1.5 complete) |
| Memory management | Manual (`malloc` / `realloc`) | `[UInt8]` (dynamic; fixed buffer planned for Phase 5) |
| Thread safety | None | Single-threaded `struct` (`actor` not supported in Embedded) |
| Ownership | Pointer-based pseudo-management (`IM3Runtime*`) | `struct` + value semantics |

---

## 12. Leveraging Swift's Strengths

### 12.1 Enum Exhaustiveness for 1:1 Spec Mapping

Swift `enum` can represent Wasm value types, instruction sets, and error kinds in a 1:1 correspondence with the spec.
`switch` exhaustiveness ensures the compiler catches unhandled cases when new instructions are added.

```swift
// The compiler catches missing cases when new instructions are added
// — in C, the bug would only surface at runtime
switch instruction {
case .i32Add: ...
case .i32Sub: ...
// ← compile error if a new instruction is forgotten
}
```

### 12.2 Structured Traps via Typed Throws

`throws(WasmError)` expresses which errors can occur directly in the function signature,
replacing wasm3's `M3Result = const char*` string comparison with type-safe alternatives.

### 12.3 Value Semantics for Explicit State

`struct` + `mutating` ensures state changes only occur through explicit `mutating` calls.
Implicit state mutation via shared references is structurally impossible.
Execution context snapshots are natural to write, aiding step-by-step debugging and testing.

### 12.4 Embedded Constraints Improve Architecture

Restrictions like "no class" and "no dynamic allocation" have a beneficial side effect of
encouraging better design:

- Choosing fixed-size buffers over heap allocation → predictable memory usage
- No shared references → clear ownership
- Restricted closure captures → host functions naturally trend toward static table designs

### 12.5 Debug-Build Safety

Swift traps on integer overflow and out-of-bounds array access in debug builds.
In C, these are undefined behaviour that can silently corrupt execution.
In the UART-only debug environment of the Pico, traps with a clear failure point are invaluable.

### 12.6 Generic Arithmetic Unification via Protocol + Generics (design proposal)

Wasm integer arithmetic (`i32`/`i64`) has identical semantics differing only in bit width.
Inspired by WasmKit's `RawUnsignedInteger` protocol, a `WasmInteger` protocol could unify implementations.

```swift
// Design proposal (not yet implemented)
protocol WasmInteger: FixedWidthInteger & UnsignedInteger {
    associatedtype Signed: FixedWidthInteger & SignedInteger
    init(bitPattern: Signed)
}
extension UInt32: WasmInteger { typealias Signed = Int32 }
extension UInt64: WasmInteger { typealias Signed = Int64 }
```

Currently i32/i64 are implemented separately in each `switch` case.
This will be considered if code size becomes a bottleneck on real Pico hardware.

---

## 13. Comparison with WasmKit

`ThirdParty/WasmKit/` contains a reference Swift Wasm Runtime for comparison.

### Where WasmKit Leverages Swift's Strengths

**Generic arithmetic unification via Protocol + Generics**

```swift
// Sources/WasmKit/Execution/Value.swift
protocol RawUnsignedInteger: FixedWidthInteger & UnsignedInteger { ... }
extension RawUnsignedInteger {
    func divS(_ other: Self) throws -> Self { ... }
}
```

**Thorough struct + Value Semantics**

`UntypedValue` and all Instruction Operands are unified as structs, consistent with this project's approach.

### Where WasmKit Intentionally Trades Type Safety for Performance

**Abandons enum exhaustiveness in hot paths**

```swift
// Instruction.swift leading comment
/// NOTE: This enum representation is just for modeling purposes.
/// The actual runtime representation can be different.
```

The execution loop uses an integer opcode `switch` for performance, losing compiler-enforced exhaustiveness.

**Does not use typed WasmValue in hot paths**

```swift
// UntypedValue.swift — stores i32/i64/f32/f64 all as UInt64
struct UntypedValue { let storage: UInt64 }
```

Since the opcode knows the type, a runtime type tag is unnecessary — a deliberate optimisation.

### Design Comparison

| Aspect | WasmKit | This project | Reason |
|--------|---------|--------------|--------|
| Instruction dispatch | Integer switch (performance) | `switch` on enum (safety/learning) | Leverage exhaustiveness during learning |
| Value representation | `UntypedValue` (UInt64) | `Value` enum (type-safe) | 1:1 spec mapping for comprehensibility |
| Errors | Plain `throws` | `throws(WasmError)` | Embedded Swift recommended pattern |

This project prioritises type safety over performance because the goal is "understanding the mechanics
and catching errors early", not raw throughput. If profiling identifies a bottleneck on Pico,
migration to an `UntypedValue`-style approach will be considered.

---

## 14. Evaluation of Swift for Embedded Environments

### Advantages That Remain in Embedded Swift

Embedded Swift only loses runtime features (String, dynamic Array, Swift Concurrency).
**All compile-time safety features are preserved.**

- Enum exhaustiveness → compiler catches missing instructions in a hard-to-debug environment
- Integer overflow is not undefined behaviour (`&+` expresses wrapping intent)
- Generics are zero-cost abstractions (monomorphised)
- `@_silgen_name` enables type-safe C function bridging to the Pico SDK

### Honest Drawbacks

| Aspect | C | Embedded Swift |
|--------|---|----------------|
| Flash usage | Minimal | Type metadata tends to increase binary size |
| Compile speed | Fast | Slow |
| Debug tooling | Mature GDB + OpenOCD | LLDB support still maturing |
| Library ecosystem | Vast | Near zero |
| Toolchain stability | Very stable | Relatively new |

Rust `no_std` is more mature than Embedded Swift (`heapless`, `defmt`, `probe-rs`, etc.).
In terms of raw Embedded efficiency: `C > Rust no_std > Embedded Swift`.

### Why This Project Chose Embedded Swift

- **Code sharing**: Parser, validator, and interpreter core is identical source for macOS and Pico
- **Phase 6 (iOS integration)**: The iOS app that transfers Wasm binaries via BLE is also written in Swift. With Swift on both ends of iOS ↔ Pico, sharing error types and protocol definitions becomes possible
- **Learning goal**: "Deepen understanding of Embedded Swift" is one of the project objectives

---

## 15. Related Documents

| Document | Content |
|----------|---------|
| `Documentations/PHASE2_WASM3.md` | wasm3 source investigation and Swift applicability |
| `Documentations/PHASE3_PARSER.md` | Binary parser implementation plan |
| `Documentations/PHASE4_INTERPRETER.md` | Interpreter implementation plan |
| `Documentations/WASM_SPEC.md` | Wasm specification reference |
| `Documentations/OVERVIEW.md` | Overall project policy and incremental development approach |
