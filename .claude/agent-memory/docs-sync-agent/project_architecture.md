---
name: project-architecture
description: Key structural facts about the project that affect documentation maintenance — directory names, naming conventions, and past rename history
metadata:
  type: project
---

The documentation directory is `Documentations/` (not `docs/`). It was renamed from `docs/` to `Documentations/` in commit `0c8dde0` (2026-05-29) but internal cross-references were not updated at that time — they have since been corrected.

**Why:** The rename was part of a broader directory restructuring commit. Internal path references lagged behind.

**How to apply:** When reviewing or updating documentation, always use `Documentations/` as the path prefix in cross-references, not `docs/`. If any new document refers to `docs/`, that is a bug to fix.

Key actual type names in implementation (differ from design doc names in SWIFT_VM_DESIGN.md):
- `Value` (not `WasmValue`) — runtime value enum
- `ValueType` (not `WasmType`) — type code enum
- `FunctionType` (not `FuncType`) — function signature struct
- `WasmError` (not `WasmFormatError`/`WasmTrap`) — unified error enum covering both parser and interpreter errors

SWIFT_VM_DESIGN.md is intentionally a design/learning document; its Section 3 now contains both the original design intent and the actual implementation type names.

[[phase-status]]
