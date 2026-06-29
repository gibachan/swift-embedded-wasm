---
name: docs-cross-references
description: Cross-reference map between documentation files — which docs mirror which information
metadata:
  type: project
---

Key cross-document relationships in this project:

- `SWIFT_VM_DESIGN.md` Section 5 (Interpreter Loop phases) ↔ source files `WasmInterpreterEmbedded.swift`, `WasmInterpreter.swift`
- `SWIFT_VM_DESIGN.md` Section 10 (Stack Size) → references `Examples/RaspberryPiPicoW-BLE/Embedded/memmap_wasm.ld` and `CMakeLists.txt`
- `SWIFT_VM_DESIGN.md` Section 10 (Stack Size) → cross-references Section 5 Phase 5 for the moduleRef pointer pattern
- `TODO.md` RAM budget table → reflects the same physical memory layout as SWIFT_VM_DESIGN.md Section 10
- `ARENA_ALLOCATOR.md` → detailed design for WasmArena; summarized in SWIFT_VM_DESIGN.md Section 2 and 6
- `CLAUDE.md` → references `Documentations/SWIFT_VM_DESIGN.md` for Embedded compliance policy

**Why:** These cross-references need to stay consistent. When a number (e.g., stack size, arena size, buffer counts) changes, it must be updated in all places that reference it.

**How to apply:** After updating SWIFT_VM_DESIGN.md, check TODO.md RAM table and ARENA_ALLOCATOR.md for stale numbers.

[[swift-vm-design-structure]]
