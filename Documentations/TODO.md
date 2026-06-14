# TODO — Unimplemented Items

---

## Phase 1 — Embedded Swift Development Environment

The build toolchain setup, Embedded Swift compilation, and BLE firmware linking have all been verified (`make compile` / `make build` pass).
The only remaining item is hardware verification.

- [x] **Verify log output over UART**

  Use Pico SDK's `stdio_init_all()` + `printf()` to output a string such as `"Hello from Embedded Swift\n"` via UART (USB CDC) to a host PC.
  Receiving it in a serial monitor (`screen` / `minicom` etc.) confirms success.
  This would be the first proof that Embedded Swift code is actually executing on the Pico.

---

## Phase 2 — Wasm Binary Parser (for Embedded)

The macOS-phase parser is complete. The following work is needed when porting to an Embedded Swift environment (Pico).
The goal is to eliminate dynamic allocation (`Array<T>`) and replace it with fixed-size data structures.

- [x] **Zero-copy the Code Section**

  The current implementation expands all instructions into an `Instruction` enum array at parse time, stored as `FunctionBody`.
  In the Embedded phase, this array allocation becomes a problem; change it to a `FunctionHandle` that stores only the byte range.

  ```swift
  // Current (macOS phase)
  struct FunctionBody {
      let locals: [ValueType]
      let instructions: [Instruction]  // all instructions expanded at parse time
  }

  // Implemented (Embedded phase — active in #if hasFeature(Embedded) builds)
  struct FunctionHandle {
      let codeOffset: UInt32           // byte offset of instruction stream within rawBytes
      let codeSize: UInt32             // byte length of instruction stream
      let locals: [ValueType]          // local variable types (TODO: fixed buffer in Phase 4)
      let hasBulkMemoryInstruction: Bool
      let jumpTable: [JumpEntry]       // pre-computed block/loop/if targets (TODO: fixed buffer in Phase 4)
  }

  struct JumpEntry {
      let instrOffset: UInt32  // absolute byte position of block/loop/if opcode
      let target1: UInt32      // block/if: byte after end; loop: first byte of body
      let target2: UInt32      // ifElse: byte after end (br-continuation); others: 0
  }
  ```

  In the current Embedded build, the interpreter lazy-decodes a `[Instruction]` array from the
  stored byte range on each function call. The jump table is pre-built at parse time and will be
  consumed by the Phase 4 on-the-fly decoder to resolve `br`/`br_if` targets in O(1) without
  scanning forward through raw bytes at runtime.

  The `parseFlatBodyTracked()` method in `WasmParser.swift` (Embedded-only) builds both the
  temporary `[Instruction]` array and the `[JumpEntry]` table in a single pass, using a
  pre-append-then-backpatch strategy that maintains pre-order (parent block before children).
  This ordering allows Phase 4's decoder to advance its jump table cursor monotonically.

- [ ] **Introduce `WasmLimits` fixed upper bounds to eliminate dynamic arrays**

  Currently each field of `WasmModule` is a dynamic array (`[FunctionType]`, `[UInt32]`, `[Export]`, etc.).
  In the Embedded phase, `malloc` is unavailable, so all must be replaced with fixed-size buffers.

  ```swift
  // Example limit constants
  enum WasmLimits {
      static let maxTypes     = 64   // max number of function signatures
      static let maxFunctions = 64   // max number of functions
      static let maxImports   = 32   // max number of imports
      static let maxExports   = 32   // max number of exports
      static let maxGlobals   = 32   // max number of global variables
      static let maxTables    = 4    // max number of tables
      static let maxMemories  = 1    // max number of memories (Wasm MVP: 1 only)
      static let maxElements  = 16   // max number of element segments
      static let maxData      = 16   // max number of data segments
  }
  ```

  Change `[FunctionType]` to fixed-length tuples or static buffers via `UnsafeBufferPointer`.
  Limit values should be tuned to typical Embedded use cases (small Wasm binaries of a few KB).

---

## Phase 2.5 — Design Improvements Before Embedded Migration

Items to fix before the Embedded-phase migration, to reduce the migration cost.
None of these affect macOS behavior, but they are design issues or potential Embedded link errors.

- [x] **Pre-compute `block`/`loop`/`if` arity in the parser and embed in instructions**

  `brArity` and `paramCount` are now pre-computed at parse time by `blockArityForBlock()` and
  `loopBrArityFromBlockType()` in `WasmParser.swift` and embedded directly in the instruction.
  The interpreter no longer calls `blockArity()` / `loopBrArity()` or accesses `module.types` at runtime.

  `BlockType` is retained in the enum cases for use by the macOS validator (`WasmValidator`).
  Parser helpers now throw `WasmError.typeMismatch` for out-of-range type indices instead of
  returning a silent fallback.

  ```swift
  // Before: arity computed at runtime on every execution
  case block(BlockType, Int)              // endPc only
  case loop(BlockType, Int)              // startPc only
  case ifElse(BlockType, Int, Int)       // elsePc, endPc only

  // After: parser embeds pre-computed values
  case block(BlockType, brArity: Int, paramCount: Int, endPc: Int)
  case loop(BlockType, brArity: Int, startPc: Int)
  case ifElse(BlockType, brArity: Int, paramCount: Int, elsePc: Int, endPc: Int)
  ```

  Change is localised to `WasmModule.swift` (Instruction enum), `WasmParser.swift`, and `WasmInterpreter.swift`.

- [x] **Inline `brTable` target array into the flat instruction stream**

  The previous implementation stored `case brTable([UInt32], UInt32)` with a heap-allocated `[UInt32]`.
  This was replaced with a flat-bytecode scheme:

  ```swift
  // Current implementation (no malloc required)
  case brTable(count: UInt32, default_: UInt32)  // followed by count brTableEntry instructions
  case brTableEntry(UInt32)                       // each target depth

  // At runtime: access targets via instructions[ip + i] instead of labels[i]
  ```

  The parser uses a backpatch strategy: emit the header with `default_=0`, emit each `brTableEntry`
  as targets are read, then overwrite the header with the real `default_`.
  All 31,925 spectests pass; Embedded Swift compilation (`armv7em`) succeeds.

- [ ] **Implement `WasmInteger` protocol to unify i32/i64 arithmetic generically**

  The adoption plan is documented in `SWIFT_VM_DESIGN.md` Section 9, but currently i32/i64
  arithmetic, comparison, and bit operations are all implemented individually with near-duplicate code.

  Implementing a `WasmInteger` protocol inspired by WasmKit's `RawUnsignedInteger` would reduce
  duplication and allow the compiler to catch missing cases when new instructions are added.

  ```swift
  protocol WasmInteger: FixedWidthInteger & UnsignedInteger {
      associatedtype Signed: FixedWidthInteger & SignedInteger
      init(bitPattern: Signed)
  }
  extension UInt32: WasmInteger { typealias Signed = Int32 }
  extension UInt64: WasmInteger { typealias Signed = Int64 }
  ```

  Generics use static dispatch (monomorphisation) in Embedded Swift, so this is compatible.
  However, `@inlinable` is required for calls across module boundaries (see `SWIFT_VM_DESIGN.md` Section 9).

---

## Phase 3 — Wasm Interpreter (for Embedded)

The macOS-phase interpreter is complete (spectest 31,925 pass / 0 fail).
The following changes are needed when migrating to the Embedded phase.

- [ ] **Fix effective address computation for 32-bit targets**

  Memory instructions (load/store) currently compute the effective address as:

  ```swift
  // Current (works on macOS but unsafe on 32-bit)
  let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
  ```

  On macOS (64-bit), `Int` is 64-bit wide so no overflow occurs, but on Pico (32-bit, `Int` is 32-bit)
  `addr + offset` can overflow `UInt32.max`, producing an incorrect address.

  ```swift
  // Fixed (for Embedded phase)
  let ea = UInt64(UInt32(bitPattern: addr)) + UInt64(offset)
  guard ea + UInt64(accessSize) <= UInt64(memory.count) else {
      throw WasmError.memoryAccessOutOfBounds
  }
  ```

  Using `UInt64` for intermediate computation ensures correct bounds checking on 32-bit targets.
  Affects all load/store instructions in `WasmInterpreter.swift` (~25 sites).

- [ ] **Replace `Array<T>` with fixed-size buffers**

  Replace the dynamic arrays used at runtime with fixed-length buffers.

  | Field | Location | Current | Embedded replacement |
  |-------|----------|---------|----------------------|
  | `valueStack` | `WasmInterpreter.swift` L279 | `[Value]` | Fixed-length array + top index (e.g. max depth 256) |
  | `callStack` | `WasmInterpreter.swift` L280 | `[Frame]` | Fixed-length array + depth counter (e.g. max depth 64) |
  | `CallFrame.locals` | `WasmInterpreter.swift` L87 | `[Value]` | Fixed slots on the stack (e.g. max locals 128) |
  | `CallFrame.labels` | `WasmInterpreter.swift` L87 | `[Label]` | Fixed-length array (e.g. max nesting depth 32) |
  | `tables` | `WasmInterpreter.swift` L125 | `[[Value]]` | Flat fixed-length buffer + per-table offset/count |

  Note: `droppedDataSegments` and `droppedElementSegments` were `[Bool]` and are now `UInt64` bitmaps (completed).

- [x] **Eliminate argument copy in `call` / `call_indirect`**

  Changed `pushFrame` signature from `callArgs: [Value]` to `argCount: Int`;
  arguments are now read directly from `valueStack` without an intermediate copy.
  The `Array(valueStack.suffix(argCount))` allocation is eliminated.

  One copy remains at the host-function boundary (intentional; avoids changing the host API).
  `CallFrame.locals` still uses `[Value]` — fixed-buffer replacement is part of the Phase 5 work.
  (Marked with `// TODO: Embedded Phase 5` comment in source.)

---

## Phase 4 — Porting to Raspberry Pi Pico

Embedded Swift compilation (`armv7em-none-none-eabi`) and linking (BLE firmware generation) are verified.
The following work is needed to reach a state where Wasm runs on real hardware.

### Eliminate Dynamic Allocation

Apply the Phase 2–3 work (`FunctionHandle`, `WasmLimits`, fixed buffers) to the real hardware build.
On Pico, `malloc` must not be used (even though `pico_stdlib` provides it, the Embedded-phase policy
is to eliminate all dynamic allocation), so all dynamic allocations must be replaced with
compile-time fixed-size buffers.

- [x] **Pre-compute jump table in `FunctionHandle` (Phase 4 preparation)**

  `FunctionHandle.jumpTable: [JumpEntry]` is built at parse time by `parseFlatBodyTracked()`.
  Each entry maps the absolute byte position of a `block`/`loop`/`if` opcode to its target
  byte positions within `WasmModule.rawBytes`.
  Entries are in pre-order (parent before children), enabling Phase 4's on-the-fly decoder
  to advance a monotonic cursor — one step per control-flow opcode — for O(1) target lookup.

  Remaining Phase 4 work: replace `[JumpEntry]` with a fixed-size buffer to eliminate the
  `malloc` dependency (marked `// TODO: Embedded Phase 4` in source).

- [ ] **Replace lazy decode with true on-the-fly decode (primary Phase 4 goal)**

  The current Embedded interpreter still lazy-decodes a `[Instruction]` array from `rawBytes`
  on each function call (`pushFrame` path). Phase 4 replaces this with a `ip: UInt32` byte
  offset that advances through `rawBytes` directly, using the `jumpTable` to resolve
  `br`/`br_if`/`br_table` targets without forward scanning.

  Prerequisites completed: `FunctionHandle` zero-copy byte range (Phase 2), `brTable` flat
  inline (Phase 2.5②), jump table pre-computation (above).

- [ ] **Replace `ValueStack` with a fixed-size buffer + index management**

  Fix the maximum stack depth (e.g. 256 elements) and manage it with a `top` index.
  Throw `WasmError.stackOverflow` on overflow.

  ```swift
  struct ValueStack {
      var storage: (Value, Value, ...) // fixed-length tuple or UnsafeBufferPointer
      var top: Int = 0
  }
  ```

- [ ] **Replace `CallStack` / `CallFrame.locals` with fixed arrays on the stack**

  Fix the maximum call depth (e.g. 64 frames) and manage with a fixed-length buffer.
  Limit each frame's local variable count (e.g. 128 locals).
  Throw `WasmError.stackOverflow` when the limit is exceeded.

- [ ] **Replace `WasmModule` dynamic fields with fixed-length buffers**

  Use `WasmLimits` (defined in Phase 2) to change `types` / `functions` / `exports` / `imports` /
  `globals` / `tables` / `memories` / `elements` / `data` fields to fixed-length.

- [ ] **Introduce an Arena Allocator to reduce allocations during module load**

  Reserve a large buffer from Pico SRAM and stack module-load data into it.
  This is more Embedded-friendly than repeated `malloc`/`free` calls, avoiding heap fragmentation.

  ```
  [     Arena buffer (e.g. 64 KB of SRAM)     ]
   ↑ used ↑  ↑ next allocation starts here
  ```

### Host Function Implementation

Implement host functions for Wasm to control Pico peripherals.
Since Embedded Swift cannot heap-allocate closures, use `@convention(c)` function pointers + a static table.

- [x] **Migrate `HostFunction` closure to `@convention(c)` function pointer**

  `HostFunctionPtr` type alias and `HostImport` enum are now conditionally compiled with
  `#if hasFeature(Embedded)`. In Embedded builds, host functions are registered as
  `@convention(c)` function pointers (no heap-captured closures).
  `pushFrame` uses `withUnsafeTemporaryAllocation` + `UnsafeRawPointer` for argument passing.
  The `hostBlink` function in `Examples/RaspberryPiPicoW-BLE/Embedded/Main.swift` is implemented
  as a `@_cdecl("hostBlink")` function (closure eliminated).

- [ ] **`digitalWrite(pin: i32, val: i32) -> void` — GPIO output**

  Calls Pico SDK's `gpio_init()` + `gpio_set_dir()` + `gpio_put()`.
  `pin` is the GPIO pin number (0–29); `val` is 0 (LOW) / 1 (HIGH).
  Wasm imports it as `(import "env" "digitalWrite" (func (param i32 i32)))`.

- [ ] **`digitalRead(pin: i32) -> i32` — GPIO input**

  Calls Pico SDK's `gpio_get()` and returns the pin state as i32.
  Wasm imports it as `(import "env" "digitalRead" (func (param i32) (result i32)))`.

- [ ] **`sleep(ms: i32) -> void` — delay**

  Calls Pico SDK's `sleep_ms()`.
  Calling `sleep(1000)` from Wasm waits 1 second.

- [ ] **(Extension) `oledDrawText(x: i32, y: i32, ptr: i32) -> void` — OLED display**

  Receives a string pointer in Wasm linear memory and renders it on an SSD1306 OLED via I2C.
  `ptr` is an offset into linear memory (null-terminated ASCII string assumed).

### Hardware Verification

- [ ] **Execute `i32.add` from Wasm and print the result via UART**

  Target a minimal Wasm function such as:

  ```wat
  (module
    (func (export "add") (param i32 i32) (result i32)
      local.get 0
      local.get 1
      i32.add))
  ```

  Call `WasmInterpreter.callExport("add", args: [.i32(3), .i32(4)])` and verify
  that the return value is `7` and `"result: 7\n"` appears on UART.

### Size and RAM Optimization

- [ ] **Enable LTO (Link-Time Optimization) to reduce binary size**

  The current BLE firmware is ~968 KB (`pico-ble.uf2`; ~484 KB stripped binary).
  Compared to wasm3 (~64 KB) and WAMR (100–300 KB), there is a significant gap.

  **Attempted and blocked:** `INTERPROCEDURAL_OPTIMIZATION TRUE` was tried in `CMakeLists.txt`
  but is incompatible with Pico SDK's extensive `--wrap` usage (`__wrap_printf`, `__wrap_malloc`,
  `__wrap_memcpy`, etc.). During LTO, GCC cannot resolve the ARM/Thumb calling convention of
  `__wrap_*` symbols, producing "Unknown destination type" / "dangerous relocation" linker errors.
  Swift-level dead code elimination is already provided by `CMAKE_Swift_COMPILATION_MODE wholemodule`.

  Re-evaluate when migrating to a bare-metal environment that does not rely on `--wrap` for
  standard library interception.

- [ ] **Add `@frozen` to the `Instruction` enum to reduce type metadata**

  ```swift
  // WasmModule.swift
  @frozen
  enum Instruction: Sendable { ... }
  ```

  `@frozen` tells the compiler the enum's cases are exhaustive and stable, enabling exhaustive
  `switch` optimization and reducing Embedded Swift type metadata overhead.
  No effect on macOS behavior; beneficial in Embedded builds.

- [ ] **Measure RAM usage on real hardware and confirm it fits in SRAM**

  RP2350 SRAM: 520 KB; RP2040: 264 KB.
  Estimated RAM breakdown during Wasm execution:

  | Purpose | Estimated size |
  |---------|---------------|
  | Wasm Linear Memory (1 page) | 64 KB |
  | Interpreter ValueStack | ~4 KB (256 elements × 16 bytes) |
  | Interpreter CallStack | ~8 KB (64 frames × 128 bytes) |
  | WasmModule (fixed buffers) | ~8 KB |
  | BLE stack (CYW43) | ~50 KB |
  | Pico SDK / system | ~20 KB |
  | **Total (estimate)** | **~154 KB** |

  Check per-symbol sizes in `pico-ble.elf.map` and verify the budget is met.
  Tighter reductions are needed to support RP2040 as well.

---

## Phase 5 — iOS Integration

Basic BLE-based Wasm transfer and execution is implemented.
BLE communication uses the CYW43439 (Wi-Fi/BLE combo chip) built into the Pico W.
The iOS app is implemented in SwiftUI + CoreBluetooth.

### BLE Protocol Design

- [x] **Design BLE GATT service and characteristic for Wasm binary transfer**

  Adopted a state-machine approach using a single writable characteristic (UUID: `...def1`) with a command byte prefix.
  Unlike the original two-characteristic design (WasmBinary + Control), all protocol is consolidated into one characteristic.

  ```
  Service UUID: 12345678-1234-5678-1234-56789abcdef0
    Characteristic UUID: 12345678-1234-5678-1234-56789abcdef1 (Write, Dynamic)
      → Command byte protocol:
          0xF0 [size_lo] [size_hi]              — Transfer start / buffer reset
          0xF1 [offset_lo] [offset_hi] [data…]  — Write chunk data
          0xF2                                   — Confirm full receipt and execute
  ```

  Uses `withResponse` writes; the next packet is sent only after receiving a `didWriteValueFor` completion (ordering guaranteed).

- [ ] **Design a Notification characteristic for log output** (not implemented)

  Forward UART log output from Pico to iOS as BLE Notifications.
  Implement as UART → ring buffer → BLE Notification.
  Split and reassemble log lines to fit MTU size (20–512 bytes).

- [ ] **Strengthen the transfer-complete / execution-start handshake protocol** (not implemented)

  Currently completion is determined solely by matching received byte count.
  Include a CRC checksum in the final packet to detect corruption or interruption during transfer.

### Required Features (iOS App)

- [x] **Select a Wasm file from the iOS app and send it to Pico via BLE**

  Tap to select from a preset `.wasm` file list (`WasmEntry.all`) bundled in the app,
  then transfer to Pico via CoreBluetooth in the order: 0xF0 → 0xF1 chunks → 0xF2.
  A `ProgressView` shows transfer progress.
  (The original `UIDocumentPickerViewController` Files app integration is not implemented.)

- [x] **The transferred Wasm executes immediately on Pico**

  After receiving 0xF2, the Pico calls `executeReceivedWasm()`, loads the module with
  `WasmInterpreter`, and executes it via `call(functionIndex: module.importedFunctionCount, args: [])`.
  An execution-start Status Notification is not yet implemented.

- [ ] **Display Pico execution logs in real time in the iOS app** (not implemented)

  Append text to a SwiftUI `ScrollView` each time a Log Notification is received.
  Receive via the CoreBluetooth `centralManager(_:didUpdateValueFor:)` delegate
  and forward to a `@MainActor`-bound ViewModel.

- [x] **Re-transfer a different Wasm and switch Pico behaviour**

  After 0xF2 execution, `wasmRecvLen` / `wasmRecvExpected` are reset to zero,
  so the next 0xF0 immediately starts receiving the next binary.
  An explicit RESET command to the interpreter is not implemented.

### Preset Wasm Files

The iOS app bundle includes three Wasm files.
Each has a no-argument `(export "run")` entry point and imports `env::blink`.

| File | Description |
|------|-------------|
| `blink-loop.wasm` | Blink LED 3 times |
| `blink-loop2.wasm` | Blink LED 5 times |
| `blink-loop3.wasm` | Blink LED 10 times (loop) |

### Extensions (Optional)

- [ ] **Store, manage, and switch between multiple Wasm binaries in the iOS app**

  Use SwiftData or FileManager to save transferred binaries to the app's Documents folder.
  Implement a management screen with list view, deletion, and re-sending.

- [ ] **Select and transfer any `.wasm` from the iOS Files app**

  Enable `.wasm` file selection via `UIDocumentPickerViewController`.

- [ ] **Mirror OLED display content in the iOS app**

  Have Pico periodically send its OLED frame buffer (128×64 bits = 1 KB) as BLE Notifications,
  and render it in real time in the iOS app using `Canvas` or `UIImage`.

- [ ] **Monitor Pico CPU load and memory usage**

  Periodically retrieve instruction count, stack usage, and memory usage from the interpreter during
  Wasm execution, send via BLE Notification, and display as charts (Swift Charts) in the iOS app.
