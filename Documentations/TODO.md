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

Reserve a large buffer from Pico SRAM and stack module-load data into it.
This is more Embedded-friendly than repeated `malloc`/`free` calls, avoiding heap fragmentation.

```
[     Arena buffer (e.g. 64 KB of SRAM)     ]
 ↑ used ↑  ↑ next allocation starts here
```

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
  | BLE stack (CYW43) | ~50 KB |
  | Pico SDK / system | ~20 KB |
  | **Total (estimate)** | **~154 KB** |

  Use `peakValueStackDepth` and `peakCallStackDepth` from `WasmInterpreter` as runtime watermarks
  to verify that the fixed-size buffer capacities are sufficient in practice.
  Check per-symbol sizes in `pico-ble.elf.map` and verify the budget is met.
  Tighter reductions are needed to support RP2040 as well.
