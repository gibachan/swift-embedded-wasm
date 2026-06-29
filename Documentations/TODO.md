# TODO — Unimplemented Items

---

## Phase 4 — Porting to Raspberry Pi Pico

### Remaining Dynamic Allocations

The following heap allocations are intentional and remain:

| Allocation | Note |
|---|---|
| macOS `var frames: [EmbeddedFrame]` | Intentional stack-pressure workaround; Embedded path already uses fixed-size `CallStack` |
| macOS `CallFrame.locals: [Value]` | Intentional stack-pressure workaround; Embedded path stores locals on shared `ValueStack` |

### Arena Allocator

Steps 1–4 are complete. See `Documentations/ARENA_ALLOCATOR.md` for the full design.

- [x] **Step 1**: `WasmArena` bump-pointer allocator implemented (`Sources/WasmRuntime/WasmArena.swift`); 96 KB C static backing buffer added (`Examples/RaspberryPiPicoW-BLE/Embedded/wasm_arena.c`); 12 unit tests (`Tests/WasmRuntimeTests/WasmArenaTests.swift`)
- [x] **Step 2**: `WasmInterpreter.memory` changed from `[UInt8]` to `UnsafeMutableBufferPointer<UInt8>`; `WasmInterpreter.init` now requires `arena: inout WasmArena`; `memoryCapacity: Int` property added
- [x] **Step 3**: `DataSegment.bytes` / import/export name bytes changed to zero-copy `UnsafeBufferPointer<UInt8>` slices of `rawBytes` (no arena copy needed)
- [x] **Step 4**: `Main.swift` updated with `var wasmArena = WasmArena()` global and `wasmArena.reset()` per-cycle; `memory.grow` (0x40) and `table.grow` (FC 0x15) fixed to operate in `UInt64` domain to avoid 32-bit Int overflow traps on RP2350; `-enable-experimental-feature Extern` added to `Makefile` and `CMakeLists.txt`
- [ ] **Step 5**: Measure `wasmArena.usedBytes` on real hardware via BLE notification; adjust Arena size based on actual measurements
  - Implementation complete: `bleNotifyStats` now sends `STATS:<instr>,<vs>,<cs>,<arenaBytes>\n`; iOS StatsView shows "Arena Used" in Latest Run and a bar chart across runs
  - Pending: flash to Pico, run demo Wasm binaries, read arenaUsed values, tune `WASM_ARENA_SIZE` in `wasm_arena.c`

### Host Function Extensions

- [ ] **`oledDrawText(x: i32, y: i32, ptr: i32) -> void` — OLED display**

  Receives a string pointer in Wasm linear memory and renders it on an SSD1306 OLED via I2C.
  `ptr` is an offset into linear memory (null-terminated ASCII string assumed).
  Requires an SSD1306 I2C driver to be integrated into the Pico firmware.

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
  | WasmArena static backing store | 96 KB (C static array in `wasm_arena.c`) |
  | BLE stack (CYW43) | ~50 KB |
  | Pico SDK / system | ~20 KB |
  | Core 0 native stack (linker script) | 64 KB (reserved at top of RAM by `memmap_wasm.ld`) |
  | **Total (estimate)** | **~314 KB** |

  Note: RP2040 has 264 KB total SRAM; this estimate exceeds that. The WasmArena backing
  store (96 KB) and Wasm Linear Memory (64 KB) are the dominant allocations and would need
  reduction to support RP2040. RP2350 has 520 KB SRAM and comfortably fits the full budget.

  Use `peakValueStackDepth` and `peakCallStackDepth` from `WasmInterpreter` as runtime watermarks
  to verify that the fixed-size buffer capacities are sufficient in practice.
  Check per-symbol sizes in `pico-ble.elf.map` and verify the budget is met.
  Tighter reductions are needed to support RP2040 as well.
