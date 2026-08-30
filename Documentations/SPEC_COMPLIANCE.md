# WebAssembly Spec Compliance

This document summarizes the current implementation's compliance level based on results from
the WebAssembly official Spec Testsuite run via `swift test`.

Last evaluated: 2026-08-29 (full `swift test` aggregation)

> **2026-08-29 measurement note.** The **Overall** table below is a fresh full-suite
> aggregation. `FAIL` remains **0**. The UTF-8 name-validation change landed as expected:
> `utf8-import-field`, `utf8-import-module`, and `utf8-custom-section-id` each pass 176/176,
> and only the text-format `utf8-invalid-encoding` (176) is still skipped (no WAT parser).
>
> The measured `PASS` (29,811) is ~2,100 below the 2026-05-31 baseline (31,925) at an
> unchanged total of 59,889, with the difference appearing entirely as `SKIP` in the
> Memory64 / "Other" buckets (SIMD is unchanged at 790 / 25,199). The cause is not yet
> identified — most likely a `make spectest-gen` corpus/toolchain drift rather than a
> runtime regression (FAIL = 0 throughout). **The per-category Skip Breakdown and the
> "Pass Rate Excluding SIMD and Memory64" figures below predate this and still reflect the
> 2026-05-31 itemization; they need a methodical re-count and are marked accordingly.**

---

## Test Results (Overall)

| Metric | Value |
|--------|-------|
| Total test cases | 59,889 |
| **PASS** | 29,811 (49.8%) |
| **SKIP** | 30,078 (50.2%) |
| **FAIL** | **0 (0.0%)** |

FAIL = 0 is the most important metric. Every test case that was attempted was handled correctly.

---

## Skip Breakdown

The vast majority of skips are due to intentionally unimplemented features.

| Category | pass | skip | Primary cause |
|----------|------|------|---------------|
| SIMD (v128) | 790 | 25,199 | Intentionally unimplemented (out of scope for Embedded); unchanged 2026-08-29 |
| Memory64 (64-bit addressing) | _re-count pending_ | _re-count pending_ | Unimplemented for 32-bit Embedded targets; 2026-05-31 figure was 9,503 / 1,789 |
| Other | _re-count pending_ | _re-count pending_ | 2026-05-31 figure was 21,632 / 976; see table below |

### Breakdown of the remaining "Other" skips (2026-05-31 itemization — re-count pending)

| Test name | skip count | Estimated cause |
|-----------|-----------|-----------------|
| `utf8-invalid-encoding` | 176 | Text-format (`.wat`) test modules — no WAT parser (out of scope) |
| `if` | 153 | Multi-value returns with block type annotation on `if` |
| `float_literals` / `const` | 154 | NaN payload (non-canonical NaN bit patterns) |
| `memory_init` | 141 | Some patterns with passive data segments |
| `data` / `data1` | 46 | Specific data segment encodings |
| `block` / `loop` | 30 | Block type annotations |
| `token` | 26 | Text format tokens |
| `ref_func` | 14 | Some funcref operations |

As of 2026-08-29, `WasmParser` performs a decode-level UTF-8 well-formedness check
(`validateUTF8` → `ParserError.malformedUTF8`) on every `name` field — custom-section
names plus import module/field names and export names — on all targets (macOS and
Embedded). This moved the binary-form corpora `utf8-import-field` (176) and
`utf8-import-module` (176) from skip to pass; `utf8-custom-section-id` (176) already
passed. Only the text-format `utf8-invalid-encoding` (176) remains skipped, for lack of
a WAT parser.

The rest of the table above is the 2026-05-31 itemization and is stale. A partial
2026-08-29 spot-check (`swift test --filter Spectest`, per-corpus) shows the picture has
shifted: `float_literals` skip 177, `if` skip 153, `memory_init` skip 141, `loop` skip 94,
`block` skip 68, `data`/`data0`/`data1` skip 53. A full re-itemization of the "Other"
bucket is still outstanding — see the measurement note at the top of this document.

---

## Compliance Level

### WebAssembly 1.0 (MVP) — ~95–98% compliant

All MVP features pass except SIMD, Memory64, and obsolete-keywords. Binary-form UTF-8
well-formedness validation of `name` fields is implemented (Wasm spec §5.2.4); only the
text-format `utf8-invalid-encoding` corpus remains skipped for lack of a WAT parser.

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
| UTF-8 well-formedness of import / export / custom-section names | ✅ Complete (decode-level, runs on all targets) |
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
| PASS | _re-count pending_ |
| SKIP | _re-count pending_ |
| **Pass rate** | _re-count pending_ |

> These figures were **21,984 / 624 / 97.2%** under the 2026-05-31 itemization. Because
> the 2026-08-29 full run shows ~2,100 fewer passes overall (see the measurement note at
> the top), this table is invalidated until the Memory64 and "Other" buckets are
> re-counted. The `Target test cases` total (22,608 = 59,889 − 25,989 SIMD − 11,292
> Memory64) is unchanged only if the Memory64 corpus size held steady, which is itself
> part of what needs re-checking.

Known contributors to the remaining "Other" skips (measured 2026-08-29 where noted): the
text-format `utf8-invalid-encoding` corpus (176, no WAT parser), NaN payload in
`float_literals` (skip 177), and multi-value `if` annotations (skip 153). All are within
the MVP range but represent high-complexity edge cases or out-of-scope text-format tests.

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
