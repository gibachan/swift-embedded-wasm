# TODO — Unimplemented Items

---

## Phase 4 — Porting to Raspberry Pi Pico

Embedded Swift compilation (`armv7em-none-none-eabi`) and linking (BLE firmware generation) are verified.
The following work is needed to reach a state where Wasm runs on real hardware.

### Eliminate Dynamic Allocation

- [ ] **Remaining dynamic allocations (deferred to Phase 5)**

  The following fields are still heap-allocated and will be addressed in Phase 5:

  | Field | Location | Note |
  |-------|----------|------|
  | `code: [FunctionHandle]` | `WasmModule` | byte ranges + pre-computed jump tables |
  | `rawBytes: [UInt8]` | `WasmModule` | original Wasm binary buffer |
  | `var tempInstructions: [Instruction]` | `parseFunctionHandles()` | per-function heap alloc during parse; needs a zero-allocation byte scanner to eliminate |
  | `var frames: [EmbeddedFrame]` | macOS path | `CallStack` already fixed on Embedded; macOS uses `[EmbeddedFrame]` |
  | `CallFrame.locals: [Value]` | macOS path | Embedded stores locals on shared `ValueStack`; macOS uses `[Value]` |

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

- [x] **`digitalWrite(pin: i32, val: i32) -> void` — GPIO output**

  Calls Pico SDK's `gpio_init()` + `gpio_set_dir()` + `gpio_put()`.
  `pin` is the GPIO pin number (0–29); `val` is 0 (LOW) / 1 (HIGH).
  Wasm imports it as `(import "env" "digitalWrite" (func (param i32 i32)))`.

- [x] **`digitalRead(pin: i32) -> i32` — GPIO input**

  Calls Pico SDK's `gpio_get()` and returns the pin state as i32.
  Wasm imports it as `(import "env" "digitalRead" (func (param i32) (result i32)))`.

- [x] **`sleep(ms: i32) -> void` — delay**

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

- [ ] **Design a Notification characteristic for log output**

  Forward UART log output from Pico to iOS as BLE Notifications.
  Implement as UART → ring buffer → BLE Notification.
  Split and reassemble log lines to fit MTU size (20–512 bytes).

- [ ] **Strengthen the transfer-complete / execution-start handshake protocol**

  Currently completion is determined solely by matching received byte count.
  Include a CRC checksum in the final packet to detect corruption or interruption during transfer.

### Required Features (iOS App)

- [ ] **Display Pico execution logs in real time in the iOS app**

  Append text to a SwiftUI `ScrollView` each time a Log Notification is received.
  Receive via the CoreBluetooth `centralManager(_:didUpdateValueFor:)` delegate
  and forward to a `@MainActor`-bound ViewModel.

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
