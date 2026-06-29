---
name: swift-vm-design-structure
description: Key structure and cross-reference map for SWIFT_VM_DESIGN.md — which sections to update for which kinds of changes
metadata:
  type: project
---

`Documentations/SWIFT_VM_DESIGN.md` is the primary technical reference for the WASM VM. Its section structure:

- Section 2: Component Architecture (update when new top-level components are added)
- Section 3: Type Design (Value, ValueType, FunctionType, WasmError)
- Section 4: Validation Policy (macOS vs Embedded)
- Section 5: Interpreter Loop — phases 1, 1.5, 2, 2.5, 4, and now Phase 5 pointer pattern
  - Fixed-buffer status table at end of Phase 4 section — update when new fixed-buffer types are added
  - Phase 5: Pointer-Based Module Access subsection — documents moduleRef: UnsafePointer<WasmModule>
- Section 6: Linear Memory — arena-backed UnsafeMutableBufferPointer
- Section 7: Host Function Design — HostImport, Fixed4_HostImport, Fixed32_HostFunctionPtr
- Section 8: Embedded Swift Constraints (unavailable features + patterns)
- Section 9: Performance Optimization (inlinable, hot path patterns)
- Section 10: Memory Layout and Debugging — now includes Stack Size and Custom Linker Script
  - Cross-references Section 5 Phase 5 for the moduleRef pointer pattern
- Sections 11–15: Comparisons, Swift strengths, evaluation, related docs

**Why:** SWIFT_VM_DESIGN.md is the most frequently updated doc — every significant Embedded optimization or VM design decision lands here.

**How to apply:** When reviewing implementation changes, check which sections are affected before editing. Section 5 (phases) and Section 10 (memory/stack) are highest-change-frequency.

[[docs-cross-references]]
