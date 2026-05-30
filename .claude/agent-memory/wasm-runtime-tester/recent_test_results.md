---
name: recent-test-results
description: Test results for binary parser verification gap fix (2026-05-31)
metadata:
  type: project
---

## Test Date: 2026-05-31

### Changes Tested
- Binary parser verification gap fix
- New error cases: `malformedSectionId`, `sectionSizeMismatch`, `duplicateSection`, `sectionOutOfOrder`, `dataCountMismatch`, `dataCountRequired`
- Enhanced validation: section size checks, section ID ordering, Data Count section integrity
- Improvement: [binary] spectest moved from pass=96 skip=31 → pass=127 skip=0

### Test Results: ALL PASS

#### Level 1: macOS Unit Tests
- **Status**: PASS
- **Test Count**: 52 unit tests (excluding spectests)
- **Failures**: 0
- **Errors**: 0
- **Skipped**: 1 (address64 — expected, multi-valued feature)
- **Spectest Results**:
  - Total files: 157 conformance test files
  - Total tests: 23,627 across all suites
  - Aggregate: 23,547 pass, 79 skip, 0 fail
  - **[binary] pass=127 skip=0 fail=0** ← Exact match to target
- **Key Suites**:
  - WasmInterpreter: PASS
  - WasmParser: PASS
  - SLEB128/ULEB128 decode: PASS
  - Spectest Conformance: ALL PASS

#### Level 2: Embedded Swift Compilation
- **Status**: PASS
- **Output**: `build/pico-wasm.o` generated successfully
- **Target**: armv7em-none-none-eabi (Cortex-M33 / RP2350)
- **Compiler**: Apple Swift 6.3.2 (swift-6.3.2-RELEASE)
- **Warnings**: None (embedded stdlib warning is pre-existing snapshot issue)
- **Errors**: 0
- **Compiler Flags**: `-enable-experimental-feature Embedded`, `-wmo`, `-Osize`
- **Constraint Violations**: None detected
  - No existential types (`any Protocol`)
  - No reference types (`class`)
  - No untyped throws
  - No String comparisons
  - No Swift Concurrency features
  - No dynamic heap allocation issues

#### Level 3: BLE Example Link Validation
- **Status**: PASS
- **Build Output**: Both UF2 and ELF generated successfully
- **Artifacts**:
  - `pico-ble.uf2`: firmware image for Pico W
  - `pico-ble.elf`: executable binary
  - Linking completed without unresolved symbols
- **Link Status**: Success — no symbol resolution errors, no size violations
- **Build Warnings**: 2 pre-existing from Pico SDK + lwip headers (endian macro redefinitions, GNU-stack section) — not from runtime code
- **Board**: pico_w (Pico W, supports BLE)

### Regression Analysis
- **No regressions detected**: All spectest suites maintain previous pass rates
- **Binary suite specifically**: Improved from 96→127 pass (31 previously skipped tests now pass)
- **Other suites**: No failures, consistent pass/skip rates

### Summary
All three test levels pass without errors. The binary parser verification gap fix:
1. Correctly validates binary format per WASM specification
2. Complies with all Embedded Swift constraints
3. Successfully links into the Pico W BLE example binary
4. Improved binary spectest from skip=31 to skip=0 (all 127 binary tests now pass)
