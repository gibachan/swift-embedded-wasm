---
name: memory-init-datadrop-implementation
description: Implementation details, spec behavior, and test results for memory.init and data.drop bulk memory operations
metadata:
  type: project
---

## memory.init (0xFC 0x08) and data.drop (0xFC 0x09) Implementation

**Status:** Complete. `memory_init` spectest: 222 pass / 5 skip / 13 fail (failures due to memory.copy in memory_init.3.wasm which is out of scope).

**Why:** Added to enable spectest compliance for the bulk memory proposal.

**How to apply:** When implementing other 0xFC sub-opcodes, follow the same pattern used here.

### Key Spec Behaviors to Remember

1. **DataSegment.offset is now Optional**: `nil` = passive, non-nil = active. Only active segments are copied into linear memory at instantiation time.

2. **memory.init bounds check is unconditional**: The spec says trap if `src + n > |seg|` OR `dst + n > |mem|` — this check applies even when `n = 0`. Our first implementation incorrectly skipped bounds checks for `n = 0`, causing 3 spectest traps to pass instead of trap. Fixed by always computing `srcOff + copyCount <= segBytes.count`.

3. **Dropped segments have effective length 0**: When `droppedDataSegments[si] == true`, we use an empty `[]` slice for `segBytes`. This means any non-zero `src + n` traps correctly.

4. **n = 0 with dropped segment, src = 0**: `0 + 0 = 0 <= 0` — valid (no trap). This is spec-correct.

5. **data.drop is idempotent**: Dropping an already-dropped segment is a no-op per spec.

### 0xFC Prefix Parser (parseFlatBody)

The full 0xFC dispatch table is implemented in `parseFlatBody()`. Sub-opcodes 0x00-0x07 (saturating truncate) have no extra operands. Sub-opcodes 0x08-0x11 each have specific operand parsing (see WasmParser.swift case 0xFC).

### Side Effect: Exposed Latent Failures

Adding 0xFC prefix parsing made `bulk`, `memory_copy`, `memory_fill` spectests parse-capable. Previously these modules failed to parse (counted as skips). Now they parse correctly but fail at runtime on `.unimplemented(0xFC)` for `memory.copy` / `memory.fill`. This exposes latent failures:
- bulk: 29 fail (was 0)
- memory_copy: 251 fail (was 0)
- memory_fill: 5 fail (was 0)

These are correct "exposed latent failures" not regressions — they indicate which operations need implementation next.

### droppedDataSegments State

`private var droppedDataSegments: [Bool]` on `WasmInterpreter` — marked `// TODO: Embedded — replace with fixed-size buffer`. This is instance state, mutated by `data.drop` and read by `memory.init` during `runIterative`.
