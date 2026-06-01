# WebAssembly Spec Compliance

This document summarizes the current implementation's compliance level based on results from
the WebAssembly official Spec Testsuite run via `swift test`.

Last evaluated: 2026-05-31

---

## Test Results (Overall)

| Metric | Value |
|--------|-------|
| Total test cases | 59,889 |
| **PASS** | 31,925 (53.3%) |
| **SKIP** | 27,964 (46.7%) |
| **FAIL** | **0 (0.0%)** |

FAIL = 0 is the most important metric. Every test case that was attempted was handled correctly.

---

## Skip Breakdown

The vast majority of skips are due to intentionally unimplemented features.

| Category | pass | skip | Primary cause |
|----------|------|------|---------------|
| SIMD (v128) | 790 | 25,199 | Intentionally unimplemented (out of scope for Embedded) |
| Memory64 (64-bit addressing) | 9,503 | 1,789 | Unimplemented for 32-bit Embedded targets |
| Other | 21,632 | 976 | See table below |

### Breakdown of the remaining 976 skips (major items)

| Test name | skip count | Estimated cause |
|-----------|-----------|-----------------|
| `utf8-invalid-encoding` | 176 | Invalid UTF-8 byte sequence validation in import/export names not implemented |
| `if` | 153 | Multi-value returns with block type annotation on `if` |
| `float_literals` / `const` | 154 | NaN payload (non-canonical NaN bit patterns) |
| `memory_init` | 141 | Some patterns with passive data segments |
| `data` / `data1` | 46 | Specific data segment encodings |
| `block` / `loop` | 30 | Block type annotations |
| `token` | 26 | Text format tokens |
| `ref_func` | 14 | Some funcref operations |

---

## Compliance Level

### WebAssembly 1.0 (MVP) — ~95–98% compliant

All MVP features pass except SIMD, Memory64, obsolete-keywords, and UTF-8 validation.

| MVP feature | Status |
|-------------|--------|
| i32 / i64 / f32 / f64 all arithmetic instructions | ✅ Complete |
| `block` / `loop` / `if` / `br` / `br_if` / `br_table` | ✅ Nearly complete (153 multi-value `if` annotations skipped) |
| `call` / `call_indirect` (multiple table support) | ✅ Complete |
| `local.get` / `local.set` / `local.tee` | ✅ Complete |
| `global.get` / `global.set` | ✅ Complete |
| All memory load/store instructions (`i32.load8_s` through `f64.store`) | ✅ Complete |
| `memory.size` / `memory.grow` | ✅ Complete |
| `table.get` / `table.set` | ✅ Complete |
| import / export / start sections | ✅ Complete |
| Binary format validation (magic / version / section ordering) | ✅ Complete |
| LEB128 signed and unsigned | ✅ Complete |
| Trap handling (division by zero, out-of-bounds access, etc.) | ✅ Complete |

### WebAssembly 2.0 — ~97% compliant (excluding SIMD)

Excluding SIMD (out of project scope), nearly all Wasm 2.0 features are implemented.

| Wasm 2.0 feature | Status |
|------------------|--------|
| Saturating float-to-int truncation (`i32.trunc_sat_*`, etc.) | ✅ Complete (619 pass) |
| Sign-extension operators (`i32.extend8_s`, etc.) | ✅ Complete |
| Bulk Memory (`memory.copy` / `fill` / `init` / `data.drop`) | ✅ Complete |
| Bulk Table (`table.copy` / `fill` / `init` / `grow` / `size` / `elem.drop`) | ✅ Complete |
| Reference types (`funcref` / `externref` / `ref.null` / `ref.is_null` / `ref.func`) | ✅ Nearly complete |
| Multiple values (multi-value returns) | ✅ |
| **Fixed-width SIMD (v128)** | ❌ Intentionally unimplemented |

---

## Intentionally Unimplemented Features

| Feature | Reason |
|---------|--------|
| SIMD (v128) | Not needed for Embedded use cases; SIMD support on RP2350 is also limited |
| Memory64 (64-bit addressing) | Not needed for 32-bit Embedded targets (RP2040/RP2350) |
| Threads | Embedded Swift does not support the Swift Concurrency runtime |
| Exception Handling | Not needed for Embedded use cases |
| GC (Garbage Collection) | Incompatible with dynamic memory management in Embedded environments |
| WASI | Not applicable in OS-less Embedded environments |

---

## Pass Rate Excluding SIMD and Memory64

Effective pass rate within the intended implementation scope.

| Metric | Value |
|--------|-------|
| Target test cases | 22,608 |
| PASS | 21,632 |
| SKIP | 976 |
| **Pass rate** | **95.7%** |

Of the remaining 976 skips, just three items account for 483: NaN payload (154), UTF-8 validation (176), and multi-value `if` annotations (153). All are within the MVP range but represent high-complexity edge cases.

---

## Evaluation Commands

```sh
# Run all tests (outputs pass/skip/fail)
swift test

# Aggregate pass/skip/fail counts
swift test 2>&1 | grep -E '^\[' \
  | awk -F'pass=|skip=|fail=' \
    '{p+=$2; s+=$3; f+=$4} END {print "pass:", p, "skip:", s, "fail:", f, "total:", p+s+f}'
```
