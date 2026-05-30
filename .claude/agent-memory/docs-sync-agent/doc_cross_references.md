---
name: doc-cross-references
description: Cross-document dependency map and documents most frequently affected by implementation changes
metadata:
  type: project
---

## Documents most frequently affected by implementation changes

1. `Documentations/WASM_SPEC.md` — "実装するサブセット" section (Step 1/2/後回し/実装済み). Updated whenever new instruction groups are implemented.
2. `Documentations/PHASE4_INTERPRETER.md` — 成功基準 and 追加実装済み checklists. Updated per implementation increment.
3. `CLAUDE.md` — macOS phase allowances table; must reflect current constraints (indirect case is now gone).

## Document cross-reference map

- `CLAUDE.md` → `Documentations/OVERVIEW.md`, `Documentations/SWIFT_VM_DESIGN.md`, `Documentations/EMBEDDED_SWIFT.md`, `Documentations/PHASE2_WASM3.md`
- `OVERVIEW.md` → all PHASE*.md files
- `SWIFT_VM_DESIGN.md` → all PHASE*.md files, `WASM_SPEC.md`, `OVERVIEW.md`
- `PHASE3_PARSER.md` → `WASM_SPEC.md`
- `PHASE4_INTERPRETER.md` → `WASM_SPEC.md`
- `EMBEDDED_SWIFT.md` → `SWIFT_VM_DESIGN.md` (Section 5)

## Terminology conventions

- Use `Value` (not `WasmValue`) when referring to the runtime value enum
- Use `ValueType` (not `WasmType`) when referring to the type code enum
- Use `FunctionType` (not `FuncType`) when referring to function signatures
- Use `WasmError` (not `WasmFormatError`/`WasmTrap`) for the error enum
- Use `Documentations/` (not `docs/`) for all internal path references

[[project-architecture]]
[[phase-status]]
