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
│  │  DataSegment[]                           │   │
│  └──────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────┐   │
│  │           HostFunctionTable              │   │
│  └──────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────┐   │
│  │               WasmArena                  │   │
│  │  Bump-pointer arena (96 KB static buf)   │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

| Component | Role |
|-----------|------|
| `WasmParser` | Converts Wasm binary to `WasmModule` |
| `WasmValidator` | Validates module type consistency (enabled only via `#if !hasFeature(Embedded)`) |
| `WasmInterpreter` | Executes the module (Stack Machine). Tracks `data.drop` / `elem.drop` state via `droppedDataSegments: UInt64` / `droppedElementSegments: UInt64` bitmaps. Exposes execution statistics: `executedInstructions: UInt64`, `peakValueStackDepth: Int`, `peakCallStackDepth: Int`, and `resetStats()` |
| `WasmModule` | Parsed Wasm module (functions, memory, globals). `DataSegment.offset: Int32?` (nil = passive, non-nil = active write offset) |
| `WasmArena` | Bump-pointer arena allocator. Caller provides an `inout WasmArena` to `WasmInterpreter.init(module:arena:hostImports:)`. On Embedded the backing buffer is a 96 KB C static array (`wasm_arena.c`); on macOS a single heap allocation made once at `init`. `reset()` reclaims all allocations in O(1). |
| Linear Memory | `var memory: UnsafeMutableBufferPointer<UInt8>` (held by the interpreter; arena-backed). `var memoryCapacity: Int` tracks the pre-allocated ceiling for `memory.grow`. Responsible for bounds checking. |
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
Swift represents parse-time errors and runtime traps as two separate type-safe `Error` enums,
`ParserError` and `InterpreterError`, rather than one unified type. The two are genuinely
distinct responsibilities — binary-format decode errors vs. runtime trap errors — used by
different subsystems (`WasmParser` / `WasmValidator` vs. `WasmInterpreter` /
`WasmInterpreterEmbedded` / `WasmInteger`).

```swift
// ParserError.swift: enum ParserError
enum ParserError: Error, Equatable, Sendable {
    case invalidMagic
    case unexpectedEnd
    case invalidValueType(UInt8)
    case invalidInstruction(UInt8)
    case leb128Error(LEB128Error)
    // ... other section/format decode errors

    // WasmValidator (macOS-only static type checker) detects a type
    // violation while statically checking the module before execution
    case typeMismatch

    // a section's item count exceeds the fixed-buffer capacity defined in
    // WasmLimits while parsing
    case resourceLimitExceeded
}
```

```swift
// InterpreterError.swift: enum InterpreterError
enum InterpreterError: Error, Equatable, Sendable {
    case stackUnderflow
    case stackOverflow   // value stack, call stack, or label stack exceeded the fixed-size limit
    case memoryAccessOutOfBounds
    case divisionByZero
    case unreachableReached
    case indirectCallTypeMismatch
    // ... other runtime errors

    // the interpreter decodes opcodes/operands on the fly from rawBytes
    // during dispatch (post flat-bytecode migration) — the same
    // decode-style failures the parser can hit, but discovered at
    // execution time instead of parse time
    case unexpectedEnd
    case invalidValueType(UInt8)
    case invalidInstruction(UInt8)

    // a runtime stack-type trap: the interpreter pops a value of the
    // wrong type off the value stack during execution
    case typeMismatch

    // a table/element-segment count exceeds the runtime's fixed capacity
    // during module instantiation — a separate limit enforced at a later
    // phase than parsing
    case resourceLimitExceeded
}
```

Five case names — `unexpectedEnd`, `invalidValueType(UInt8)`, `invalidInstruction(UInt8)`,
`typeMismatch`, `resourceLimitExceeded` — are intentionally duplicated across both types.
This isn't accidental overlap: each condition genuinely occurs independently in both phases.
The interpreter decodes bytecode on the fly at runtime (a consequence of the Phase 1.5 flat-bytecode
migration and the Phase 4 on-the-fly decoder — see Section 5), so it can hit the same decode-style
errors the parser hits, just later. `WasmValidator` throws `.typeMismatch` at validate time as a
static check, while the interpreter throws its own `.typeMismatch` as a runtime stack-type trap —
same name, different phase, same underlying meaning ("a value of the wrong type showed up").

Typed throws (`throws(ParserError)` / `throws(InterpreterError)`) are used throughout to avoid
`any Error` existentials. This also satisfies the Embedded Swift constraint against existential types.

---

## 4. Validation Policy

wasm3 has no validation phase; type checking is unimplemented. This project uses `#if !hasFeature(Embedded)`.

### Non-Embedded Build (macOS development / debug)

**Full validation enabled.**

- Function signature type consistency checking
- Per-instruction stack type checking (type stack tracking)
- Invalid Wasm detected as `ParserError` before execution

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
    func validate() throws(ParserError) { ... }
}
#endif
```

Goal: catch bad Wasm binaries and implementation bugs early during development.

### Embedded Build (Pico)

**Type validation skipped; resource-limit checks always run.**

- Magic number / version check (always performed in the parser)
- `WasmLimits` section-count checks (always performed in the parser — throws `ParserError.resourceLimitExceeded` if any section's item count exceeds the fixed-buffer limits defined in `WasmLimits`; runtime stack limits `maxValueStackDepth`, `maxCallDepth`, `maxLabelDepth` are enforced by `precondition` in Embedded builds)
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
case block(BlockType, brArity: Int, paramCount: Int, endPc: Int)
case loop(BlockType, brArity: Int, startPc: Int)
case ifElse(BlockType, brArity: Int, paramCount: Int, elsePc: Int, endPc: Int)
case blockEnd                    // end-of-body marker for block/loop/if
case jump(Int)                   // unconditional jump to PC (skips else body)
```

All instructions are laid out in a flat array; block/loop/if carry their jump target PC directly.
`brArity` and `paramCount` are pre-computed at parse time by `blockArityForBlock()` /
`loopBrArityFromBlockType()` in `WasmParser.swift`, eliminating all `module.types` lookups from
the interpreter hot path. `BlockType` is retained in the cases for use by the macOS validator.
The same flat-bytecode approach is used by CPython bytecode and JavaScriptCore, making it educationally valuable.

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

`WasmModule.rawBytes` holds the original Wasm binary. In the Phase 2 lazy-decode path, when
the interpreter called a function it constructed a sub-parser over the stored byte range and called
`parseFlatBody()` to obtain a `[Instruction]` array — eliminating the per-function allocation at
load time and replacing it with a per-call allocation. Phase 4 (`WasmInterpreterEmbedded.swift`)
removes this per-call allocation entirely by decoding opcodes on-the-fly directly from `rawBytes`.

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

**Note on iterative parsing:** Both `parseFlatBody` and `parseFlatBodyTracked` are iterative,
using an explicit `var pending: [PendingBlock]` stack. The original recursive implementations
caused native stack overflow (SIGBUS / signal 10) on deeply nested Wasm binaries and certain
crashes on the Pico's 4 KB default stack. Both functions were rewritten iteratively in commit
`22f7571`. `parseFlatBodyTracked` extends `PendingBlock` with `jumpEntryIdx` and
`opcodeByteOffset` fields for jump-table backpatching.

### Phase 4 (implemented): True On-the-Fly Decode

`WasmInterpreterEmbedded.swift` (Embedded-only, ~2700 lines) replaces the lazy-decode path
with a true on-the-fly decoder.  The per-call `[Instruction]` array is eliminated; opcodes are
decoded directly from `module.rawBytes` as execution proceeds.

#### `BinaryReader`

A zero-allocation byte reader over `UnsafeBufferPointer<UInt8>`.  Handles LEB128 (unsigned and
signed), IEEE 754 floats, and block type bytes inline.  Used inside `dispatchEmbedded()` as a
local variable — there is no shared `BinaryReader` state per frame.

```swift
struct BinaryReader {
    let buffer: UnsafeBufferPointer<UInt8>
    var offset: Int                         // current read position within buffer

    @inline(__always)
    mutating func readByte() throws(InterpreterError) -> UInt8 { ... }
    mutating func readU32() throws(InterpreterError) -> UInt32 { ... }  // unsigned LEB128
    mutating func readS32() throws(InterpreterError) -> Int32  { ... }  // signed LEB128
    mutating func readS64() throws(InterpreterError) -> Int64  { ... }  // signed LEB128
    mutating func readF32() throws(InterpreterError) -> Float  { ... }  // 4-byte LE IEEE 754
    mutating func readF64() throws(InterpreterError) -> Double { ... }  // 8-byte LE IEEE 754
}
```

#### `EmbeddedFrame`

Per-call frame used by `runIterativeEmbedded()`.  Tracks a byte-offset `ip` instead of an
instruction-array index.

```swift
struct EmbeddedFrame {
    var ip: UInt32       // absolute byte offset in module.rawBytes
    var jumpCursor: Int  // monotonic index into FunctionHandle.jumpTable
    let handleIdx: Int   // index into module.code
    let localBase: Int   // index of first local/param on valueStack
    let localCount: Int  // params + declared locals; depth of valueStack at body start
    let resultCount: Int // number of return values
    var labels: LabelStack  // unified on both platforms; LabelStack uses [Label] internally on macOS
}
```

`LabelStack` encapsulates the platform difference: Embedded uses a 32-element tuple (no malloc),
macOS uses `[Label]` (heap) to keep `EmbeddedFrame` small enough that `CallStack` (64 frames)
fits on the call stack. The single `#if hasFeature(Embedded)` lives inside `LabelStack` itself.
Call sites in `dispatchEmbedded` / `handleEmbeddedBranch` / `pushEmbeddedFrame` are unconditional.

Local variables (params + declared locals) are stored on the shared `valueStack` at indices
`localBase ..< localBase + localCount`.  This eliminates per-frame heap allocation for locals.

#### `runIterativeEmbedded()`

The Embedded execution entry point.  Replaces the Phase 3 lazy-decode path.

Mutable interpreter state (`memory`, `globals`, `tables`, `droppedDataSegments`,
`droppedElementSegments`) is extracted into local variables at the top of this function and
written back before returning.  All mutations go through those local variables — `self` is
not accessed again until the `defer` write-back.  This avoids overlapping-access (exclusivity)
violations that arise when both a closure capturing `self` and an `inout` parameter pointing
into `self` are live simultaneously.

#### `dispatchEmbedded()`

Non-mutating method that takes mutable state as `inout` arguments.  Executes one instruction
at the current `ip` of the top frame and advances it.

The method creates a local `BinaryReader` positioned at the current `ip`, reads the opcode
byte, then falls into a `switch` that handles all opcodes (0x00–0xFC).  Immediates are decoded
inline from the reader without any temporary allocation.

#### `jumpCursorForIp()`

Binary search that returns the first `jumpTable` index where `entry.instrOffset >= ip`.
Called when `ip` changes non-sequentially (branch taken, function return, etc.) to
re-synchronise the monotonic `jumpCursor`.

In the sequential forward path, `jumpCursor` advances by 1 each time a `block` / `loop` / `if`
opcode is encountered (pre-order invariant of the jump table).  The binary search is only needed
after non-sequential jumps.

```swift
private func jumpCursorForIp(_ ip: UInt32, in jumpTable: [JumpEntry]) -> Int {
    // standard binary search: first index where jumpTable[i].instrOffset >= ip
}
```

#### Phase 4 / Phase 5 fixed-buffer status

- `LabelStack` (32 entries): **complete** — both macOS and Embedded use `LabelStack` for `EmbeddedFrame.labels`. Embedded uses a 32-element tuple internally; macOS uses `[Label]` (heap) to keep `EmbeddedFrame` small. The `#if` is encapsulated inside `LabelStack`; no call-site branching required.
- `ValueStack` (256 entries): **complete** — replaces `valueStack: [Value]` in Embedded builds.
- `CallStack` (64 entries): **complete** — replaces `frames: [EmbeddedFrame]` in Embedded builds.
- `WasmModule` section fields: **partially unified across platforms**. Of the 11 `Fixed*_X` fixed-buffer types backing `types`, `functions`, `imports`, `exports`, `globals`, `tables`, `memories`, `elements`, `data`, and `importedFunctionTypeIndices`, 6 now use a single `#if`-free tuple implementation shared by macOS and Embedded builds: `Fixed64_UInt32`, `Fixed32_GlobalDef`, `Fixed32_UInt32`, `Fixed4_TableType`, `Fixed1_MemoryType`, `FixedLocals_ValueType`. Their element types are bitwise-copyable (no heap-array fields), which made unification safe. The remaining 5 — `Fixed64_FunctionType`, `Fixed32_Import`, `Fixed32_Export`, `Fixed16_ElementSegment`, `Fixed16_DataSegment` — still keep a per-platform `#if hasFeature(Embedded)` (Embedded tuple vs. macOS `[T]`), because their element types hold heap-array fields (e.g. `name: [UInt8]`, `params: [ValueType]`, `bytes: [UInt8]`). Unifying those 5 was attempted and reverted: the resulting growth in `WasmModule`'s size was, on its own, enough to overflow Swift Testing's 512 KB worker-thread stack inside `_runIterativeEmbeddedCore` / `dispatchEmbedded` (reproduced as a SIGBUS in `swift test`). See `Documentations/hasFeature削除計画.md` §5 for the full investigation; unification of these 5 types is deferred until the `dispatchEmbedded` stack-frame-size problem (Phase 3, §6.2 of that document) is resolved. `rawBytes: [UInt8]` remains dynamic in both builds (marked `// TODO: Embedded Phase 5`).
- `FixedLocals_ValueType` (32 entries): **complete** — replaces `FunctionHandle.locals: [ValueType]`. Throws `.resourceLimitExceeded` at parse time if locals count exceeds `WasmLimits.maxLocalsPerFunction`.
- `FixedJumpTable_JumpEntry` (64 entries): **complete** — replaces `FunctionHandle.jumpTable: [JumpEntry]`. Throws `.resourceLimitExceeded` at parse time if jump table overflows `WasmLimits.maxJumpEntriesPerFunction`.
- `Fixed64_FunctionHandle` (64 entries): **complete (Phase 5)** — replaces `code: [FunctionHandle]` on `WasmModule`. Embedded: 64-slot tuple; macOS: `[FunctionHandle]` (heap). The `#if` is encapsulated inside `Fixed64_FunctionHandle`; no call-site branching required.
- `Fixed4_HostImport`: **complete (Phase 5)** — stack-allocated 4-slot container for `HostImport` values. Passed to `WasmInterpreter.init<S: Sequence>(module:hostImports:S)` on Embedded to avoid `[HostImport]` heap allocation.
- `Fixed32_HostFunctionPtr`: **complete (Phase 5)** — Embedded-only internal buffer holding up to 32 `HostFunctionPtr` values during `WasmInterpreter.init`. Eliminates `[HostFunctionPtr]` heap allocation. Not part of the public API.
- `FlatTableStorage`: **defined, not yet connected** — `tables: [[Value]]` replacement is tracked as `// TODO: Embedded Phase 5`.

The `WasmLimits` enum in `WasmModule.swift` includes six runtime constants used by the fixed buffers:

```swift
static let maxImports: Int             = 32   // max number of imports
static let maxTableElements: Int       = 256  // max elements per table
static let maxValueStackDepth: Int     = 256  // max operand stack depth
static let maxCallDepth: Int           = 64   // max call stack depth (call frames)
static let maxLabelDepth: Int          = 32   // max nested block/loop/if depth per frame
static let maxLocalsPerFunction: Int   = 32   // max declared locals per function body
static let maxJumpEntriesPerFunction: Int = 64 // max block/loop/if instructions per function body
```

Overflow is currently caught by `precondition` in runtime stacks (traps on violation) and by
`throws(.resourceLimitExceeded)` in the parser for locals and jump-table limits.
`InterpreterError.stackOverflow` is defined and reserved for future explicit `throw` paths on runtime
stack overflows. The macOS execution path retains dynamic `[Value]` / `[EmbeddedFrame]` storage
with `// TODO: Embedded Phase 5` markers.

### Phase 5: Pointer-Based Module Access (implemented, Embedded builds)

`WasmModule` is approximately 5,288 bytes after all fixed-buffer conversions. When
`dispatchEmbedded()` receives a `module: WasmModule` value parameter, the compiler
materialises a full copy of that struct on the native stack. Across the combined call
chain `_runIterativeEmbeddedCore → dispatchEmbedded → pushEmbeddedFrame → handleEmbeddedBranch`,
this copy accounts for roughly 18 KB of the peak native stack requirement.

**Solution**: the five interpreter functions that access module fields now receive
`moduleRef: UnsafePointer<WasmModule>` instead of a value copy. Field accesses via
`moduleRef.pointee.xxx` compile to direct loads from the BSS global address — no
`WasmModule` copy is materialised on the stack.

Functions that carry the `moduleRef: UnsafePointer<WasmModule>` parameter:
- `dispatchEmbedded`
- `embeddedBlockArity`
- `embeddedLoopBrArity`
- `pushEmbeddedFrame`
- `handleEmbeddedBranch`

`_runIterativeEmbeddedCore` (the caller) passes `self.moduleRef`, which is a stored
property on `WasmInterpreter` pointing to the BSS global `_embeddedModule`.

```swift
// WasmInterpreterEmbedded.swift — BSS global, filled at load time
#if hasFeature(Embedded)
nonisolated(unsafe) var _embeddedModule = WasmModule.empty
#endif
```

On the macOS path, where native stack depth is not a constraint, `_runIterativeEmbeddedCore`
takes a value copy as `var localModule = self.module` and passes `&localModule` to the same
functions. The function signatures are identical across both paths; the only difference is
what the pointer points to.

**Why a pointer and not `inout`?** Swift's `inout` is semantically an in-out borrow with
exclusivity enforcement — passing `&self.module` as `inout` while `self` is also accessed by
other parts of the call would trigger an exclusivity violation. `UnsafePointer` is a raw
address with no exclusivity tracking, which is safe here because `_embeddedModule` is a
module-level global that is not written to during interpreter execution.

**Why not a value parameter?** Swift's ABI does not guarantee that a large struct passed
by value is placed in-place on the callee's stack without copying. The pointer pattern is
the only reliable way to guarantee zero struct copies along the call chain in Embedded Swift.

---

## 6. Linear Memory

### Current Implementation

```swift
// WasmInterpreter.swift
var memory: UnsafeMutableBufferPointer<UInt8>
var memoryCapacity: Int
```

Arena-backed via `WasmArena`. The interpreter requires `arena: inout WasmArena` at init time.
`WasmInterpreter.init` pre-allocates the full maximum memory capacity from the arena once and
stores the ceiling in `memoryCapacity`. The active `memory` view starts at the initial page count;
`memory.grow` (opcode 0x40) extends `memory.count` up to `memoryCapacity` without any new
allocation. On Embedded, the backing store is the 96 KB C static array (`wasm_arena.c`) — zero heap usage.

```swift
// WasmInterpreter.init — linear memory allocation from arena
guard let slice = arena.allocate(count: capacityByteCount, alignment: 4) else {
    throw .resourceLimitExceeded
}
slice.initialize(repeating: 0)
self.memory = UnsafeMutableBufferPointer(start: slice.baseAddress!, count: initialByteCount)
self.memoryCapacity = capacityByteCount
```

Bounds checking is explicit on all 23 load/store instruction handlers:

```swift
// Bounds check — all 23 load/store handlers (Phase 3 complete)
let ea = UInt64(UInt32(bitPattern: addr)) + UInt64(offset)
guard ea + UInt64(N) <= UInt64(memory.count) else { throw .memoryAccessOutOfBounds }
let eaInt = Int(ea)
```

`UInt64` intermediate arithmetic prevents silent wraparound on 32-bit targets (RP2350) where
`Int` is 32 bits wide. This fix is applied to all 23 load/store instruction handlers.

`memory.grow` (0x40) and `table.grow` (FC 0x15) also operate in `UInt64` throughout:
the `delta` operand is reinterpreted as `UInt32(bitPattern: delta)` first, then compared
and accumulated in `UInt64` before any conversion to `Int`. This prevents an overflow trap
on RP2350 when an unsigned delta value exceeds `Int32.max`.

### Remaining Issues

- Bulk memory ops (`memoryFill` / `memoryCopy` / `memoryInit`) still use the old `Int &+` pattern
  in some paths and are marked `[macOS-phase-OK, Embedded-TODO]` in source

---

## 7. Host Function Design

wasm3 uses signature strings like `"v(ii)"` for runtime type checking.
This project registers host functions in an array indexed by import order, with the
representation differing between macOS and Embedded builds.

### `HostImport` Enum

Module and field names are `StaticString` (compile-time constants) in both builds,
so that no heap allocation is required for string storage in either environment.

```swift
// WasmInterpreter.swift
enum HostImport {
  #if hasFeature(Embedded)
    case function(StaticString, StaticString, HostFunctionPtr)  // (module, name, body)
    case memory(StaticString, StaticString, UInt32)              // (module, name, pages)
  #else
    case function(StaticString, StaticString, HostFunction)      // (module, name, body)
    case memory(StaticString, StaticString, UInt32)              // (module, name, pages)
    case functionDyn([UInt8], [UInt8], HostFunction)             // (moduleBytes, nameBytes, body)
    case memoryDyn([UInt8], [UInt8], UInt32)                     // (moduleBytes, nameBytes, pages)
  #endif
}
```

The `functionDyn` / `memoryDyn` variants are available only in non-Embedded builds and exist
for test infrastructure that constructs module/name byte arrays at runtime (e.g., spectest).
Production call sites always use the `StaticString` variants.

### `WasmInterpreter.init` — Generic over Sequence

The initialiser is generic over any `Sequence` of `HostImport`, so callers can pass
either `[HostImport]` (macOS, heap-allocated) or `Fixed4_HostImport` (Embedded, stack-allocated)
without changing the call site. All overloads now require `arena: inout WasmArena` since
linear memory is allocated from the arena at init time:

```swift
// Convenience: no host imports
init(module: WasmModule, arena: inout WasmArena) throws(InterpreterError)

// Primary generic initialiser — accepts [HostImport] or Fixed4_HostImport
init<S: Sequence>(module: WasmModule, arena: inout WasmArena, hostImports: S) throws(InterpreterError)
where S.Element == HostImport
```

### `Fixed4_HostImport` — Stack-Allocated Import Container

`Fixed4_HostImport` is a `struct` that holds up to 4 `HostImport` values in optional
storage (no backing array), conforming to `Sequence`.  It avoids the heap allocation
that `[HostImport]` would require on Embedded.

```swift
// WasmInterpreter.swift (both builds)
struct Fixed4_HostImport: Sequence {
    mutating func append(_ hi: HostImport)
    func makeIterator() -> Iterator
}
```

```swift
// Usage (Embedded — no heap allocation)
var hostImports = Fixed4_HostImport()
hostImports.append(.function("env", "gpio_put", hostGpioPut))
hostImports.append(.memory("env", "memory", 1))
let interpreter = try WasmInterpreter(module: module, hostImports: hostImports)
```

```swift
// Usage (macOS — [HostImport] is also accepted)
let hostImports: [HostImport] = [
    .function("env", "gpio_put") { args, _ in return [] }
]
let interpreter = try WasmInterpreter(module: module, hostImports: hostImports)
```

### `callExport` — StaticString Overload

Two overloads exist for calling exported functions by name:

```swift
// Zero-copy StaticString name matching — preferred on Embedded
mutating func callExport(_ name: StaticString, args: [Value]) throws(InterpreterError) -> [Value]

// Legacy [UInt8] byte-array overload — for test infrastructure
mutating func callExport(nameBytes: [UInt8], args: [Value]) throws(InterpreterError) -> [Value]
```

The `StaticString` overload uses `withUTF8Buffer` for zero-copy byte comparison against
`exp.nameBytes` and requires no heap allocation at the call site.  String literals are
accepted directly: `try interp.callExport("add", args: [.i32(3), .i32(4)])`.

### macOS Build

Host functions are registered as Swift closures.

```swift
// WasmInterpreter.swift (non-Embedded)
typealias HostFunction = ([Value], [UInt8]) -> [Value]
```

The macOS `[Value]` return type requires heap allocation for multi-value returns, but
this is acceptable in the development/debug phase.

### Embedded Build

Embedded Swift cannot heap-allocate closures.  Host functions are instead registered as
`@convention(c)` function pointers (no captures) via `#if hasFeature(Embedded)`.
Arguments are passed through `withUnsafeTemporaryAllocation` + `UnsafeRawPointer`, avoiding any
heap allocation at the call site.

```swift
// WasmInterpreter.swift (Embedded)
#if hasFeature(Embedded)
typealias HostFunctionPtr =
    @convention(c) (
        UnsafeRawPointer?,    // args pointer (raw packed Value bytes)
        Int32,                // args count
        UnsafeMutablePointer<UInt8>?,  // results buffer
        Int32,                // results count
        UnsafeMutableRawPointer?       // context (unused)
    ) -> Void
#endif
```

```swift
// Examples/RaspberryPiPicoW-BLE/Embedded/Main.swift
@_cdecl("hostBlink")
func hostBlink(
    _ args: UnsafeRawPointer?, _ argsCount: Int32,
    _ memory: UnsafeMutablePointer<UInt8>?, _ memorySize: Int32,
    _ results: UnsafeMutableRawPointer?
) {
    // GPIO blink implementation — no closure capture
}
```

### `Fixed32_HostFunctionPtr` — Internal Embedded-Only Buffer

`Fixed32_HostFunctionPtr` is a private `struct` used internally by `WasmInterpreter.init`
in Embedded builds to hold up to 32 `HostFunctionPtr` values without heap allocation.
It replaces the `[HostFunctionPtr]` array that would otherwise be required.  This type
is an implementation detail of the initialiser and is not exposed in the public API.

```swift
// WasmInterpreter.swift (Embedded only, internal)
#if hasFeature(Embedded)
struct Fixed32_HostFunctionPtr {
    mutating func append(_ fn: HostFunctionPtr)
    subscript(index: Int) -> HostFunctionPtr { get }
    var count: Int { get }
}
#endif
```

### Common Benefits

- No `class` — Embedded Swift compatible
- `Fixed4_HostImport` avoids `[HostImport]` heap allocation when registering imports
- `Fixed32_HostFunctionPtr` avoids `[HostFunctionPtr]` heap allocation during `init`
- `callExport(_ name: StaticString, ...)` avoids `[UInt8]` heap allocation at call sites
- Module/function name comparison uses `withUTF8Buffer` + `elementsEqual` (avoids `String ==`)

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

### Stack Size and Custom Linker Script

#### The Problem: Default 4 KB Core 0 Stack

The default pico-sdk linker script places the Core 0 stack in `SCRATCH_Y` (4 KB at
`0x20041000`). The WebAssembly interpreter's peak native call chain is:

```
_runIterativeEmbeddedCore → dispatchEmbedded → pushEmbeddedFrame → handleEmbeddedBranch
```

Even after the Phase 5 pointer-based module access optimization (which eliminated the
~18 KB `WasmModule` copy), the peak stack requirement is approximately 28,400 bytes —
more than 7× the default 4 KB limit. Exceeding the stack boundary causes a HardFault
on RP2040. Therefore two complementary measures are required: keep individual frame sizes
small (the pointer pattern) and reserve enough total stack space (the linker script).

#### The Solution: `memmap_wasm.ld`

A custom linker script at `Examples/RaspberryPiPicoW-BLE/Embedded/memmap_wasm.ld`
moves the Core 0 stack from `SCRATCH_Y` into the top of main RAM, reserving 64 KB:

```ld
/* Force the stack region to the top 64 KB of main RAM */
. = ORIGIN(RAM) + LENGTH(RAM) - 65536;
.stack_dummy (NOLOAD): { KEEP(*(.stack*)) } > RAM

__StackTop    = ORIGIN(RAM) + LENGTH(RAM);    /* 0x20040000 */
__StackBottom = __StackTop - SIZEOF(.stack_dummy); /* 0x20030000 */
__HeapLimit   = __StackBottom;
ASSERT(__StackBottom >= __bss_end__, "Stack overflows into BSS — increase RAM or reduce stack size")
```

Activated in `CMakeLists.txt`:

```cmake
pico_set_linker_script(pico-ble ${CMAKE_CURRENT_LIST_DIR}/memmap_wasm.ld)

# 64 KB Core 0 stack — matches the reserved region in memmap_wasm.ld.
# PICO_STACK_SIZE is defined on pico-ble (not pico_crt0) because pico_crt0 is an
# INTERFACE library; crt0.S compiles with the consuming target's definitions.
target_compile_definitions(pico-ble PRIVATE PICO_STACK_SIZE=65536)
```

#### RP2040 RAM Layout After `memmap_wasm.ld`

RP2040 has 256 KB of SRAM at `0x20000000`.

```
Address        Region                        Size / Notes
0x20000000     .data / .bss / static bufs    ~159 KB (includes 96 KB WasmArena backing store)
                                             BSS ends at ~0x200277C8
0x200277C8     heap (grows upward)           ~34 KB available for malloc (BLE stack etc.)
0x20030000     Core 0 stack bottom (SP_min)  \
               stack grows downward           > 64 KB reserved
0x20040000     Core 0 stack top (initial SP) /   [= end of RAM]
0x20040000     SCRATCH_X (4 KB)              freed from stack use; available for future use
0x20041000     SCRATCH_Y (4 KB)              freed from stack use; available for future use
```

Verified ELF symbols from a linked binary:

| Symbol | Value | Meaning |
|--------|-------|---------|
| `StackSize` | 0x10000 (65,536) | Stack reservation in bytes |
| `__StackTop` | 0x20040000 | Initial SP; top of Core 0 stack |
| `__StackBottom` | 0x20030000 | Minimum SP; stack grows down to here |
| `__bss_end__` | 0x200277C8 | End of BSS; well clear of stack bottom |
| `__HeapLimit` | 0x20030000 | Heap ceiling; heap cannot grow into stack |

The linker `ASSERT` guards against BSS growing so large that it would collide with
the reserved stack region.

#### Complementary Optimization: Pointer-Based Module Access

Even with 64 KB of stack headroom, keeping individual frame sizes small extends the
maximum call depth. The `moduleRef: UnsafePointer<WasmModule>` pattern (see Section 5,
Phase 5) eliminates the ~18 KB `WasmModule` copy from `dispatchEmbedded`'s frame. Both
techniques are required: the linker script provides the headroom; the pointer pattern
keeps peak usage well within it.

### Debugging

`print` is unavailable (or routes to UART) in Embedded environments.

- Use target-specific output functions (UART writes etc.) for debug output
- Inlined functions do not appear in stack traces
- `assert` / `precondition` behaviour depends on the target's trap implementation

---

## 11. Comparison with wasm3

| Aspect | wasm3 (C) | This project (Swift) |
|--------|-----------|----------------------|
| Error type | `const char*` (NULL = success) | `enum ParserError: Error` (parser) / `enum InterpreterError: Error` (interpreter) — split types, 5 case names intentionally duplicated (see Section 3.4) |
| Value storage | `union + u8 type` | `enum Value` with associated values |
| Validation | None (stub) | `#if !hasFeature(Embedded)`: full (`WasmValidator`) / Embedded: skipped |
| Host function registration | String signature `"v(ii)"` | macOS: closure array; Embedded: `@convention(c)` function pointer array |
| Opcode dispatch | Threaded Code (function pointer + tail call) | macOS: `switch` on `Instruction` enum; Embedded: `switch` on raw opcode byte decoded on-the-fly from `rawBytes` |
| Code representation | Compiled threaded code | macOS: flat `[Instruction]`; Embedded: `FunctionHandle` (byte range + pre-computed `[JumpEntry]`) |
| Control flow representation | Nested function calls | Flat bytecode + jump offsets (Phase 1.5); Embedded uses byte-offset `ip` + monotonic `jumpCursor` |
| Memory management | Manual (`malloc` / `realloc`) | `WasmArena` bump-pointer allocator; linear memory is `UnsafeMutableBufferPointer<UInt8>` backed by a 96 KB C static array on Embedded (zero heap) |
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

`throws(ParserError)` / `throws(InterpreterError)` express which errors can occur directly in
the function signature, replacing wasm3's `M3Result = const char*` string comparison with
type-safe alternatives.

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

### 12.6 Generic Arithmetic Unification via `WasmInteger` Protocol (implemented)

Wasm integer arithmetic (`i32`/`i64`) has identical semantics differing only in bit width.
Inspired by WasmKit's `RawUnsignedInteger` protocol, the `WasmInteger` protocol unifies i32/i64
arithmetic, comparison, and bit operations in the on-the-fly interpreter (`WasmInterpreterEmbedded.swift`).

```swift
// Implemented in WasmModule.swift
protocol WasmInteger: FixedWidthInteger & UnsignedInteger {
    associatedtype Signed: FixedWidthInteger & SignedInteger
    init(bitPattern: Signed)
    func toSigned() -> Signed
    static func fromSigned(_ s: Signed) -> Self
    static func fromValue(_ v: Value) throws(InterpreterError) -> Self
    func toValue() -> Value
}
extension UInt32: WasmInteger { typealias Signed = Int32 }
extension UInt64: WasmInteger { typealias Signed = Int64 }
```

`fromValue` and `toValue` bridge between unsigned bit-pattern types and the `Value` enum
(which stores i32/i64 as their signed counterparts following Wasm convention).

14 generic helper functions in `WasmInterpreterEmbedded.swift` use the protocol:
`intBinaryOp`, `intCmpOp`, `intSignedCmpOp`, `intEqzOp`, `intCountOp`,
`intDivS`, `intDivU`, `intRemS`, `intRemU`, `intShl`, `intShrS`, `intShrU`, `intRotl`, `intRotr`.

All helpers carry `@inline(__always)` and use non-capturing closures, so Embedded Swift
monomorphises them into zero-allocation, zero-overhead call sites. 44 i32/i64 opcode case
bodies in `dispatchEmbedded()` now delegate to these helpers; the `switch` cases themselves
are retained for compiler exhaustiveness checking.

`@inlinable` is not required because all call sites are within the same module.
If the module is ever split into separate targets, `@inlinable` will need to be added to all
conformances and the helper functions.

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
| Errors | Plain `throws` | `throws(ParserError)` / `throws(InterpreterError)` | Embedded Swift recommended pattern |

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
