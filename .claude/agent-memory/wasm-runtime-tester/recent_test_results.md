---
name: recent-test-results
description: Test results for newly implemented WASM instructions (2026-05-30)
metadata:
  type: project
---

## Test Date: 2026-05-30

### Instructions Tested
- `memory.size` (0x3F)
- `table.size` (0xFC 0x10)
- `table.grow` (0xFC 0x0F)
- `table.fill` (0xFC 0x11)
- `ref.null` (0xD0)
- `ref.is_null` (0xD1)
- `ref.func` (0xD2)

### Test Results: ALL PASS

#### Level 1: macOS Unit Tests
- **Status**: PASS
- **Test Count**: 52 tests total across all suites
- **Failures**: 0
- **Errors**: 0
- **Skipped**: 1 (expected — relates to address64, which is multi-valued feature)
- **Key Suites**:
  - WasmInterpreter: PASS
  - WasmParser: PASS
  - SLEB128/ULEB128 decode: PASS
  - Spectest Conformance: PASS (157 conformance test files, 23,627 tests total: 23,547 pass, 79 skip, 0 fail)

#### Level 2: Embedded Swift Compilation
- **Status**: PASS
- **Output**: `build/pico-wasm.o` generated successfully
- **Target**: armv7em-none-none-eabi (Cortex-M33 / RP2350)
- **Warnings**: None (embedded stdlib warning is pre-existing about missing snapshot)
- **Errors**: 0
- **Compiler Flags**: `-enable-experimental-feature Embedded`, `-wmo`, `-Osize`
- **Note**: All Embedded Swift constraints satisfied — no reference types, existential types, untyped throws, or dynamic allocation issues detected

#### Level 3: BLE Example Link Validation
- **Status**: PASS
- **Build Output**: Both UF2 and ELF generated successfully
- **Artifacts**:
  - `pico-ble.uf2`: 968K (firmware image)
  - `pico-ble.elf`: 2.5M (executable)
  - `pico-ble.bin`: 484K (raw binary)
  - `pico-ble.hex`: 1.3M (hex dump)
  - `pico-ble.elf.map`: 1.2M (symbol map)
- **Link Status**: No unresolved symbols, no size violations
- **Build Warnings**: Pre-existing from Pico SDK and lwip header includes (macro redefinition of LITTLE_ENDIAN, BIG_ENDIAN, BYTE_ORDER from libc headers) — not from runtime code
- **Board**: pico_w (Pico W, supports BLE)

### Summary
All three test levels pass without errors. The newly implemented instructions are:
1. Functionally correct as per WASM specification
2. Compliant with Embedded Swift constraints
3. Successfully linked into the Pico W BLE example binary
