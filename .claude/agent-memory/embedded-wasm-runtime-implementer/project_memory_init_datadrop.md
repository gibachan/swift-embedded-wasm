---
name: memory-init-datadrop-implementation
description: Implementation details, spec behavior, and test results for bulk memory and table operations
metadata:
  type: project
---

## Bulk Memory and Table Instructions Implementation

**Status:** Complete. All originally-failing suites now pass:
- `memory_fill`: 99 pass / 1 skip / 0 fail
- `memory_copy`: 4449 pass / 1 skip / 0 fail
- `bulk`: 116 pass / 1 skip / 0 fail
- `table_copy`: 611 pass / 1117 skip / 0 fail
- `table_init64`: 587 pass / 289 skip / 0 fail

**Why:** Added to enable spectest compliance for the bulk memory and bulk table proposals.

**How to apply:** When implementing other 0xFC sub-opcodes, follow the same pattern used here.

### Instructions Implemented

- `memory.fill` (0xFC 0x0B): fills n bytes at dst with low 8 bits of val
- `table.init` (0xFC 0x0C): copies from element segment into table
- `elem.drop` (0xFC 0x0D): marks element segment as dropped
- `table.copy` (0xFC 0x0E): copies entries between tables (overlap-safe)

### Key Spec Behaviors

1. **ElementSegment.isPassive**: Added `isPassive: Bool` field. Passive (flags=1) segments are not applied at instantiation. Active (flags=0, flags=2) segments are applied and then implicitly dropped.

2. **Active element segments are dropped after instantiation** (spec §4.5.4): `droppedElementSegments` is initialized with `true` for all non-passive (active) segments. This ensures `table.init` on active segments traps correctly.

3. **Passive element segments** (flags=1 in binary): format is `[elemkind: u8][count: u32][funcidx: u32...]`. elemkind 0x00 = funcref.

4. **All bounds checks are unconditional** (apply even when n=0): `dst + n > table/memory.count` traps. Same pattern as memory.copy and memory.init.

5. **table.copy overlap safety**: Same-table copies use memmove semantics (copy backward when dst > src and regions overlap). Different-table copies always copy forward.

6. **elem.drop is idempotent**: Dropping an already-dropped segment is a no-op.

7. **Dropped segments have effective length 0**: `droppedElementSegments[ei] ? 0 : module.elements[ei].functionIndices.count`.

### State Added to WasmInterpreter

- `private var droppedElementSegments: [Bool]` — initialized with active=true, passive=false; mutated by `elem.drop`; read by `table.init`

### Prior memory.init / data.drop behaviors (still apply)

1. **DataSegment.offset is Optional**: `nil` = passive, non-nil = active. Only active segments applied at instantiation.
2. **memory.init bounds check is unconditional**: always `srcOff + copyCount <= segLen`.
3. **Dropped data segments have effective length 0**: `droppedDataSegments[si] ? 0 : module.data[si].bytes.count`.
4. **data.drop is idempotent**.

### 0xFC Prefix Parser (parseFlatBody)

Sub-opcodes 0x00-0x07: saturating truncate (no extra operands, `.unimplemented`).
Sub-opcodes 0x08-0x0E: fully implemented (memory.init, data.drop, memory.copy, memory.fill, table.init, elem.drop, table.copy).
Sub-opcodes 0x0F-0x11: table.grow, table.size, table.fill (still `.unimplemented`).
