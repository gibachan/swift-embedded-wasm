// Core data types for the Wasm binary parser and interpreter

// MARK: - Value Types

enum ValueType: UInt8, Sendable {
  case i32 = 0x7F
  case i64 = 0x7E
  case f32 = 0x7D
  case f64 = 0x7C
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

/// An active element segment (flags=0) that initializes table entries at instantiation.
struct ElementSegment: Sendable {
  let tableIndex: UInt32
  let offset: Int32
  let functionIndices: [UInt32]
}

// MARK: - Instructions

/// Instruction set supported by this interpreter.
///
/// All control-flow instructions use flat bytecode with pre-computed jump offsets.
/// block/loop/if carry integer PCs computed during parsing — no indirect cases,
/// no nested arrays, no heap allocation required.
///
/// Flat control flow model:
///   block(bt, endPc)         — pushes a label; br to this label jumps to endPc
///   loop(bt, startPc)        — pushes a label; br to this label jumps to startPc (restart)
///   ifElse(bt, elsePc, endPc)— pops condition; jumps to elsePc if 0; br jumps to endPc
///   blockEnd                 — pops the top label (normal fall-through exit)
///   jump(pc)                 — unconditional jump (skips the else body in if/else)
enum Instruction: Sendable {
  case unreachable  // 0x00
  case nop  // 0x01
  // Flat structured control flow (no indirect cases; all PCs computed by parser)
  case block(BlockType, Int)  // 0x02: endPc = PC after blockEnd (br-continuation)
  case loop(BlockType, Int)  // 0x03: startPc = first body instruction (br restarts here)
  case ifElse(BlockType, Int, Int)  // 0x04: elsePc, endPc (br-continuation)
  case blockEnd  // marks end of block/loop/if body; pops the label
  case jump(Int)  // unconditional jump to PC (used to skip else body)
  case br(UInt32)  // 0x0C
  case brIf(UInt32)  // 0x0D
  case brTable([UInt32], UInt32)  // 0x0E: target_labels[], default_label
  case return_  // 0x0F
  case call(UInt32)  // 0x10
  // stack operations
  case drop  // 0x1A
  case select  // 0x1B
  // locals
  case localGet(UInt32)  // 0x20
  case localSet(UInt32)  // 0x21
  case localTee(UInt32)  // 0x22
  case globalGet(UInt32)  // 0x23
  case globalSet(UInt32)  // 0x24
  // constants
  case i32Const(Int32)  // 0x41
  case i64Const(Int64)  // 0x42
  case f32Const(Float)  // 0x43
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
  // Parsed but not yet implemented; throws invalidInstruction at runtime.
  case unimplemented(UInt8)
}

// MARK: - Function Body

struct FunctionBody: Sendable {
  /// Local variable types declared inside the function (separate from parameters)
  let locals: [ValueType]
  let instructions: [Instruction]

  init(locals: [ValueType], instructions: [Instruction]) {
    self.locals = locals
    self.instructions = instructions
  }
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

/// An initialization segment from the Data section (active form only)
struct DataSegment: Sendable {
  let offset: Int32  // write offset into linear memory
  let bytes: [UInt8]  // data to write
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

// MARK: - Module

/// A parsed Wasm module. Data is stored per section.
struct WasmModule: Sendable {
  let types: [FunctionType]  // Type section
  let imports: [Import]  // Import section
  let functions: [UInt32]  // Function section: type index for each local function
  let tables: [TableType]  // Table section
  let memories: [MemoryType]  // Memory section
  let globals: [GlobalDef]  // Global section
  let exports: [Export]  // Export section
  let code: [FunctionBody]  // Code section
  let start: UInt32?  // Start section
  let elements: [ElementSegment]  // Element section
  let data: [DataSegment]  // Data section

  /// Cached count of imported functions.
  /// The function index space is ordered as: imported functions (0..N-1), local functions (N..).
  let importedFunctionCount: Int

  /// Type indices for imported functions, in import order.
  /// Cached at init to avoid re-scanning imports on every call dispatch.
  private let importedFunctionTypeIndices: [UInt32]

  init(
    types: [FunctionType],
    imports: [Import] = [],
    functions: [UInt32],
    tables: [TableType] = [],
    memories: [MemoryType],
    globals: [GlobalDef] = [],
    exports: [Export],
    code: [FunctionBody],
    start: UInt32? = nil,
    elements: [ElementSegment] = [],
    data: [DataSegment] = []
  ) {
    self.types = types
    self.imports = imports
    self.functions = functions
    self.tables = tables
    self.memories = memories
    self.globals = globals
    self.exports = exports
    self.code = code
    self.start = start
    self.elements = elements
    self.data = data

    var count = 0
    var typeIndices: [UInt32] = []
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
enum Value: Sendable, Equatable {
  case i32(Int32)
  case i64(Int64)
  case f32(Float)
}
