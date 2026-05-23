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
enum BlockType: Sendable {
  case void              // 0x40: no result
  case value(ValueType)  // 0x7F etc.: single result
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

// MARK: - Instructions

/// Instruction set supported by this interpreter
///
/// block/loop/if hold child instructions, so indirect cases are used.
/// In the macOS phase, indirect (heap allocation) is acceptable in favor of correctness.
enum Instruction: Sendable {
  case localGet(UInt32)                                                         // 0x20
  case localSet(UInt32)                                                         // 0x21
  case i32Const(Int32)                                                          // 0x41
  case i32Add                                                                   // 0x6A
  case i32Eq                                                                    // 0x46
  case i32GeS                                                                   // 0x4E: signed >=
  case i32RemU                                                                  // 0x70: unsigned remainder
  case call(UInt32)                                                             // 0x10: function call
  indirect case block(BlockType, [Instruction])                                 // 0x02
  indirect case loop(BlockType, [Instruction])                                  // 0x03
  indirect case ifElse(BlockType, thenBody: [Instruction], elseBody: [Instruction]) // 0x04
  case br(UInt32)                                                               // 0x0C
  case brIf(UInt32)                                                             // 0x0D
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
  let module: [UInt8]    // module name (UTF-8 bytes)
  let name: [UInt8]      // field name (UTF-8 bytes)
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
  let offset: Int32   // write offset into linear memory
  let bytes: [UInt8]  // data to write
}

// MARK: - Exports

enum ExportKind: UInt8, Sendable {
  case function = 0x00
  case table    = 0x01
  case memory   = 0x02
  case global   = 0x03
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
  let types: [FunctionType]    // Type section
  let imports: [Import]        // Import section
  let functions: [UInt32]      // Function section: type index for each local function
  let memories: [MemoryType]   // Memory section
  let exports: [Export]        // Export section
  let code: [FunctionBody]     // Code section
  let start: UInt32?           // Start section
  let data: [DataSegment]      // Data section

  init(
    types: [FunctionType],
    imports: [Import] = [],
    functions: [UInt32],
    memories: [MemoryType],
    exports: [Export],
    code: [FunctionBody],
    start: UInt32? = nil,
    data: [DataSegment] = []
  ) {
    self.types = types
    self.imports = imports
    self.functions = functions
    self.memories = memories
    self.exports = exports
    self.code = code
    self.start = start
    self.data = data
  }

  /// Number of imported functions in the Import section.
  /// The function index space is ordered as: imported functions (0..N-1), local functions (N..).
  var importedFunctionCount: Int {
    imports.reduce(0) { n, imp in
      if case .function = imp { return n + 1 }
      return n
    }
  }

  /// Returns the FunctionType for the given function index (including imports)
  func functionType(at index: Int) -> FunctionType {
    var funcImports: [FunctionImport] = []
    for imp in imports {
      if case .function(let fi) = imp { funcImports.append(fi) }
    }
    if index < funcImports.count {
      return types[Int(funcImports[index].typeIndex)]
    }
    let localIdx = index - funcImports.count
    return types[Int(functions[localIdx])]
  }
}

// MARK: - Runtime Value

/// A value held on the stack or in locals at runtime
enum Value: Sendable, Equatable {
  case i32(Int32)
}
