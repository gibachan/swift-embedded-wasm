# WebAssembly Specification Reference

This document summarizes the WebAssembly specification referenced in this project.
It serves as the basis for implementation decisions and design rationale.

---

## Specification Version and Target

| Version | Standardized | Key additions |
|---------|-------------|---------------|
| **WebAssembly 1.0 (MVP)** | 2019 | Core minimal spec: integers, floating-point, linear memory, function calls |
| **WebAssembly 2.0** | 2022 | Multi-value returns, reference types, SIMD, Bulk Memory, sign-extension operators, etc. |

**This project targets: WebAssembly 2.0 (major subset)**

- i32 / i64 / f32 / f64 full arithmetic, comparison, and conversion instructions
- Control flow (block / loop / if / br / br_table)
- Linear memory (all load/store, Bulk Memory)
- Tables (funcref / externref, Bulk Table)
- Reference types (ref.null / ref.is_null / ref.func)
- Sign-extension operators and Saturating truncation

SIMD, threads, exception handling, and GC are out of scope.

---

## Implemented Instruction Set

### Control Flow

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `unreachable` | 0x00 | Unconditional trap |
| `nop` | 0x01 | No operation |
| `block` | 0x02 | Block start (br jumps to end) |
| `loop` | 0x03 | Loop start (br jumps back to top) |
| `if` / `else` | 0x04 / 0x05 | Conditional branch |
| `br` | 0x0C | Unconditional branch (by depth) |
| `br_if` | 0x0D | Conditional branch |
| `br_table` | 0x0E | Table branch (selects label by integer) |
| `return` | 0x0F | Return from function |
| `call` | 0x10 | Direct function call |
| `call_indirect` | 0x11 | Indirect call via table (with type check) |

Control flow is implemented using **flat bytecode + jump offsets** (no `indirect case` used).

### Parametric Instructions

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `drop` | 0x1A | Discard top of stack |
| `select` | 0x1B | Select one of two values based on condition |

### Variable Instructions

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `local.get` | 0x20 | Read local variable |
| `local.set` | 0x21 | Write local variable |
| `local.tee` | 0x22 | Write local variable and keep value on stack |
| `global.get` | 0x23 | Read global variable |
| `global.set` | 0x24 | Write global variable |

### Table Instructions

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `table.get` | 0x25 | Read table element |
| `table.set` | 0x26 | Write table element |

### Numeric Constants

| Instruction | opcode |
|-------------|--------|
| `i32.const` | 0x41 |
| `i64.const` | 0x42 |
| `f32.const` | 0x43 |
| `f64.const` | 0x44 |

### i32 Operations

Comparison and logic (result is i32):
`i32.eqz` / `i32.eq` / `i32.ne` / `i32.lt_s` / `i32.lt_u` / `i32.gt_s` / `i32.gt_u` / `i32.le_s` / `i32.le_u` / `i32.ge_s` / `i32.ge_u`

Bit operations:
`i32.clz` / `i32.ctz` / `i32.popcnt`

Arithmetic:
`i32.add` / `i32.sub` / `i32.mul` / `i32.div_s` / `i32.div_u` / `i32.rem_s` / `i32.rem_u`

Shift and rotate:
`i32.and` / `i32.or` / `i32.xor` / `i32.shl` / `i32.shr_s` / `i32.shr_u` / `i32.rotl` / `i32.rotr`

Sign-extension:
`i32.extend8_s` (0xC0) / `i32.extend16_s` (0xC1)

### i64 Operations

Comparison and logic (result is i32):
`i64.eqz` / `i64.eq` / `i64.ne` / `i64.lt_s` / `i64.lt_u` / `i64.gt_s` / `i64.gt_u` / `i64.le_s` / `i64.le_u` / `i64.ge_s` / `i64.ge_u`

Bit operations:
`i64.clz` / `i64.ctz` / `i64.popcnt`

Arithmetic:
`i64.add` / `i64.sub` / `i64.mul` / `i64.div_s` / `i64.div_u` / `i64.rem_s` / `i64.rem_u`

Shift and rotate:
`i64.and` / `i64.or` / `i64.xor` / `i64.shl` / `i64.shr_s` / `i64.shr_u` / `i64.rotl` / `i64.rotr`

Sign-extension:
`i64.extend8_s` (0xC2) / `i64.extend16_s` (0xC3) / `i64.extend32_s` (0xC4)

### f32 Operations

Comparison (result is i32):
`f32.eq` / `f32.ne` / `f32.lt` / `f32.gt` / `f32.le` / `f32.ge`

Unary:
`f32.abs` / `f32.neg` / `f32.ceil` / `f32.floor` / `f32.trunc` / `f32.nearest` / `f32.sqrt`

Binary arithmetic:
`f32.add` / `f32.sub` / `f32.mul` / `f32.div` / `f32.min` / `f32.max` / `f32.copysign`

### f64 Operations

Comparison (result is i32):
`f64.eq` / `f64.ne` / `f64.lt` / `f64.gt` / `f64.le` / `f64.ge`

Unary:
`f64.abs` / `f64.neg` / `f64.ceil` / `f64.floor` / `f64.trunc` / `f64.nearest` / `f64.sqrt`

Binary arithmetic:
`f64.add` / `f64.sub` / `f64.mul` / `f64.div` / `f64.min` / `f64.max` / `f64.copysign`

### Conversion Instructions (0xA7–0xBF)

| Instruction | Description |
|-------------|-------------|
| `i32.wrap_i64` | i64 → i32 (lower 32 bits) |
| `i32.trunc_f32_s/u` | f32 → i32 (traps on NaN/Inf/overflow) |
| `i32.trunc_f64_s/u` | f64 → i32 (traps on NaN/Inf/overflow) |
| `i64.extend_i32_s/u` | i32 → i64 (sign-extend / zero-extend) |
| `i64.trunc_f32_s/u` | f32 → i64 (traps on NaN/Inf/overflow) |
| `i64.trunc_f64_s/u` | f64 → i64 (traps on NaN/Inf/overflow) |
| `f32.convert_i32_s/u` | i32 → f32 |
| `f32.convert_i64_s/u` | i64 → f32 |
| `f32.demote_f64` | f64 → f32 |
| `f64.convert_i32_s/u` | i32 → f64 |
| `f64.convert_i64_s/u` | i64 → f64 |
| `f64.promote_f32` | f32 → f64 |
| `i32.reinterpret_f32` | f32 bit pattern → i32 |
| `i64.reinterpret_f64` | f64 bit pattern → i64 |
| `f32.reinterpret_i32` | i32 bit pattern → f32 |
| `f64.reinterpret_i64` | i64 bit pattern → f64 |

### Saturating Truncation (0xFC 0x00–0x07)

On NaN / Inf / overflow, clamps to max/min instead of trapping.

`i32.trunc_sat_f32_s/u` / `i32.trunc_sat_f64_s/u` / `i64.trunc_sat_f32_s/u` / `i64.trunc_sat_f64_s/u`

### Memory Instructions

**Load:**

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `i32.load` | 0x28 | Read 4 bytes |
| `i64.load` | 0x29 | Read 8 bytes |
| `f32.load` | 0x2A | Read 4 bytes |
| `f64.load` | 0x2B | Read 8 bytes |
| `i32.load8_s/u` | 0x2C/0x2D | Read 1 byte (sign-extend / zero-extend) |
| `i32.load16_s/u` | 0x2E/0x2F | Read 2 bytes |
| `i64.load8_s/u` | 0x30/0x31 | Read 1 byte |
| `i64.load16_s/u` | 0x32/0x33 | Read 2 bytes |
| `i64.load32_s/u` | 0x34/0x35 | Read 4 bytes |

**Store:**

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `i32.store` | 0x36 | Write 4 bytes |
| `i64.store` | 0x37 | Write 8 bytes |
| `f32.store` | 0x38 | Write 4 bytes |
| `f64.store` | 0x39 | Write 8 bytes |
| `i32.store8` | 0x3A | Write 1 byte |
| `i32.store16` | 0x3B | Write 2 bytes |
| `i64.store8` | 0x3C | Write 1 byte |
| `i64.store16` | 0x3D | Write 2 bytes |
| `i64.store32` | 0x3E | Write 4 bytes |

**Memory operations:**

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `memory.size` | 0x3F | Push current page count as i32 |
| `memory.grow` | 0x40 | Grow by pages (success: old size, failure: -1) |

### Bulk Memory Instructions (0xFC prefix)

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `memory.init` | 0xFC 0x08 | Copy passive data segment into linear memory |
| `data.drop` | 0xFC 0x09 | Mark data segment as dropped |
| `memory.copy` | 0xFC 0x0A | Copy within linear memory (overlap-safe) |
| `memory.fill` | 0xFC 0x0B | Fill n bytes with byte value val |

### Bulk Table Instructions (0xFC prefix)

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `table.init` | 0xFC 0x0C | Copy passive element segment into table |
| `elem.drop` | 0xFC 0x0D | Mark element segment as dropped |
| `table.copy` | 0xFC 0x0E | Copy within table (overlap-safe) |
| `table.grow` | 0xFC 0x0F | Grow table by n elements, return old size (-1 on failure) |
| `table.size` | 0xFC 0x10 | Push current table element count as i32 |
| `table.fill` | 0xFC 0x11 | Fill table range with reference value |

### Reference Type Instructions

| Instruction | opcode | Description |
|-------------|--------|-------------|
| `ref.null` | 0xD0 | Push null reference (funcref or externref) |
| `ref.is_null` | 0xD1 | Null check → i32 (1 if null, 0 otherwise) |
| `ref.func` | 0xD2 | Push funcref for the given function index |

### Element Sections (flags 0–7)

All Wasm 2.0 formats are supported:

| flags | Kind | Description |
|-------|------|-------------|
| 0, 2, 4, 6 | active | Immediate table initialization |
| 1, 5 | passive | Initialized later via `table.init` |
| 3, 7 | declarative | Reference declaration for `ref.func`. Dropped immediately at instantiation |

Expression-based segments (flags 4–7): elements are constructed from `ref.null` / `ref.func` init expressions.
`nil` entries in `functionIndices: [UInt32?]` represent null references (from `ref.null`).

---

## Out of Scope

- **SIMD** / **Threads** / **Exception Handling** / **GC**
- **WASI** (WebAssembly System Interface)
- **Cross-module linking** (sharing tables/memory between modules via import/export)

### Why Cross-Module Linking Is Out of Scope

Cross-module linking refers to sharing tables or memory between multiple `.wasm` files via `import`/`export`, dynamically linking modules together. Primary use cases include:

- C/C++ dynamic linking (Emscripten dlopen equivalent)
- Plugin systems
- Module splitting as a precursor to the Wasm Component Model

**This project does not implement cross-module linking.** Reasons:

1. **Incompatible with Embedded use cases**: Binaries targeting Raspberry Pi Pico are single `.wasm` files. The resources (RAM, Flash) for dynamically linking multiple modules are not assumed.
2. **Design cost**: Table sharing requires reference semantics, which conflicts with the current value-type (`struct`)-centric design. Embedded Swift restricts `class` (reference types), making Embedded-phase alignment difficult.
3. **Learning objectives**: The primary goal is understanding the Runtime internals; cross-module linking introduces independent complexity.

**Note on the `register` command in spectests**: The `register` command (registers a module by name so subsequent modules can import its functions) is implemented in `SpectestTests.swift`. This is a value-copy-based host function import — not true cross-module linking with shared table/memory references. This implementation enables full `table_copy` spectest passing (1728 pass / 0 skip).

---

## Binary Format

### File Structure

```text
[magic: 4 bytes] [version: 4 bytes] [section...] [section...]
```

| Field | Value |
|-------|-------|
| Magic | `0x00 0x61 0x73 0x6D` (`\0asm`) |
| Version | `0x01 0x00 0x00 0x00` (little-endian) |

### Section Structure

Each section has the following layout:

```text
[section_id: u8] [size: u32 LEB128] [content: size bytes]
```

The Wasm specification guarantees sections appear in order.

| Section | ID | Content |
|---------|----|---------|
| Custom | 0 | Arbitrarily named extension data (exempt from ordering checks) |
| Type | 1 | Function signature definitions |
| Import | 2 | Imported functions, memory, etc. |
| Function | 3 | Signature index for each function |
| Table | 4 | Function tables |
| Memory | 5 | Linear memory definition |
| Global | 6 | Global variables |
| Export | 7 | Exported functions, memory, etc. |
| Start | 8 | Function to call at startup |
| Element | 9 | Table initial values |
| Code | 10 | Function body bytecode |
| Data | 11 | Memory initial values |
| Data Count | 12 | Pre-declaration of data segment count for `memory.init` / `data.drop` |

Sections must appear in ascending ID order (custom sections with ID=0 are exempt).
Each known section ID may appear at most once. The declared section size must match the actual consumed byte count.

---

## LEB128

Wasm encodes integers in **LEB128** (Little Endian Base 128) format.
Variable-length encoding: smaller values require fewer bytes.

```text
Bit structure of each byte:
  bit 7 (MSB) = continuation bit: 1 means more bytes follow, 0 means final byte
  bits 6–0    = 7 data bits

Example: encoding the value 300:
  300 = 0b1_0010_1100
  → [0xAC, 0x02]  (2 bytes)
  0xAC = 1010_1100  (continuation=1, data=010_1100)
  0x02 = 0000_0010  (continuation=0, data=000_0010)
```

**ULEB128** is used for unsigned integers; **SLEB128** for signed integers.

---

## Stack Machine

Wasm uses a **stack machine** model with no registers.
Each instruction pops values from the stack, computes a result, and pushes it back.

```text
i32.const 3   → stack: [3]
i32.const 4   → stack: [3, 4]
i32.add       → stack: [7]      (computes 3+4, pushes result)
return        → returns 7 as the function result
```

### Key Runtime Components

| Component | Role |
|-----------|------|
| Value Stack | Operand stack manipulated by instructions |
| Call Stack | Manages frames for function calls |
| Call Frame | Holds local variables, return address, and label stack |

---

## Value Types

| Type | Description |
|------|-------------|
| `i32` | 32-bit integer (signed/unsigned distinction is per-instruction) |
| `i64` | 64-bit integer |
| `f32` | 32-bit floating-point |
| `f64` | 64-bit floating-point |
| `funcref` | Reference to a function. Can represent a null reference (uninitialized slot) |
| `externref` | Opaque reference to an external (host) object |

`funcref` is the table element type used by `call_indirect`. It can be pushed onto the stack and read/written via `table.get` / `table.set`.
`externref` references an arbitrary host-side object. In this project it is treated symmetrically with `funcref` as `Value.externref(UInt32?)`.

---

## Linear Memory

A contiguous byte array held by the Wasm module. The only memory space directly accessible from Wasm.

- Unit: **page** (1 page = 64 KB)
- Initial and maximum sizes declared in the module
- Current page count readable via `memory.size`
- Dynamic growth via `memory.grow`
- All accesses require bounds checking (out-of-bounds → trap)

Implemented as `var memory: [UInt8]` (`pico_stdlib` provides `malloc`, enabling this on the `pico-ble` target).

---

## Traps

When an invalid operation occurs, the Wasm runtime raises a **trap** (halts execution).

Runtime traps are represented as cases of `InterpreterError`, one of two typed-throws error
enums the project uses (the other, `ParserError`, covers binary-format decode errors — see
`Documentations/SWIFT_VM_DESIGN.md` Section 3.4).

```swift
// InterpreterError.swift (cases corresponding to runtime traps)
enum InterpreterError: Error, Equatable, Sendable {
    case stackUnderflow
    case typeMismatch
    case memoryAccessOutOfBounds
    case divisionByZero
    case integerOverflow
    case unreachableReached
    case indirectCallTypeMismatch
    case undefinedElement
    case invalidConversionToInteger  // trunc of NaN/Inf → int
    case executionLimitExceeded      // infinite loop prevention
    // ... other cases (see InterpreterError.swift)
}
```

---

## References

| Resource | Purpose |
|----------|---------|
| [WebAssembly Core Spec](https://webassembly.github.io/spec/core/) | Primary source for binary format and execution model |
| [WebAssembly Reference Manual](https://github.com/sunfishcode/wasm-reference-manual) | Readable unofficial reference |
| [wat2wasm (WABT)](https://github.com/WebAssembly/wabt) | Tool to generate binary from text format (.wat) |
| [Wasm3](https://github.com/wasm3/wasm3) | Reference implementation (Embedded-friendly MVP interpreter) |
