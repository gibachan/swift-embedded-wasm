# TODO — Unimplemented Items

Only outstanding work is listed. Completed items have been removed; see git history
and `Documentations/ARENA_ALLOCATOR.md` for what is already done.

---

## Raspberry Pi Pico (Phase 4–5)

### Arena Allocator — Step 5: measure on real hardware

Steps 1–4 are complete. Backing store is a 96 KB C static buffer
(`Examples/RaspberryPiPicoW-BLE/Embedded/wasm_arena.c:3`, `WASM_ARENA_SIZE`).

- [ ] Measure `wasmArena.usedBytes` on hardware and tune `WASM_ARENA_SIZE` to actual usage
  - Instrumentation is done: firmware sends `STATS:<instr>,<vs>,<cs>,<arenaBytes>\n`;
    the iOS `StatsView` shows "Arena Used" per run plus a bar chart across runs.
  - Procedure once a Pico is available:
    1. `cd Examples/RaspberryPiPicoW-BLE/Embedded && make flash`
       (or copy `build/pico-ble.uf2` to the BOOTSEL mass-storage volume)
    2. Launch the iOS `Demo` app; it auto-connects to `PicoLED` over BLE
    3. Send `i32-add.wasm` (small, no host imports — minimum-footprint baseline),
       then `gpio-blink-swift.wasm` (host imports + loop); read `arenaUsedBytes`
       for each from the "Latest Run" section / bar chart in `StatsView`
    4. Compare `arenaUsedBytes` against `WASM_ARENA_SIZE` (96 KB) and note headroom
    5. If headroom is large, shrink `WASM_ARENA_SIZE`, re-measure, and feed the
       confirmed number into the RAM budget table below

### Host Function Extensions

- [ ] `oledDrawText(x: i32, y: i32, ptr: i32) -> void` — SSD1306 OLED over I2C
  - `ptr` is an offset into Wasm linear memory (null-terminated ASCII string assumed)
  - Requires an SSD1306 I2C driver integrated into the Pico firmware

### Size and RAM Optimization

- [ ] Enable LTO to reduce binary size — **currently blocked**
  - BLE firmware is ~968 KB (`pico-ble.uf2`; ~484 KB stripped) vs wasm3 ~64 KB, WAMR 100–300 KB
  - `INTERPROCEDURAL_OPTIMIZATION TRUE` in `CMakeLists.txt` is incompatible with the
    Pico SDK's extensive `--wrap` usage (`__wrap_printf`, `__wrap_malloc`, `__wrap_memcpy`, …):
    during LTO, GCC cannot resolve the ARM/Thumb calling convention of `__wrap_*` symbols,
    producing "Unknown destination type" / "dangerous relocation" linker errors
  - Swift-level dead-code elimination is already provided by `CMAKE_Swift_COMPILATION_MODE wholemodule`
  - Re-evaluate when moving to a bare-metal environment that does not rely on `--wrap`

- [ ] Measure RAM usage on real hardware and confirm it fits in SRAM
  - RP2350 SRAM: 520 KB; RP2040: 264 KB. Estimated breakdown during Wasm execution:

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

  - RP2350 (520 KB) fits comfortably. RP2040 (264 KB) does not — the WasmArena backing
    store (96 KB) and Wasm Linear Memory (64 KB) dominate and would need reduction.
  - Use `peakValueStackDepth` / `peakCallStackDepth` from `WasmInterpreter` as runtime
    watermarks to confirm the fixed-size buffer capacities are sufficient; check
    per-symbol sizes in `pico-ble.elf.map`.

---

## Spec Compliance

- [ ] Re-itemize the spectest skip breakdown in `Documentations/SPEC_COMPLIANCE.md`
  - 2026-08-29 full run: PASS 29,811 / SKIP 30,078 / **FAIL 0** — ~2,100 fewer passes than
    the 2026-05-31 baseline at an unchanged total (59,889), entirely as SKIP in the
    Memory64 / "Other" buckets (SIMD unchanged at 790 / 25,199)
  - Confirm the cause is `make spectest-gen` corpus/toolchain drift, not a runtime regression
  - Recompute the per-category tables (Memory64, "Other") and the
    "Pass Rate Excluding SIMD and Memory64" figures, then drop the `_re-count pending_` markers

---

## Known / Accepted (not TODO)

Intentional heap allocations that remain in the macOS path only:

| Allocation | Note |
|---|---|
| macOS `var frames: [EmbeddedFrame]` | Stack-pressure workaround; Embedded path uses fixed-size `CallStack` |
| macOS `CallFrame.locals: [Value]` | Stack-pressure workaround; Embedded path stores locals on the shared `ValueStack` |
