// Core data types for the Wasm binary parser and interpreter

// MARK: - Module Limits

/// Fixed upper bounds for each section of a WasmModule.
///
/// These constants serve two purposes:
///   1. Parser validation — the parser rejects binaries that exceed these counts with
///      `WasmError.resourceLimitExceeded`, providing early detection of modules that
///      cannot run on the Embedded target.
///   2. Embedded phase migration — when dynamic `Array<T>` fields of `WasmModule` are
///      replaced with fixed-size buffers (Phase 4 / 5), these constants determine the
///      tuple or static-buffer dimensions.
///
/// Values are sized for typical Embedded use cases (small Wasm binaries of a few KB).
/// They are intentionally conservative: any binary that fits within these limits will
/// comfortably run on the RP2350's 520 KB SRAM budget.
///
/// Checks are enforced on both macOS and Embedded builds — a binary that exceeds a limit
/// will not run on Embedded hardware regardless of the host OS, so early detection is
/// always desirable.
enum WasmLimits {
  static let maxTypes: Int = 64  // max number of function signatures
  static let maxFunctions: Int = 64  // max number of functions
  static let maxImports: Int = 32  // max number of imports
  static let maxExports: Int = 32  // max number of exports
  static let maxGlobals: Int = 32  // max number of global variables
  static let maxTables: Int = 4  // max number of tables
  static let maxTableElements: Int = 256  // max elements per table (for fixed-buffer Embedded target)
  static let maxMemories: Int = 1  // Wasm MVP spec §5.5.8 allows at most 1 memory; also matches the Embedded fixed-buffer limit.
  static let maxElements: Int = 16  // max number of element segments
  static let maxData: Int = 16  // max number of data segments
  // Interpreter runtime limits (used by fixed-size buffer implementations in Embedded builds)
  static let maxValueStackDepth: Int = 256  // max operand stack depth
  static let maxCallDepth: Int = 64  // max call stack depth (call frames)
  static let maxLabelDepth: Int = 32  // max nested block/loop/if depth per frame
  static let maxLocalsPerFunction: Int = 32  // max declared locals per function body
  static let maxJumpEntriesPerFunction: Int = 64  // max block/loop/if instructions per function body
}

// MARK: - Value Types

enum ValueType: UInt8, Sendable {
  case i32 = 0x7F
  case i64 = 0x7E
  case f32 = 0x7D
  case f64 = 0x7C
  case funcref = 0x70  // reference to a function; used in table types and signatures
  case externref = 0x6F  // opaque host reference; used in table types and signatures
}

// MARK: - Block Type

/// Result type of a block / loop / if instruction
///
/// Encoded as a signed LEB128 (s33) in the binary format:
///   negative values are value types or void (0x40 = -64, 0x7F = -1 for i32, etc.)
///   non-negative values are type indices into the Type section (multi-value extension)
enum BlockType: Sendable {
  case void  // 0x40: no result
  case value(ValueType)  // 0x7F etc.: single result
  case typeIndex(UInt32)  // >= 0: index into Type section (multi-value blocks)
}

// MARK: - Function Type (signature)

struct FunctionType: Sendable {
  let params: [ValueType]
  let results: [ValueType]

  init(params: [ValueType], results: [ValueType]) {
    self.params = params
    self.results = results
  }
}

// MARK: - Reference Types

enum RefType: UInt8, Sendable {
  case funcRef = 0x70
  case externRef = 0x6F
}

// MARK: - Table

struct TableType: Sendable {
  let refType: RefType
  let min: UInt32
  let max: UInt32?
}

// MARK: - Globals

enum GlobalMutability: UInt8, Sendable {
  case immutable = 0x00
  case mutable = 0x01
}

struct GlobalType: Sendable {
  let valueType: ValueType
  let mutability: GlobalMutability
}

/// A global variable definition from the Global section.
/// initValue is the result of evaluating the (constant) init expression.
struct GlobalDef: Sendable {
  let type: GlobalType
  let initValue: Value
}

// MARK: - Element Segments

/// An element segment from the Element section.
///
/// Active segments (isPassive == false, isDeclarative == false) are applied to a table at
/// instantiation time, then treated as dropped (Wasm spec §4.5.4).
/// Passive segments (isPassive == true, isDeclarative == false) are not applied at
/// instantiation; they remain available for use by `table.init` and can be invalidated by
/// `elem.drop`.
/// Declarative segments (isPassive == true, isDeclarative == true) are pre-dropped at
/// instantiation — they exist only to make `ref.func` instructions valid, and must never
/// be accessible via `table.init`.
struct ElementSegment: Sendable {
  let isPassive: Bool  // true = passive or declarative (not applied at instantiation)
  let isDeclarative: Bool  // true = declarative (flags=3, 7 only); pre-dropped per spec §4.5.4
  let tableIndex: UInt32  // valid only when isPassive == false
  let offset: Int32  // valid only when isPassive == false
  // nil entries represent null references (ref.null in expression-based segments)
  let functionIndices: [UInt32?]
}

// MARK: - Instructions

/// Instruction set supported by this interpreter.
///
/// All control-flow instructions use flat bytecode with pre-computed jump offsets.
/// block/loop/if carry integer PCs computed during parsing — no indirect cases,
/// no nested arrays, no heap allocation required.
///
/// Flat control flow model:
///   block(bt, brArity, paramCount, endPc)
///       — pushes a label; br to this label jumps to endPc;
///         brArity = result count (values carried on br / fall-through);
///         paramCount = parameter count (re-pushed when entering the block).
///   loop(bt, brArity, startPc)
///       — pushes a label; br to this label jumps to startPc (restart);
///         brArity = param count (br to a loop restarts with its args).
///   ifElse(bt, brArity, paramCount, elsePc, endPc)
///       — pops condition; jumps to elsePc if 0; br jumps to endPc;
///         brArity = result count; paramCount = parameter count.
///
/// BlockType is retained in each case for the non-Embedded validator, which requires the
/// full param/result type arrays to check type-stack consistency.  The interpreter hot path
/// uses only the pre-computed integer fields (brArity, paramCount) and never reads BlockType,
/// eliminating the module.types lookup that the previous blockArity()/loopBrArity() helpers
/// performed on every execution of a block/loop/if instruction.
///   blockEnd                 — pops the top label (normal fall-through exit)
///   jump(pc)                 — unconditional jump (skips the else body in if/else)
@frozen
enum Instruction: Sendable {
  case unreachable  // 0x00
  case nop  // 0x01
  // Flat structured control flow (no indirect cases; all PCs computed by parser)
  case block(BlockType, brArity: Int, paramCount: Int, endPc: Int)  // 0x02
  case loop(BlockType, brArity: Int, startPc: Int)  // 0x03
  case ifElse(BlockType, brArity: Int, paramCount: Int, elsePc: Int, endPc: Int)  // 0x04
  case blockEnd  // marks end of block/loop/if body; pops the label
  case jump(Int)  // unconditional jump to PC (used to skip else body)
  case br(UInt32)  // 0x0C
  case brIf(UInt32)  // 0x0D
  case brTable(count: UInt32, default_: UInt32)  // 0x0E: followed by `count` brTableEntry instructions in flat stream
  case brTableEntry(UInt32)  // each non-default target depth; consumed inline by brTable handler
  case return_  // 0x0F
  case call(UInt32)  // 0x10
  case callIndirect(UInt32, UInt32)  // 0x11: typeIdx, tableIdx
  // stack operations
  case drop  // 0x1A
  case select  // 0x1B
  // locals
  case localGet(UInt32)  // 0x20
  case localSet(UInt32)  // 0x21
  case localTee(UInt32)  // 0x22
  case globalGet(UInt32)  // 0x23
  case globalSet(UInt32)  // 0x24
  // table operations
  case tableGet(UInt32)  // 0x25: tableIdx
  case tableSet(UInt32)  // 0x26: tableIdx
  // constants
  case i32Const(Int32)  // 0x41
  case i64Const(Int64)  // 0x42
  case f32Const(Float)  // 0x43
  case f64Const(Double)  // 0x44
  // i32 unary
  case i32Eqz  // 0x45
  case i32Clz  // 0x67
  case i32Ctz  // 0x68
  case i32Popcnt  // 0x69
  case i32Extend8S  // 0xC0
  case i32Extend16S  // 0xC1
  // i32 comparisons
  case i32Eq  // 0x46
  case i32Ne  // 0x47
  case i32LtS  // 0x48
  case i32LtU  // 0x49
  case i32GtS  // 0x4A
  case i32GtU  // 0x4B
  case i32LeS  // 0x4C
  case i32LeU  // 0x4D
  case i32GeS  // 0x4E
  case i32GeU  // 0x4F
  // i32 arithmetic
  case i32Add  // 0x6A
  case i32Sub  // 0x6B
  case i32Mul  // 0x6C
  case i32DivS  // 0x6D
  case i32DivU  // 0x6E
  case i32RemS  // 0x6F
  case i32RemU  // 0x70
  // i32 bitwise
  case i32And  // 0x71
  case i32Or  // 0x72
  case i32Xor  // 0x73
  case i32Shl  // 0x74
  case i32ShrS  // 0x75
  case i32ShrU  // 0x76
  case i32Rotl  // 0x77
  case i32Rotr  // 0x78
  // f32 comparisons (return i32)
  case f32Eq  // 0x5B
  case f32Ne  // 0x5C
  case f32Lt  // 0x5D
  case f32Gt  // 0x5E
  case f32Le  // 0x5F
  case f32Ge  // 0x60
  // f32 unary
  case f32Abs  // 0x8B
  case f32Neg  // 0x8C
  case f32Ceil  // 0x8D
  case f32Floor  // 0x8E
  case f32Trunc  // 0x8F
  case f32Nearest  // 0x90
  case f32Sqrt  // 0x91
  // f32 binary arithmetic
  case f32Add  // 0x92
  case f32Sub  // 0x93
  case f32Mul  // 0x94
  case f32Div  // 0x95
  case f32Min  // 0x96
  case f32Max  // 0x97
  case f32Copysign  // 0x98
  // f64 comparisons (return i32)
  case f64Eq  // 0x61
  case f64Ne  // 0x62
  case f64Lt  // 0x63
  case f64Gt  // 0x64
  case f64Le  // 0x65
  case f64Ge  // 0x66
  // f64 unary
  case f64Abs  // 0x99
  case f64Neg  // 0x9A
  case f64Ceil  // 0x9B
  case f64Floor  // 0x9C
  case f64Trunc  // 0x9D
  case f64Nearest  // 0x9E
  case f64Sqrt  // 0x9F
  // f64 binary arithmetic
  case f64Add  // 0xA0
  case f64Sub  // 0xA1
  case f64Mul  // 0xA2
  case f64Div  // 0xA3
  case f64Min  // 0xA4
  case f64Max  // 0xA5
  case f64Copysign  // 0xA6
  // i64 unary
  case i64Eqz  // 0x50
  case i64Clz  // 0x79
  case i64Ctz  // 0x7A
  case i64Popcnt  // 0x7B
  case i64Extend8S  // 0xC2
  case i64Extend16S  // 0xC3
  case i64Extend32S  // 0xC4
  // i64 comparisons (return i32)
  case i64Eq  // 0x51
  case i64Ne  // 0x52
  case i64LtS  // 0x53
  case i64LtU  // 0x54
  case i64GtS  // 0x55
  case i64GtU  // 0x56
  case i64LeS  // 0x57
  case i64LeU  // 0x58
  case i64GeS  // 0x59
  case i64GeU  // 0x5A
  // i64 arithmetic
  case i64Add  // 0x7C
  case i64Sub  // 0x7D
  case i64Mul  // 0x7E
  case i64DivS  // 0x7F
  case i64DivU  // 0x80
  case i64RemS  // 0x81
  case i64RemU  // 0x82
  // i64 bitwise
  case i64And  // 0x83
  case i64Or  // 0x84
  case i64Xor  // 0x85
  case i64Shl  // 0x86
  case i64ShrS  // 0x87
  case i64ShrU  // 0x88
  case i64Rotl  // 0x89
  case i64Rotr  // 0x8A
  // conversions
  case i32WrapI64  // 0xA7: truncate i64 to i32 (lower 32 bits)
  case i32TruncF32S  // 0xA8: f32 → i32 (signed, traps on NaN/Inf/overflow)
  case i32TruncF32U  // 0xA9: f32 → u32 as i32 (unsigned, traps on NaN/Inf/overflow)
  case i32TruncF64S  // 0xAA: f64 → i32 (signed, traps on NaN/Inf/overflow)
  case i32TruncF64U  // 0xAB: f64 → u32 as i32 (unsigned, traps on NaN/Inf/overflow)
  case i64ExtendI32S  // 0xAC: sign-extend i32 to i64
  case i64ExtendI32U  // 0xAD: zero-extend i32 to i64 (interpret as UInt32)
  case i64TruncF32S  // 0xAE: f32 → i64 (signed, traps on NaN/Inf/overflow)
  case i64TruncF32U  // 0xAF: f32 → u64 as i64 (unsigned, traps on NaN/Inf/overflow)
  case i64TruncF64S  // 0xB0: f64 → i64 (signed, traps on NaN/Inf/overflow)
  case i64TruncF64U  // 0xB1: f64 → u64 as i64 (unsigned, traps on NaN/Inf/overflow)
  case f32ConvertI32S  // 0xB2: i32 (signed) → f32
  case f32ConvertI32U  // 0xB3: i32 (as UInt32) → f32
  case f32ConvertI64S  // 0xB4: i64 (signed) → f32
  case f32ConvertI64U  // 0xB5: i64 (as UInt64) → f32
  case f32DemoteF64  // 0xB6: f64 → f32 (precision reduction)
  case f64ConvertI32S  // 0xB7: i32 (signed) → f64
  case f64ConvertI32U  // 0xB8: i32 (as UInt32) → f64
  case f64ConvertI64S  // 0xB9: i64 (signed) → f64
  case f64ConvertI64U  // 0xBA: i64 (as UInt64) → f64
  case f64PromoteF32  // 0xBB: f32 → f64 (precision extension)
  case i32ReinterpretF32  // 0xBC: f32 bit pattern → i32
  case i64ReinterpretF64  // 0xBD: f64 bit pattern → i64
  case f32ReinterpretI32  // 0xBE: i32 bit pattern → f32
  case f64ReinterpretI64  // 0xBF: i64 bit pattern → f64
  // saturating truncations (0xFC prefix, sub-ops 0x00–0x07): clamp instead of trap
  case i32TruncSatF32S  // 0xFC 0x00
  case i32TruncSatF32U  // 0xFC 0x01
  case i32TruncSatF64S  // 0xFC 0x02
  case i32TruncSatF64U  // 0xFC 0x03
  case i64TruncSatF32S  // 0xFC 0x04
  case i64TruncSatF32U  // 0xFC 0x05
  case i64TruncSatF64S  // 0xFC 0x06
  case i64TruncSatF64U  // 0xFC 0x07
  // memory loads
  case i32Load(UInt32, UInt32)  // 0x28: align, offset
  case i64Load(UInt32, UInt32)  // 0x29: align, offset
  case f32Load(UInt32, UInt32)  // 0x2A: align, offset
  case f64Load(UInt32, UInt32)  // 0x2B: align, offset
  case i32Load8S(UInt32, UInt32)  // 0x2C: align, offset
  case i32Load8U(UInt32, UInt32)  // 0x2D: align, offset
  case i32Load16S(UInt32, UInt32)  // 0x2E: align, offset
  case i32Load16U(UInt32, UInt32)  // 0x2F: align, offset
  case i64Load8S(UInt32, UInt32)  // 0x30: align, offset
  case i64Load8U(UInt32, UInt32)  // 0x31: align, offset
  case i64Load16S(UInt32, UInt32)  // 0x32: align, offset
  case i64Load16U(UInt32, UInt32)  // 0x33: align, offset
  case i64Load32S(UInt32, UInt32)  // 0x34: align, offset
  case i64Load32U(UInt32, UInt32)  // 0x35: align, offset
  // memory stores
  case i32Store(UInt32, UInt32)  // 0x36: align, offset
  case i64Store(UInt32, UInt32)  // 0x37: align, offset
  case f32Store(UInt32, UInt32)  // 0x38: align, offset
  case f64Store(UInt32, UInt32)  // 0x39: align, offset
  case i32Store8(UInt32, UInt32)  // 0x3A: align, offset
  case i32Store16(UInt32, UInt32)  // 0x3B: align, offset
  case i64Store8(UInt32, UInt32)  // 0x3C: align, offset
  case i64Store16(UInt32, UInt32)  // 0x3D: align, offset
  case i64Store32(UInt32, UInt32)  // 0x3E: align, offset
  case memorySize  // 0x3F: push current memory page count as i32
  case memoryGrow  // 0x40
  // reference instructions
  case refNull(RefType)  // 0xD0: push null reference (.funcref(nil) or .externref(nil))
  case refIsNull  // 0xD1: [ref] → [i32]; 1 if null, 0 otherwise
  case refFunc(UInt32)  // 0xD2: push funcref for the given function index
  // bulk memory operations (0xFC prefix)
  case memoryInit(UInt32)  // 0xFC 0x08: data segment index
  case dataDrop(UInt32)  // 0xFC 0x09: data segment index
  case memoryCopy  // 0xFC 0x0A: dst_mem=0, src_mem=0 (MVP always uses memory 0)
  case memoryFill  // 0xFC 0x0B: fills n bytes starting at dst with the low 8 bits of val
  case tableInit(UInt32, UInt32)  // 0xFC 0x0C: elem_idx, table_idx
  case elemDrop(UInt32)  // 0xFC 0x0D: elem_idx — marks element segment as dropped
  case tableCopy(UInt32, UInt32)  // 0xFC 0x0E: dst_table_idx, src_table_idx
  case tableGrow(UInt32)  // 0xFC 0x0F: table_idx; [funcref, i32] → [i32]
  case tableSize(UInt32)  // 0xFC 0x10: table_idx; [] → [i32]
  case tableFill(UInt32)  // 0xFC 0x11: table_idx; [i32, funcref, i32] → []
  // Parsed but not yet implemented; throws invalidInstruction at runtime.
  case unimplemented(UInt8)
}

// MARK: - Function Handle
//
// The code section is stored as zero-copy byte ranges (FunctionHandle) in both Embedded
// and non-Embedded builds. The on-the-fly interpreter decodes opcodes directly from
// rawBytes at execution time using the pre-computed jump table for O(1) control-flow
// target resolution.

/// One control-flow entry in a function's jump table.
///
/// All offsets are absolute byte positions within the WasmModule.rawBytes buffer —
/// the same coordinate space as the on-the-fly decoder's ip in Phase 4.
///
/// Entries are stored in **pre-order** (parent block before its children) so that
/// Phase 4's on-the-fly decoder can walk the table with a monotonically advancing
/// integer cursor, advancing by 1 each time it encounters a block/loop/if opcode.
/// This gives O(1) lookup per control-flow opcode without search.
///
/// Semantics by instruction kind:
///   block:   target1 = byte position of instruction after blockEnd (br-continuation)
///            target2 = 0 (unused)
///   loop:    target1 = byte position of first instruction in loop body (br restarts here)
///            target2 = 0 (unused)
///   ifElse:  target1 = byte position of else clause start (or endPc if no else)
///            target2 = byte position of instruction after end (br-continuation)
struct JumpEntry: Sendable {
  let instrOffset: UInt32  // absolute byte position of the block/loop/if opcode
  let target1: UInt32
  let target2: UInt32
}

/// A function body descriptor for zero-copy Embedded builds.
///
/// Stores only the byte range of the function body within the original Wasm binary,
/// plus local variable types needed for frame setup. The interpreter re-parses the
/// byte range into [Instruction] on first call (lazy decode).
struct FunctionHandle: Sendable {
  /// Byte offset of the instruction stream start (after local declarations) within
  /// the Wasm binary buffer passed to WasmParser.init.
  let codeOffset: UInt32
  /// Byte length of the instruction stream (from codeOffset to 0x0B end opcode, inclusive).
  let codeSize: UInt32
  /// Local variable types declared in this function body (separate from parameters).
  let locals: FixedLocals_ValueType
  /// True if this function body contains a memory.init (0xFC 0x08) or data.drop (0xFC 0x09)
  /// instruction. Stored to support the data-count section requirement check without
  /// needing to fully decode the instruction stream at parse time.
  let hasBulkMemoryInstruction: Bool
  /// Jump table mapping each block/loop/if opcode's absolute byte offset to its target
  /// byte positions within rawBytes. Built at parse time; consumed by the Phase 4
  /// on-the-fly decoder to resolve br/br_if targets without re-scanning instructions.
  let jumpTable: FixedJumpTable_JumpEntry
}

// MARK: - Memory

/// Limits for a Wasm linear memory (in pages; 1 page = 64 KiB)
struct MemoryType: Sendable, Equatable {
  let min: UInt32
  let max: UInt32?  // nil = unbounded
}

// MARK: - Imports

/// A function import entry from the Import section
struct FunctionImport: Sendable {
  let module: [UInt8]  // module name (UTF-8 bytes)
  let name: [UInt8]  // field name (UTF-8 bytes)
  let typeIndex: UInt32  // index into the Type section
}

/// A memory import entry from the Import section
struct MemoryImport: Sendable {
  let module: [UInt8]
  let name: [UInt8]
  let type: MemoryType
}

/// An entry in the Import section (only function and memory are supported)
enum Import: Sendable {
  case function(FunctionImport)
  case memory(MemoryImport)
}

// MARK: - Data Segments

/// An initialization segment from the Data section.
///
/// Active segments (offset != nil) are copied into linear memory at instantiation time.
/// Passive segments (offset == nil) are not applied at instantiation; they remain available
/// for use by `memory.init` and can be invalidated by `data.drop`.
struct DataSegment: Sendable {
  let offset: Int32?  // nil = passive segment; non-nil = active (write offset into memory)
  let bytes: [UInt8]  // data bytes
}

// MARK: - Exports

enum ExportKind: UInt8, Sendable {
  case function = 0x00
  case table = 0x01
  case memory = 0x02
  case global = 0x03
}

struct Export: Sendable {
  // The export name is stored as UTF-8 bytes.
  // Name matching uses byte comparison rather than String == to avoid
  // pulling in Unicode normalization tables.
  let nameBytes: [UInt8]
  let kind: ExportKind
  let index: UInt32

  init(nameBytes: [UInt8], kind: ExportKind, index: UInt32) {
    self.nameBytes = nameBytes
    self.kind = kind
    self.index = index
  }

  // For debugging/display only. Use nameBytes for comparisons.
  var name: String { String(decoding: nameBytes, as: UTF8.self) }
}

// MARK: - Zero Sentinels (Embedded fixed-buffer initialisation)

// These `static var zero` properties provide sentinel values used only to fill
// fixed-buffer tuple slots at init time.  They are never read back as module data;
// they merely satisfy Swift's requirement that every tuple element be initialised.

extension FunctionType {
  /// Sentinel used to fill uninitialised slots in Fixed64_FunctionType.
  static var zero: FunctionType { FunctionType(params: [], results: []) }
}

extension Import {
  /// Sentinel used to fill uninitialised slots in Fixed32_Import.
  static var zero: Import {
    .function(FunctionImport(module: [], name: [], typeIndex: 0))
  }
}

extension Export {
  /// Sentinel used to fill uninitialised slots in Fixed32_Export.
  static var zero: Export { Export(nameBytes: [], kind: .function, index: 0) }
}

extension GlobalDef {
  /// Sentinel used to fill uninitialised slots in Fixed32_GlobalDef.
  static var zero: GlobalDef {
    GlobalDef(type: GlobalType(valueType: .i32, mutability: .immutable), initValue: .i32(0))
  }
}

extension TableType {
  /// Sentinel used to fill uninitialised slots in Fixed4_TableType.
  static var zero: TableType { TableType(refType: .funcRef, min: 0, max: nil) }
}

extension ElementSegment {
  /// Sentinel used to fill uninitialised slots in Fixed16_ElementSegment.
  static var zero: ElementSegment {
    ElementSegment(
      isPassive: true, isDeclarative: false, tableIndex: 0, offset: 0, functionIndices: [])
  }
}

extension DataSegment {
  /// Sentinel used to fill uninitialised slots in Fixed16_DataSegment.
  static var zero: DataSegment { DataSegment(offset: nil, bytes: []) }
}

extension ValueType {
  /// Sentinel used to fill uninitialised slots in FixedLocals_ValueType.
  static var zero: ValueType { .i32 }
}

extension JumpEntry {
  /// Sentinel used to fill uninitialised slots in FixedJumpTable_JumpEntry.
  static var zero: JumpEntry { JumpEntry(instrOffset: 0, target1: 0, target2: 0) }
}

// MARK: - Fixed-Buffer Types

// These types provide a uniform API for WasmModule fields on both macOS and Embedded builds,
// following the same "Approach A" pattern as LabelStack in WasmInterpreter.swift:
// the #if hasFeature(Embedded) lives INSIDE each type, not outside it.
//
// Embedded builds: storage is a homogeneous tuple on the stack — no malloc.
// macOS builds:    storage is a [T] array (heap-allocated) to keep struct sizes manageable.
//
// Each type exposes:
//   - init(_ arr: [T])    — copies from a [T] (macOS parse path)
//   - var count: Int
//   - subscript(Int) -> T  — get only; module data is immutable after parse

// MARK: Fixed64_FunctionType

/// 64-slot fixed buffer for the Type section (max WasmLimits.maxTypes = 64).
///
/// Embedded: storage is 8 × 8-element sub-tuples — no malloc.
/// macOS:    storage is [FunctionType] (heap) — keeps struct size small.
struct Fixed64_FunctionType {
  #if hasFeature(Embedded)
    private var s0, s1, s2, s3, s4, s5, s6,
      s7:
        (
          FunctionType, FunctionType, FunctionType, FunctionType,
          FunctionType, FunctionType, FunctionType, FunctionType
        )
    private var _count: Int

    init(_ arr: [FunctionType]) {
      let z = FunctionType.zero
      let row = (z, z, z, z, z, z, z, z)
      s0 = row
      s1 = row
      s2 = row
      s3 = row
      s4 = row
      s5 = row
      s6 = row
      s7 = row
      _count = 0
      for e in arr { append(e) }
    }

    var count: Int { _count }

    subscript(index: Int) -> FunctionType {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<FunctionType>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: FunctionType.self))
        }
      case 1:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: FunctionType.self))
        }
      case 2:
        return withUnsafeBytes(of: s2) {
          body($0.baseAddress!.assumingMemoryBound(to: FunctionType.self))
        }
      case 3:
        return withUnsafeBytes(of: s3) {
          body($0.baseAddress!.assumingMemoryBound(to: FunctionType.self))
        }
      case 4:
        return withUnsafeBytes(of: s4) {
          body($0.baseAddress!.assumingMemoryBound(to: FunctionType.self))
        }
      case 5:
        return withUnsafeBytes(of: s5) {
          body($0.baseAddress!.assumingMemoryBound(to: FunctionType.self))
        }
      case 6:
        return withUnsafeBytes(of: s6) {
          body($0.baseAddress!.assumingMemoryBound(to: FunctionType.self))
        }
      default:
        return withUnsafeBytes(of: s7) {
          body($0.baseAddress!.assumingMemoryBound(to: FunctionType.self))
        }
      }
    }

    // Direct inout assignment avoids withUnsafeMutableBytes on non-BitwiseCopyable FunctionType
    // (which holds [ValueType] arrays). Swift handles ARC correctly through named tuple assignment.
    private mutating func setElement(row: Int, col: Int, value: FunctionType) {
      switch row {
      case 0:
        switch col {
        case 0: s0.0 = value
        case 1: s0.1 = value
        case 2: s0.2 = value
        case 3: s0.3 = value
        case 4: s0.4 = value
        case 5: s0.5 = value
        case 6: s0.6 = value
        default: s0.7 = value
        }
      case 1:
        switch col {
        case 0: s1.0 = value
        case 1: s1.1 = value
        case 2: s1.2 = value
        case 3: s1.3 = value
        case 4: s1.4 = value
        case 5: s1.5 = value
        case 6: s1.6 = value
        default: s1.7 = value
        }
      case 2:
        switch col {
        case 0: s2.0 = value
        case 1: s2.1 = value
        case 2: s2.2 = value
        case 3: s2.3 = value
        case 4: s2.4 = value
        case 5: s2.5 = value
        case 6: s2.6 = value
        default: s2.7 = value
        }
      case 3:
        switch col {
        case 0: s3.0 = value
        case 1: s3.1 = value
        case 2: s3.2 = value
        case 3: s3.3 = value
        case 4: s3.4 = value
        case 5: s3.5 = value
        case 6: s3.6 = value
        default: s3.7 = value
        }
      case 4:
        switch col {
        case 0: s4.0 = value
        case 1: s4.1 = value
        case 2: s4.2 = value
        case 3: s4.3 = value
        case 4: s4.4 = value
        case 5: s4.5 = value
        case 6: s4.6 = value
        default: s4.7 = value
        }
      case 5:
        switch col {
        case 0: s5.0 = value
        case 1: s5.1 = value
        case 2: s5.2 = value
        case 3: s5.3 = value
        case 4: s5.4 = value
        case 5: s5.5 = value
        case 6: s5.6 = value
        default: s5.7 = value
        }
      case 6:
        switch col {
        case 0: s6.0 = value
        case 1: s6.1 = value
        case 2: s6.2 = value
        case 3: s6.3 = value
        case 4: s6.4 = value
        case 5: s6.5 = value
        case 6: s6.6 = value
        default: s6.7 = value
        }
      default:
        switch col {
        case 0: s7.0 = value
        case 1: s7.1 = value
        case 2: s7.2 = value
        case 3: s7.3 = value
        case 4: s7.4 = value
        case 5: s7.5 = value
        case 6: s7.6 = value
        default: s7.7 = value
        }
      }
    }

    private mutating func append(_ e: FunctionType) {
      precondition(_count < 64, "Fixed64_FunctionType overflow")
      let row = _count / 8
      let col = _count % 8
      setElement(row: row, col: col, value: e)
      _count += 1
    }
  #else
    // macOS: heap-allocated to keep WasmModule struct size small.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [FunctionType]  // TODO: Embedded Phase 5 — replace with tuple storage

    init(_ arr: [FunctionType]) { storage = arr }
    var count: Int { storage.count }
    subscript(index: Int) -> FunctionType { storage[index] }
  #endif
}

// MARK: Fixed64_UInt32

/// 64-slot fixed buffer for the Function section (max WasmLimits.maxFunctions = 64).
///
/// Embedded: tuple storage — no malloc.
/// macOS:    [UInt32] array (heap).
struct Fixed64_UInt32 {
  #if hasFeature(Embedded)
    private var s0, s1, s2, s3, s4, s5, s6,
      s7: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
    private var _count: Int

    init(_ arr: [UInt32]) {
      let row: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
        0, 0, 0, 0, 0, 0, 0, 0
      )
      s0 = row
      s1 = row
      s2 = row
      s3 = row
      s4 = row
      s5 = row
      s6 = row
      s7 = row
      _count = 0
      for e in arr { append(e) }
    }

    var count: Int { _count }

    subscript(index: Int) -> UInt32 {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<UInt32>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 1:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 2:
        return withUnsafeBytes(of: s2) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 3:
        return withUnsafeBytes(of: s3) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 4:
        return withUnsafeBytes(of: s4) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 5:
        return withUnsafeBytes(of: s5) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 6:
        return withUnsafeBytes(of: s6) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      default:
        return withUnsafeBytes(of: s7) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      }
    }

    private mutating func withMutableRow<R>(
      _ row: Int, _ body: (UnsafeMutablePointer<UInt32>) -> R
    ) -> R {
      switch row {
      case 0:
        return withUnsafeMutableBytes(of: &s0) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 1:
        return withUnsafeMutableBytes(of: &s1) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 2:
        return withUnsafeMutableBytes(of: &s2) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 3:
        return withUnsafeMutableBytes(of: &s3) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 4:
        return withUnsafeMutableBytes(of: &s4) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 5:
        return withUnsafeMutableBytes(of: &s5) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 6:
        return withUnsafeMutableBytes(of: &s6) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      default:
        return withUnsafeMutableBytes(of: &s7) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      }
    }

    private mutating func append(_ e: UInt32) {
      precondition(_count < 64, "Fixed64_UInt32 overflow")
      let row = _count / 8
      let col = _count % 8
      withMutableRow(row) { $0[col] = e }
      _count += 1
    }
  #else
    // macOS: heap-allocated.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [UInt32]  // TODO: Embedded Phase 5 — replace with tuple storage

    init(_ arr: [UInt32]) { storage = arr }
    var count: Int { storage.count }
    subscript(index: Int) -> UInt32 { storage[index] }
  #endif
}

// MARK: Fixed32_Import

/// 32-slot fixed buffer for the Import section (max WasmLimits.maxImports = 32).
///
/// Embedded: tuple storage — no malloc.
/// macOS:    [Import] array (heap).
struct Fixed32_Import {
  #if hasFeature(Embedded)
    private var s0, s1, s2, s3: (Import, Import, Import, Import, Import, Import, Import, Import)
    private var _count: Int

    init(_ arr: [Import]) {
      let z = Import.zero
      let row = (z, z, z, z, z, z, z, z)
      s0 = row
      s1 = row
      s2 = row
      s3 = row
      _count = 0
      for e in arr { append(e) }
    }

    var count: Int { _count }

    subscript(index: Int) -> Import {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<Import>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: Import.self))
        }
      case 1:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: Import.self))
        }
      case 2:
        return withUnsafeBytes(of: s2) {
          body($0.baseAddress!.assumingMemoryBound(to: Import.self))
        }
      default:
        return withUnsafeBytes(of: s3) {
          body($0.baseAddress!.assumingMemoryBound(to: Import.self))
        }
      }
    }

    // Direct inout assignment avoids withUnsafeMutableBytes on non-BitwiseCopyable Import
    // (which contains [UInt8] fields). Swift handles ARC correctly through named tuple assignment.
    private mutating func setElement(row: Int, col: Int, value: Import) {
      switch row {
      case 0:
        switch col {
        case 0: s0.0 = value
        case 1: s0.1 = value
        case 2: s0.2 = value
        case 3: s0.3 = value
        case 4: s0.4 = value
        case 5: s0.5 = value
        case 6: s0.6 = value
        default: s0.7 = value
        }
      case 1:
        switch col {
        case 0: s1.0 = value
        case 1: s1.1 = value
        case 2: s1.2 = value
        case 3: s1.3 = value
        case 4: s1.4 = value
        case 5: s1.5 = value
        case 6: s1.6 = value
        default: s1.7 = value
        }
      case 2:
        switch col {
        case 0: s2.0 = value
        case 1: s2.1 = value
        case 2: s2.2 = value
        case 3: s2.3 = value
        case 4: s2.4 = value
        case 5: s2.5 = value
        case 6: s2.6 = value
        default: s2.7 = value
        }
      default:
        switch col {
        case 0: s3.0 = value
        case 1: s3.1 = value
        case 2: s3.2 = value
        case 3: s3.3 = value
        case 4: s3.4 = value
        case 5: s3.5 = value
        case 6: s3.6 = value
        default: s3.7 = value
        }
      }
    }

    private mutating func append(_ e: Import) {
      precondition(_count < 32, "Fixed32_Import overflow")
      let row = _count / 8
      let col = _count % 8
      setElement(row: row, col: col, value: e)
      _count += 1
    }
  #else
    // macOS: heap-allocated.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [Import]  // TODO: Embedded Phase 5 — replace with tuple storage

    init(_ arr: [Import]) { storage = arr }
    var count: Int { storage.count }
    subscript(index: Int) -> Import { storage[index] }
  #endif
}

// MARK: Fixed32_Export

/// 32-slot fixed buffer for the Export section (max WasmLimits.maxExports = 32).
///
/// Embedded: tuple storage — no malloc.
/// macOS:    [Export] array (heap).
struct Fixed32_Export {
  #if hasFeature(Embedded)
    private var s0, s1, s2, s3: (Export, Export, Export, Export, Export, Export, Export, Export)
    private var _count: Int

    init(_ arr: [Export]) {
      let z = Export.zero
      let row = (z, z, z, z, z, z, z, z)
      s0 = row
      s1 = row
      s2 = row
      s3 = row
      _count = 0
      for e in arr { append(e) }
    }

    var count: Int { _count }

    subscript(index: Int) -> Export {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<Export>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: Export.self))
        }
      case 1:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: Export.self))
        }
      case 2:
        return withUnsafeBytes(of: s2) {
          body($0.baseAddress!.assumingMemoryBound(to: Export.self))
        }
      default:
        return withUnsafeBytes(of: s3) {
          body($0.baseAddress!.assumingMemoryBound(to: Export.self))
        }
      }
    }

    // Direct inout assignment avoids withUnsafeMutableBytes on non-BitwiseCopyable Export
    // (which holds nameBytes: [UInt8]). Swift handles ARC correctly through named tuple assignment.
    private mutating func setElement(row: Int, col: Int, value: Export) {
      switch row {
      case 0:
        switch col {
        case 0: s0.0 = value
        case 1: s0.1 = value
        case 2: s0.2 = value
        case 3: s0.3 = value
        case 4: s0.4 = value
        case 5: s0.5 = value
        case 6: s0.6 = value
        default: s0.7 = value
        }
      case 1:
        switch col {
        case 0: s1.0 = value
        case 1: s1.1 = value
        case 2: s1.2 = value
        case 3: s1.3 = value
        case 4: s1.4 = value
        case 5: s1.5 = value
        case 6: s1.6 = value
        default: s1.7 = value
        }
      case 2:
        switch col {
        case 0: s2.0 = value
        case 1: s2.1 = value
        case 2: s2.2 = value
        case 3: s2.3 = value
        case 4: s2.4 = value
        case 5: s2.5 = value
        case 6: s2.6 = value
        default: s2.7 = value
        }
      default:
        switch col {
        case 0: s3.0 = value
        case 1: s3.1 = value
        case 2: s3.2 = value
        case 3: s3.3 = value
        case 4: s3.4 = value
        case 5: s3.5 = value
        case 6: s3.6 = value
        default: s3.7 = value
        }
      }
    }

    private mutating func append(_ e: Export) {
      precondition(_count < 32, "Fixed32_Export overflow")
      let row = _count / 8
      let col = _count % 8
      setElement(row: row, col: col, value: e)
      _count += 1
    }
  #else
    // macOS: heap-allocated.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [Export]  // TODO: Embedded Phase 5 — replace with tuple storage

    init(_ arr: [Export]) { storage = arr }
    var count: Int { storage.count }
    subscript(index: Int) -> Export { storage[index] }
  #endif
}

// MARK: Fixed32_GlobalDef

/// 32-slot fixed buffer for the Global section (max WasmLimits.maxGlobals = 32).
///
/// Embedded: tuple storage — no malloc.
/// macOS:    [GlobalDef] array (heap).
struct Fixed32_GlobalDef {
  #if hasFeature(Embedded)
    private var s0, s1, s2,
      s3: (GlobalDef, GlobalDef, GlobalDef, GlobalDef, GlobalDef, GlobalDef, GlobalDef, GlobalDef)
    private var _count: Int

    init(_ arr: [GlobalDef]) {
      let z = GlobalDef.zero
      let row = (z, z, z, z, z, z, z, z)
      s0 = row
      s1 = row
      s2 = row
      s3 = row
      _count = 0
      for e in arr { append(e) }
    }

    var count: Int { _count }

    subscript(index: Int) -> GlobalDef {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<GlobalDef>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: GlobalDef.self))
        }
      case 1:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: GlobalDef.self))
        }
      case 2:
        return withUnsafeBytes(of: s2) {
          body($0.baseAddress!.assumingMemoryBound(to: GlobalDef.self))
        }
      default:
        return withUnsafeBytes(of: s3) {
          body($0.baseAddress!.assumingMemoryBound(to: GlobalDef.self))
        }
      }
    }

    private mutating func withMutableRow<R>(
      _ row: Int, _ body: (UnsafeMutablePointer<GlobalDef>) -> R
    ) -> R {
      switch row {
      case 0:
        return withUnsafeMutableBytes(of: &s0) {
          body($0.baseAddress!.assumingMemoryBound(to: GlobalDef.self))
        }
      case 1:
        return withUnsafeMutableBytes(of: &s1) {
          body($0.baseAddress!.assumingMemoryBound(to: GlobalDef.self))
        }
      case 2:
        return withUnsafeMutableBytes(of: &s2) {
          body($0.baseAddress!.assumingMemoryBound(to: GlobalDef.self))
        }
      default:
        return withUnsafeMutableBytes(of: &s3) {
          body($0.baseAddress!.assumingMemoryBound(to: GlobalDef.self))
        }
      }
    }

    private mutating func append(_ e: GlobalDef) {
      precondition(_count < 32, "Fixed32_GlobalDef overflow")
      let row = _count / 8
      let col = _count % 8
      withMutableRow(row) { $0[col] = e }
      _count += 1
    }
  #else
    // macOS: heap-allocated.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [GlobalDef]  // TODO: Embedded Phase 5 — replace with tuple storage

    init(_ arr: [GlobalDef]) { storage = arr }
    var count: Int { storage.count }
    subscript(index: Int) -> GlobalDef { storage[index] }
  #endif
}

// MARK: Fixed32_UInt32

/// 32-slot fixed buffer for importedFunctionTypeIndices (max WasmLimits.maxImports = 32).
///
/// Embedded: tuple storage — no malloc.
/// macOS:    [UInt32] array (heap).
struct Fixed32_UInt32 {
  #if hasFeature(Embedded)
    private var s0, s1, s2, s3: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
    private var _count: Int

    init(_ arr: [UInt32]) {
      let row: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
        0, 0, 0, 0, 0, 0, 0, 0
      )
      s0 = row
      s1 = row
      s2 = row
      s3 = row
      _count = 0
      for e in arr { append(e) }
    }

    var count: Int { _count }

    subscript(index: Int) -> UInt32 {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<UInt32>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 1:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 2:
        return withUnsafeBytes(of: s2) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      default:
        return withUnsafeBytes(of: s3) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      }
    }

    private mutating func withMutableRow<R>(
      _ row: Int, _ body: (UnsafeMutablePointer<UInt32>) -> R
    ) -> R {
      switch row {
      case 0:
        return withUnsafeMutableBytes(of: &s0) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 1:
        return withUnsafeMutableBytes(of: &s1) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      case 2:
        return withUnsafeMutableBytes(of: &s2) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      default:
        return withUnsafeMutableBytes(of: &s3) {
          body($0.baseAddress!.assumingMemoryBound(to: UInt32.self))
        }
      }
    }

    // fileprivate so WasmModule.init can build this buffer directly without
    // an intermediate [UInt32] heap allocation on the Embedded path.
    fileprivate mutating func append(_ e: UInt32) {
      precondition(_count < 32, "Fixed32_UInt32 overflow")
      let row = _count / 8
      let col = _count % 8
      withMutableRow(row) { $0[col] = e }
      _count += 1
    }
  #else
    // macOS: heap-allocated.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [UInt32]  // TODO: Embedded Phase 5 — replace with tuple storage

    init(_ arr: [UInt32]) { storage = arr }
    var count: Int { storage.count }
    subscript(index: Int) -> UInt32 { storage[index] }
    fileprivate mutating func append(_ e: UInt32) { storage.append(e) }
  #endif
}

// MARK: Fixed4_TableType

/// 4-slot fixed buffer for the Table section (max WasmLimits.maxTables = 4).
///
/// Embedded: tuple storage — no malloc.
/// macOS:    [TableType] array (heap).
struct Fixed4_TableType {
  #if hasFeature(Embedded)
    private var storage: (TableType, TableType, TableType, TableType)
    private var _count: Int

    init(_ arr: [TableType]) {
      let z = TableType.zero
      storage = (z, z, z, z)
      _count = 0
      for e in arr { append(e) }
    }

    var count: Int { _count }

    subscript(index: Int) -> TableType {
      precondition(index >= 0 && index < _count)
      return withUnsafeBytes(of: storage) {
        $0.baseAddress!.assumingMemoryBound(to: TableType.self)[index]
      }
    }

    private mutating func append(_ e: TableType) {
      precondition(_count < 4, "Fixed4_TableType overflow")
      withUnsafeMutableBytes(of: &storage) {
        $0.baseAddress!.assumingMemoryBound(to: TableType.self)[_count] = e
      }
      _count += 1
    }
  #else
    // macOS: heap-allocated.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [TableType]  // TODO: Embedded Phase 5 — replace with tuple storage

    init(_ arr: [TableType]) { storage = arr }
    var count: Int { storage.count }
    subscript(index: Int) -> TableType { storage[index] }
  #endif
}

// MARK: Fixed1_MemoryType

/// 1-slot fixed buffer for the Memory section (max WasmLimits.maxMemories = 1).
///
/// Embedded: Optional<MemoryType> storage — no malloc.
/// macOS:    [MemoryType] array (heap).
struct Fixed1_MemoryType {
  #if hasFeature(Embedded)
    private var _storage: MemoryType?
    private var _count: Int

    init(_ arr: [MemoryType]) {
      if let first = arr.first {
        _storage = first
        _count = 1
      } else {
        _storage = nil
        _count = 0
      }
    }

    var count: Int { _count }

    var first: MemoryType? { _storage }

    subscript(index: Int) -> MemoryType {
      precondition(index == 0 && _count == 1)
      return _storage!
    }
  #else
    // macOS: heap-allocated.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [MemoryType]  // TODO: Embedded Phase 5 — replace with Optional storage

    init(_ arr: [MemoryType]) { storage = arr }
    var count: Int { storage.count }
    var first: MemoryType? { storage.first }
    subscript(index: Int) -> MemoryType { storage[index] }
  #endif
}

// MARK: Fixed16_ElementSegment

/// 16-slot fixed buffer for the Element section (max WasmLimits.maxElements = 16).
///
/// Embedded: tuple storage — no malloc.
/// macOS:    [ElementSegment] array (heap).
struct Fixed16_ElementSegment {
  #if hasFeature(Embedded)
    private var s0,
      s1:
        (
          ElementSegment, ElementSegment, ElementSegment, ElementSegment,
          ElementSegment, ElementSegment, ElementSegment, ElementSegment
        )
    private var _count: Int

    init(_ arr: [ElementSegment]) {
      let z = ElementSegment.zero
      let row = (z, z, z, z, z, z, z, z)
      s0 = row
      s1 = row
      _count = 0
      for e in arr { append(e) }
    }

    var count: Int { _count }

    subscript(index: Int) -> ElementSegment {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<ElementSegment>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: ElementSegment.self))
        }
      default:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: ElementSegment.self))
        }
      }
    }

    // Direct inout assignment avoids withUnsafeMutableBytes on non-BitwiseCopyable ElementSegment
    // (which holds functionIndices: [UInt32?]). Swift handles ARC correctly through named tuple assignment.
    private mutating func setElement(row: Int, col: Int, value: ElementSegment) {
      switch row {
      case 0:
        switch col {
        case 0: s0.0 = value
        case 1: s0.1 = value
        case 2: s0.2 = value
        case 3: s0.3 = value
        case 4: s0.4 = value
        case 5: s0.5 = value
        case 6: s0.6 = value
        default: s0.7 = value
        }
      default:
        switch col {
        case 0: s1.0 = value
        case 1: s1.1 = value
        case 2: s1.2 = value
        case 3: s1.3 = value
        case 4: s1.4 = value
        case 5: s1.5 = value
        case 6: s1.6 = value
        default: s1.7 = value
        }
      }
    }

    private mutating func append(_ e: ElementSegment) {
      precondition(_count < 16, "Fixed16_ElementSegment overflow")
      let row = _count / 8
      let col = _count % 8
      setElement(row: row, col: col, value: e)
      _count += 1
    }
  #else
    // macOS: heap-allocated.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [ElementSegment]  // TODO: Embedded Phase 5 — replace with tuple storage

    init(_ arr: [ElementSegment]) { storage = arr }
    var count: Int { storage.count }
    subscript(index: Int) -> ElementSegment { storage[index] }
  #endif
}

// MARK: Fixed16_DataSegment

/// 16-slot fixed buffer for the Data section (max WasmLimits.maxData = 16).
///
/// Embedded: tuple storage — no malloc.
/// macOS:    [DataSegment] array (heap).
struct Fixed16_DataSegment {
  #if hasFeature(Embedded)
    private var s0,
      s1:
        (
          DataSegment, DataSegment, DataSegment, DataSegment,
          DataSegment, DataSegment, DataSegment, DataSegment
        )
    private var _count: Int

    init(_ arr: [DataSegment]) {
      let z = DataSegment.zero
      let row = (z, z, z, z, z, z, z, z)
      s0 = row
      s1 = row
      _count = 0
      for e in arr { append(e) }
    }

    var count: Int { _count }

    subscript(index: Int) -> DataSegment {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<DataSegment>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: DataSegment.self))
        }
      default:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: DataSegment.self))
        }
      }
    }

    // Direct inout assignment avoids withUnsafeMutableBytes on non-BitwiseCopyable DataSegment
    // (which holds bytes: [UInt8]). Swift handles ARC correctly through named tuple assignment.
    private mutating func setElement(row: Int, col: Int, value: DataSegment) {
      switch row {
      case 0:
        switch col {
        case 0: s0.0 = value
        case 1: s0.1 = value
        case 2: s0.2 = value
        case 3: s0.3 = value
        case 4: s0.4 = value
        case 5: s0.5 = value
        case 6: s0.6 = value
        default: s0.7 = value
        }
      default:
        switch col {
        case 0: s1.0 = value
        case 1: s1.1 = value
        case 2: s1.2 = value
        case 3: s1.3 = value
        case 4: s1.4 = value
        case 5: s1.5 = value
        case 6: s1.6 = value
        default: s1.7 = value
        }
      }
    }

    private mutating func append(_ e: DataSegment) {
      precondition(_count < 16, "Fixed16_DataSegment overflow")
      let row = _count / 8
      let col = _count % 8
      setElement(row: row, col: col, value: e)
      _count += 1
    }
  #else
    // macOS: heap-allocated.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [DataSegment]  // TODO: Embedded Phase 5 — replace with tuple storage

    init(_ arr: [DataSegment]) { storage = arr }
    var count: Int { storage.count }
    subscript(index: Int) -> DataSegment { storage[index] }
  #endif
}

// MARK: FixedLocals_ValueType

/// 32-slot fixed buffer for declared locals in a function body (max WasmLimits.maxLocalsPerFunction = 32).
///
/// ValueType is a UInt8 enum — BitwiseCopyable — so we can use withUnsafeBytes for reads.
/// Built incrementally via append(); no array initialiser because the parser builds it entry-by-entry.
///
/// Embedded: storage is 4 × 8-element sub-tuples of ValueType — no malloc.
/// macOS:    storage is [ValueType] (heap) — keeps struct size manageable.
struct FixedLocals_ValueType: Sendable {
  #if hasFeature(Embedded)
    // ValueType is a UInt8 enum — BitwiseCopyable — withUnsafeBytes is safe for reads.
    // Direct tuple assignment is used for writes (via setElement).
    private var s0, s1, s2,
      s3: (ValueType, ValueType, ValueType, ValueType, ValueType, ValueType, ValueType, ValueType)
    private var _count: Int

    init() {
      let z = ValueType.zero
      let row = (z, z, z, z, z, z, z, z)
      s0 = row
      s1 = row
      s2 = row
      s3 = row
      _count = 0
    }

    var count: Int { _count }

    subscript(index: Int) -> ValueType {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<ValueType>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: ValueType.self))
        }
      case 1:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: ValueType.self))
        }
      case 2:
        return withUnsafeBytes(of: s2) {
          body($0.baseAddress!.assumingMemoryBound(to: ValueType.self))
        }
      default:
        return withUnsafeBytes(of: s3) {
          body($0.baseAddress!.assumingMemoryBound(to: ValueType.self))
        }
      }
    }

    // Direct inout assignment — ValueType is BitwiseCopyable (UInt8 enum) so direct
    // tuple element assignment is correct and avoids any ARC overhead.
    private mutating func setElement(row: Int, col: Int, value: ValueType) {
      switch row {
      case 0:
        switch col {
        case 0: s0.0 = value
        case 1: s0.1 = value
        case 2: s0.2 = value
        case 3: s0.3 = value
        case 4: s0.4 = value
        case 5: s0.5 = value
        case 6: s0.6 = value
        default: s0.7 = value
        }
      case 1:
        switch col {
        case 0: s1.0 = value
        case 1: s1.1 = value
        case 2: s1.2 = value
        case 3: s1.3 = value
        case 4: s1.4 = value
        case 5: s1.5 = value
        case 6: s1.6 = value
        default: s1.7 = value
        }
      case 2:
        switch col {
        case 0: s2.0 = value
        case 1: s2.1 = value
        case 2: s2.2 = value
        case 3: s2.3 = value
        case 4: s2.4 = value
        case 5: s2.5 = value
        case 6: s2.6 = value
        default: s2.7 = value
        }
      default:
        switch col {
        case 0: s3.0 = value
        case 1: s3.1 = value
        case 2: s3.2 = value
        case 3: s3.3 = value
        case 4: s3.4 = value
        case 5: s3.5 = value
        case 6: s3.6 = value
        default: s3.7 = value
        }
      }
    }

    mutating func append(_ e: ValueType) {
      precondition(_count < 32, "FixedLocals_ValueType overflow")
      let row = _count / 8
      let col = _count % 8
      setElement(row: row, col: col, value: e)
      _count += 1
    }
  #else
    // macOS: heap-allocated to keep struct size manageable.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [ValueType]  // TODO: Embedded Phase 5 — replace with tuple storage

    init() { storage = [] }
    var count: Int { storage.count }
    subscript(index: Int) -> ValueType { storage[index] }
    mutating func append(_ e: ValueType) { storage.append(e) }
  #endif
}

// MARK: FixedJumpTable_JumpEntry

/// 64-slot fixed buffer for the jump table of a function body (max WasmLimits.maxJumpEntriesPerFunction = 64).
///
/// JumpEntry holds three UInt32 fields — BitwiseCopyable — so withUnsafeBytes is safe for reads.
/// Needs a mutable subscript setter for backpatching: the parser writes jumpTable[jumpEntryIdx] = JumpEntry(...)
/// after computing the final target addresses.
///
/// Embedded: storage is 8 × 8-element sub-tuples of JumpEntry — no malloc.
/// macOS:    storage is [JumpEntry] (heap) — keeps struct size manageable.
struct FixedJumpTable_JumpEntry: Sendable {
  #if hasFeature(Embedded)
    // JumpEntry is three UInt32 fields — BitwiseCopyable — withUnsafeBytes is safe for reads.
    // Direct tuple assignment is used for writes (via setElement).
    private var s0, s1, s2, s3, s4, s5, s6,
      s7: (JumpEntry, JumpEntry, JumpEntry, JumpEntry, JumpEntry, JumpEntry, JumpEntry, JumpEntry)
    private var _count: Int

    init() {
      let z = JumpEntry.zero
      let row = (z, z, z, z, z, z, z, z)
      s0 = row
      s1 = row
      s2 = row
      s3 = row
      s4 = row
      s5 = row
      s6 = row
      s7 = row
      _count = 0
    }

    var count: Int { _count }

    subscript(index: Int) -> JumpEntry {
      get {
        precondition(index >= 0 && index < _count)
        let row = index / 8
        let col = index % 8
        return withRow(row) { $0[col] }
      }
      set {
        precondition(index >= 0 && index < _count)
        let row = index / 8
        let col = index % 8
        setElement(row: row, col: col, value: newValue)
      }
    }

    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<JumpEntry>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: JumpEntry.self))
        }
      case 1:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: JumpEntry.self))
        }
      case 2:
        return withUnsafeBytes(of: s2) {
          body($0.baseAddress!.assumingMemoryBound(to: JumpEntry.self))
        }
      case 3:
        return withUnsafeBytes(of: s3) {
          body($0.baseAddress!.assumingMemoryBound(to: JumpEntry.self))
        }
      case 4:
        return withUnsafeBytes(of: s4) {
          body($0.baseAddress!.assumingMemoryBound(to: JumpEntry.self))
        }
      case 5:
        return withUnsafeBytes(of: s5) {
          body($0.baseAddress!.assumingMemoryBound(to: JumpEntry.self))
        }
      case 6:
        return withUnsafeBytes(of: s6) {
          body($0.baseAddress!.assumingMemoryBound(to: JumpEntry.self))
        }
      default:
        return withUnsafeBytes(of: s7) {
          body($0.baseAddress!.assumingMemoryBound(to: JumpEntry.self))
        }
      }
    }

    // Direct inout assignment — JumpEntry is BitwiseCopyable (three UInt32 fields) so direct
    // tuple element assignment is correct.
    private mutating func setElement(row: Int, col: Int, value: JumpEntry) {
      switch row {
      case 0:
        switch col {
        case 0: s0.0 = value
        case 1: s0.1 = value
        case 2: s0.2 = value
        case 3: s0.3 = value
        case 4: s0.4 = value
        case 5: s0.5 = value
        case 6: s0.6 = value
        default: s0.7 = value
        }
      case 1:
        switch col {
        case 0: s1.0 = value
        case 1: s1.1 = value
        case 2: s1.2 = value
        case 3: s1.3 = value
        case 4: s1.4 = value
        case 5: s1.5 = value
        case 6: s1.6 = value
        default: s1.7 = value
        }
      case 2:
        switch col {
        case 0: s2.0 = value
        case 1: s2.1 = value
        case 2: s2.2 = value
        case 3: s2.3 = value
        case 4: s2.4 = value
        case 5: s2.5 = value
        case 6: s2.6 = value
        default: s2.7 = value
        }
      case 3:
        switch col {
        case 0: s3.0 = value
        case 1: s3.1 = value
        case 2: s3.2 = value
        case 3: s3.3 = value
        case 4: s3.4 = value
        case 5: s3.5 = value
        case 6: s3.6 = value
        default: s3.7 = value
        }
      case 4:
        switch col {
        case 0: s4.0 = value
        case 1: s4.1 = value
        case 2: s4.2 = value
        case 3: s4.3 = value
        case 4: s4.4 = value
        case 5: s4.5 = value
        case 6: s4.6 = value
        default: s4.7 = value
        }
      case 5:
        switch col {
        case 0: s5.0 = value
        case 1: s5.1 = value
        case 2: s5.2 = value
        case 3: s5.3 = value
        case 4: s5.4 = value
        case 5: s5.5 = value
        case 6: s5.6 = value
        default: s5.7 = value
        }
      case 6:
        switch col {
        case 0: s6.0 = value
        case 1: s6.1 = value
        case 2: s6.2 = value
        case 3: s6.3 = value
        case 4: s6.4 = value
        case 5: s6.5 = value
        case 6: s6.6 = value
        default: s6.7 = value
        }
      default:
        switch col {
        case 0: s7.0 = value
        case 1: s7.1 = value
        case 2: s7.2 = value
        case 3: s7.3 = value
        case 4: s7.4 = value
        case 5: s7.5 = value
        case 6: s7.6 = value
        default: s7.7 = value
        }
      }
    }

    mutating func append(_ e: JumpEntry) {
      precondition(_count < 64, "FixedJumpTable_JumpEntry overflow")
      let row = _count / 8
      let col = _count % 8
      setElement(row: row, col: col, value: e)
      _count += 1
    }
  #else
    // macOS: heap-allocated to keep struct size manageable.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [JumpEntry]  // TODO: Embedded Phase 5 — replace with tuple storage

    init() { storage = [] }
    var count: Int { storage.count }
    subscript(index: Int) -> JumpEntry {
      get { storage[index] }
      set { storage[index] = newValue }
    }
    mutating func append(_ e: JumpEntry) { storage.append(e) }
  #endif
}

// MARK: - Module

/// A parsed Wasm module. Data is stored per section.
struct WasmModule: Sendable {
  let types: Fixed64_FunctionType  // Type section
  let imports: Fixed32_Import  // Import section
  let functions: Fixed64_UInt32  // Function section: type index for each local function
  let tables: Fixed4_TableType  // Table section
  let memories: Fixed1_MemoryType  // Memory section
  let globals: Fixed32_GlobalDef  // Global section
  let exports: Fixed32_Export  // Export section
  let code: [FunctionHandle]  // Code section: byte ranges with pre-computed jump tables
  // TODO: Embedded Phase 5 — replace [FunctionHandle] with fixed-size buffer
  let rawBytes: [UInt8]  // Original binary buffer retained for on-the-fly instruction decode
  // TODO: Embedded Phase 5 — consider zero-copy approach for rawBytes
  let start: UInt32?  // Start section
  let elements: Fixed16_ElementSegment  // Element section
  let data: Fixed16_DataSegment  // Data section

  /// Cached count of imported functions.
  /// The function index space is ordered as: imported functions (0..N-1), local functions (N..).
  let importedFunctionCount: Int

  /// Type indices for imported functions, in import order.
  /// Cached at init to avoid re-scanning imports on every call dispatch.
  private let importedFunctionTypeIndices: Fixed32_UInt32

  init(
    types: [FunctionType],
    imports: [Import] = [],
    functions: [UInt32],
    tables: [TableType] = [],
    memories: [MemoryType],
    globals: [GlobalDef] = [],
    exports: [Export],
    code: [FunctionHandle],
    start: UInt32? = nil,
    elements: [ElementSegment] = [],
    data: [DataSegment] = [],
    rawBytes: [UInt8]
  ) {
    self.types = Fixed64_FunctionType(types)
    self.imports = Fixed32_Import(imports)
    self.functions = Fixed64_UInt32(functions)
    self.tables = Fixed4_TableType(tables)
    self.memories = Fixed1_MemoryType(memories)
    self.globals = Fixed32_GlobalDef(globals)
    self.exports = Fixed32_Export(exports)
    self.code = code  // TODO: Embedded Phase 5 — replace with fixed-size buffer
    self.start = start
    self.elements = Fixed16_ElementSegment(elements)
    self.data = Fixed16_DataSegment(data)
    self.rawBytes = rawBytes  // TODO: Embedded Phase 5 — consider zero-copy approach

    // Build importedFunctionTypeIndices directly via fileprivate append (both platforms).
    // On Embedded this avoids an intermediate [UInt32] heap allocation;
    // on macOS Fixed32_UInt32.append delegates to [UInt32].append.
    var count = 0
    var typeIndices = Fixed32_UInt32([])
    for imp in imports {
      if case .function(let fi) = imp {
        typeIndices.append(fi.typeIndex)
        count += 1
      }
    }
    self.importedFunctionCount = count
    self.importedFunctionTypeIndices = typeIndices
  }

  /// Returns the FunctionType for the given function index (including imports).
  /// O(1): uses the cached type index array built at init.
  func functionType(at index: Int) -> FunctionType {
    if index < importedFunctionCount {
      return types[Int(importedFunctionTypeIndices[index])]
    }
    let localIdx = index - importedFunctionCount
    return types[Int(functions[localIdx])]
  }
}

// MARK: - Runtime Value

/// A value held on the stack or in locals at runtime
@frozen
enum Value: Sendable, Equatable {
  case i32(Int32)
  case i64(Int64)
  case f32(Float)
  case f64(Double)
  case funcref(UInt32?)  // nil = null reference; UInt32 = function index
  case externref(UInt32?)  // nil = null reference; UInt32 = opaque host index
}
