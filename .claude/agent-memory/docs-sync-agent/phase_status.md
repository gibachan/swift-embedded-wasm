---
name: phase-status
description: Current implementation milestone status for Phase 4 (interpreter) and Phase 5 (iOS BLE) — what is implemented, what is pending
metadata:
  type: project
---

As of 2026-05-31, the project has completed Phase 4 (macOS interpreter) and the core of Phase 5 (iOS BLE WASM transfer).

**Completed (Phase 1-4):**
- Flat bytecode migration (フェーズ 1.5): `block`/`loop`/`if` use jump offsets, no `indirect case`, no heap
- Full parser: Type / Import / Function / Table / Memory / Global / Export / Element / Code / Data sections
- `i32` full instruction set (arithmetic, comparison, bitwise, unary)
- `i64` full instruction set
- `f32` full instruction set (const, arithmetic, comparison, unary)
- `f64` full instruction set: const, arithmetic (0xA0–0xA6), comparison (0x61–0x66), unary (0x99–0x9F)
- `call_indirect` with multiple table support and result-type checking
- Global variables (`global.get` / `global.set`); init expressions support `i64.const`, `f64.const`, `ref.null` (0xD0), and `ref.func` (0xD2)
- Full memory load/store instruction set:
  - Load: `i32.load`(0x28) through `i64.load32_u`(0x35), plus `f32.load`(0x2A) and `f64.load`(0x2B)
  - Store: `i32.store`(0x36) through `i64.store32`(0x3E), plus `f32.store`(0x38) and `f64.store`(0x39)
  - `memory.size`(0x3F): pushes current page count as i32; spectest memory_size 42 pass
  - `memory.grow`(0x40): delta interpreted as u32; respects MemoryType.max limit
- `i64.extend_i32_s` (one conversion instruction)
- `table.get` (0x25) / `table.set` (0x26): funcref table element read/write
  - `Value` enum has `.funcref(UInt32?)` case (nil = null reference, UInt32 = function index)
  - `ValueType` enum has `.funcref = 0x70` case
  - funcref locals default-initialized to nil (Wasm spec compliant)
  - Validator: bounds + type checking for table.get/table.set
- Bulk Memory instructions (0xFC prefix) — memory ops:
  - `memory.init` (0xFC 0x08): copies passive data segment into linear memory; n=0 still bounds-checks; dropped segment treated as length 0
  - `data.drop` (0xFC 0x09): idempotent flag set; tracked by `droppedDataSegments: [Bool]` in WasmInterpreter
  - `memory.copy` (0xFC 0x0A): overlap-safe (memmove equivalent); n=0 still bounds-checks
  - `memory.fill` (0xFC 0x0B): fills n bytes with val; n=0 still bounds-checks
  - `DataSegment.offset` changed to `Int32?` (nil = passive, non-nil = active write offset)
  - Parser: Data section flags 0/1/2 supported
  - Validator: segment bounds and type checking for all four instructions
  - spectest memory_init: 240 pass / 0 skip / 0 fail
- Bulk Table instructions (0xFC prefix) — table ops:
  - `table.init` (0xFC 0x0C): copies passive element segment into table; n=0 still bounds-checks; dropped segment treated as length 0
  - `elem.drop` (0xFC 0x0D): idempotent flag set; tracked by `droppedElementSegments: [Bool]` in WasmInterpreter
  - `table.copy` (0xFC 0x0E): overlap-safe table copy; n=0 still bounds-checks
    - spectest table_copy: 1728 pass / 0 skip / 0 fail (complete pass after element segment flags 3–7 support)
  - `table.grow` (0xFC 0x0F): grows table by n elements (delta as u32); respects TableType.max; returns old size or -1; spectest table_grow 24 pass
  - `table.size` (0xFC 0x10): pushes current element count as i32; spectest table_size 39 pass
  - `table.fill` (0xFC 0x11): fills table range with ref value; dst+n as u32; n=0 boundary case handled; spectest table_fill 9 pass
  - Element segment 3-way classification (Wasm spec §4.5.4):
    - Active (isPassive=false): applied at instantiation, then dropped
    - Passive (isPassive=true, isDeclarative=false): available to table.init at runtime
    - Declarative (isPassive=true, isDeclarative=true): pre-dropped at instantiation; ref.func validity only
  - `ElementSegment.isDeclarative: Bool` added (true for flags=3/7; flags=5 is passive — CORRECTED)
  - `ElementSegment.functionIndices: [UInt32?]` — nil entries represent null references (from ref.null init_expr)
  - Parser: Element section flags 0–7 (Wasm 2.0 encoding) fully supported:
    - flags=0: active, table 0, i32.const offset, function index list (MVP)
    - flags=1: passive, elemkind(0x00), function index list
    - flags=2: active, explicit table index, i32.const offset, elemkind(0x00), function index list
    - flags=3: declarative, elemkind(0x00), init_expr* list
    - flags=4: active, table 0, i32.const offset, init_expr* list
    - flags=5: passive, reftype byte, init_expr* list  ← (correction: NOT declarative)
    - flags=6: active, explicit table index, offset expr, reftype byte, init_expr* list
    - flags=7: declarative, reftype byte, init_expr* list
  - `readFuncrefInitExpr()` helper added: ref.null → nil, ref.func funcidx → UInt32
  - Validator: segment bounds and type checking for tableInit / elemDrop / tableCopy / tableGrow / tableSize / tableFill
- Reference type instructions:
  - `ref.null` (0xD0): reads reftype byte; pushes `.funcref(nil)` for funcref (0x70) or `.externref(nil)` for externref (0x6F)
  - `ref.is_null` (0xD1): handles both `.funcref` and `.externref` via switch; [funcref|externref] → [i32]
  - `ref.func x` (0xD2): pushes funcref for function index x; bounds-checked against total function count
  - Validator: type checking for refNull / refIsNull / refFunc
- externref type support:
  - `ValueType.externref = 0x6F` added
  - `Value.externref(UInt32?)` case added
  - Tables changed from `[[UInt32?]]` to `[[Value]]` (supports both funcref and externref tables)
  - `Instruction.refNull(RefType)` carries reftype (was untyped)
  - spectest: table_fill / table_get / table_set externref cases now pass (0 skip)
- Binary parser validation (Wasm spec §6.5):
  - Section ID validation: id > 12 → `malformedSectionId`
  - Section size integrity: declared size vs consumed bytes mismatch → `sectionSizeMismatch`
  - Duplicate section detection (id 1–11) → `duplicateSection`
  - Section order enforcement (non-ascending id, custom sections excepted) → `sectionOutOfOrder`
  - Data Count section (id=12) consistency: value vs data segment count mismatch → `dataCountMismatch`
  - Data Count required when memory.init / data.drop present → `dataCountRequired`
  - flags=5 element segment: corrected to passive (isDeclarative: false), was incorrectly labeled declarative
  - Element section reftype byte validation for flags=5/6/7
  - spectest [binary]: 127 pass / 0 skip / 0 fail (was 96 pass / 31 skip)
  - Total spectest: 23,547 pass / 79 skip / 0 fail
- Spectest cross-module linking (register command):
  - `ConformanceRunner.registeredModules: [String: WasmInterpreter]` added
  - `handleRegister` stores current/named module under asName
  - `crossModuleImports(for:)` generates HostImport closures from registered modules
  - Value-copy semantics (pure function exports only; no table/memory reference sharing)
  - spectest ref_func: pass=3 (was 2)
- Linear memory with data segment initialization (active segments only applied at init)
- Host function import via `HostImport` enum (array-based, not `class HostFunctionTable`)
- Type-checking validator (`WasmValidator`) — macOS only
- Spectest runner (`SpectestTests.swift`) with f64 type support added
- Type conversion instructions (all 0xA7–0xBF + saturating truncation 0xFC 0x00–0x07):
  - Regular: i32.wrap_i64, i32.trunc_f32_s/u, i32.trunc_f64_s/u, i64.extend_i32_u, i64.trunc_f32_s/u, i64.trunc_f64_s/u, f32.convert_i32_s/u, f32.convert_i64_s/u, f32.demote_f64, f64.convert_i32_s/u, f64.convert_i64_s/u, f64.promote_f32, i32.reinterpret_f32, i64.reinterpret_f64, f32.reinterpret_i32, f64.reinterpret_i64
  - Saturating: i32.trunc_sat_f32_s/u, i32.trunc_sat_f64_s/u, i64.trunc_sat_f32_s/u, i64.trunc_sat_f64_s/u
  - spectest conversions: 619 pass / 0 skip / 0 fail
  - All spectest (as of conversion instructions commit): 3587 pass total (total now 23,547 pass / 79 skip / 0 fail)

**Known issues / Embedded-phase TODOs:**
- 32-bit address calculation: `let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)` is unsafe on 32-bit targets where `Int` is 32 bits wide; needs `UInt64` intermediate on Embedded phase

**Phase 5 — iOS BLE WASM transfer (completed items):**
- Single-characteristic BLE protocol: 0xF0 (start) / 0xF1 (chunk) / 0xF2 (execute) command-byte state machine
- `wasm_recv_buf.c`: 8KB static buffer in BSS; `wasm_recv_buf_ptr()` / `wasm_recv_buf_size()` accessors
- `executeReceivedWasm()`: calls `call(functionIndex: module.importedFunctionCount, args: [])`
- iOS app: `BLEManager.sendWasm(_:)` queues 0xF0 → 0xF1 chunks → 0xF2 with ordered `withResponse` writes
- iOS app: `ContentView` shows `WasmEntry.all` list with progress view during transfer
- iOS app: `WasmEntry` struct with `blink-loop.wasm` / `blink-loop2.wasm` / `blink-loop3.wasm` bundle presets
- Tests: `blinkLoopRuns3Times` / `blinkLoop2Runs5Times` / `blinkLoop3Runs10Times` added; old tests removed

**Phase 5 — iOS BLE (not yet implemented):**
- Log Notification characteristic (UART → BLE → iOS)
- Status Notification (transfer/execution state feedback)
- CRC checksum for transfer integrity
- iOS file picker (`UIDocumentPickerViewController`) for arbitrary .wasm selection
- RESET command to reinitialize interpreter mid-session

**Not yet implemented (Embedded phase):**
- Pico (Embedded) phase: fixed-size buffers, zero-copy Code section parsing

**Why:** Incremental implementation strategy — each instruction group is added when needed for Spectest coverage.

**How to apply:** When updating WASM_SPEC.md or Phase documents, reflect: Phase 5 BLE transfer core is implemented. The static .incbin embed approach is replaced by dynamic BLE transfer. `wasm_symbols.c` and `blink_loop_wasm.s.in` remain in the repository but are excluded from the CMake build. The single writable characteristic replaces the original 2-characteristic (WasmBinary + Control) design. Total spectest: 23,547 pass / 79 skip / 0 fail.

[[project-architecture]]
[[doc-cross-references]]
