// Wasm binary parser
//
// A Wasm binary is a sequence of sections.
// Each section has the format: [id: u8][size: u32(leb128)][content]
//
// Reference: https://webassembly.github.io/spec/core/binary/modules.html

struct WasmParser {
  private var stream: BufferStream

  init(_ buffer: UnsafeBufferPointer<UInt8>) {
    self.stream = BufferStream(buffer)
  }

  // MARK: - Public

  mutating func parse() throws(WasmError) -> WasmModule {
    try validateHeader()

    var types: [FunctionType] = []
    var imports: [Import] = []
    var functions: [UInt32] = []
    var tables: [TableType] = []
    var memories: [MemoryType] = []
    var globals: [GlobalDef] = []
    var exports: [Export] = []
    var code: [FunctionBody] = []
    var start: UInt32? = nil
    var elements: [ElementSegment] = []
    var data: [DataSegment] = []

    while !stream.isExhausted {
      let id = try readByte()
      let size = try readU32()

      switch id {
      case 1:  types     = try parseTypeSection()
      case 2:  imports   = try parseImportSection()
      case 3:  functions = try parseFunctionSection()
      case 4:  tables    = try parseTableSection()
      case 5:  memories  = try parseMemorySection()
      case 6:  globals   = try parseGlobalSection()
      case 7:  exports   = try parseExportSection()
      case 8:  start     = try parseStartSection()
      case 9:  elements  = try parseElementSection()
      case 10: code      = try parseCodeSection()
      case 11: data      = try parseDataSection()
      default:
        // Unknown sections are skipped by size (required by the Wasm spec for extensibility)
        for _ in 0..<Int(size) { _ = try readByte() }
      }
    }

    return WasmModule(
      types: types, imports: imports, functions: functions,
      tables: tables, memories: memories, globals: globals,
      exports: exports, code: code,
      start: start, elements: elements, data: data
    )
  }

  // MARK: - Header

  private mutating func validateHeader() throws(WasmError) {
    let magic: [UInt8] = [try readByte(), try readByte(), try readByte(), try readByte()]
    guard magic == wasmMagic else { throw .invalidMagic }

    let version: [UInt8] = [try readByte(), try readByte(), try readByte(), try readByte()]
    guard version == wasmVersion else { throw .invalidVersion }
  }

  // MARK: - Section Parsers

  /// Type section (id=1): array of function signatures
  ///
  /// Format: [count] ([0x60][params][results])*
  private mutating func parseTypeSection() throws(WasmError) -> [FunctionType] {
    let count = try readU32()
    var types: [FunctionType] = []
    for _ in 0..<count {
      // 0x60 is the functype marker byte
      let marker = try readByte()
      guard marker == 0x60 else { throw .invalidValueType(marker) }

      let paramCount = try readU32()
      var params: [ValueType] = []
      for _ in 0..<paramCount { params.append(try readValueType()) }

      let resultCount = try readU32()
      var results: [ValueType] = []
      for _ in 0..<resultCount { results.append(try readValueType()) }

      types.append(FunctionType(params: params, results: results))
    }
    return types
  }

  /// Import section (id=2): array of externally provided functions, memories, etc.
  ///
  /// Imported functions occupy the front of the function index space;
  /// local functions follow after them.
  private mutating func parseImportSection() throws(WasmError) -> [Import] {
    let count = try readU32()
    var imports: [Import] = []
    for _ in 0..<count {
      let modLen = try readU32()
      var modBytes: [UInt8] = []
      for _ in 0..<modLen { modBytes.append(try readByte()) }

      let nameLen = try readU32()
      var nameBytes: [UInt8] = []
      for _ in 0..<nameLen { nameBytes.append(try readByte()) }

      let kind = try readByte()
      switch kind {
      case 0x00:  // function import: read type index
        let typeIndex = try readU32()
        imports.append(.function(FunctionImport(module: modBytes, name: nameBytes, typeIndex: typeIndex)))
      case 0x02:  // memory import: read limits
        let (min, max) = try parseMemoryLimits()
        imports.append(.memory(MemoryImport(module: modBytes, name: nameBytes, type: MemoryType(min: min, max: max))))
      default:
        throw .invalidImportKind(kind)
      }
    }
    return imports
  }

  /// Table section (id=4): table definitions (e.g. funcref tables for call_indirect)
  ///
  /// Format: [count] ([reftype][limits])*
  private mutating func parseTableSection() throws(WasmError) -> [TableType] {
    let count = try readU32()
    var tables: [TableType] = []
    for _ in 0..<count {
      let refTypeByte = try readByte()
      guard let refType = RefType(rawValue: refTypeByte) else {
        throw .invalidRefType(refTypeByte)
      }
      let (min, max) = try parseMemoryLimits()
      tables.append(TableType(refType: refType, min: min, max: max))
    }
    return tables
  }

  /// Memory section (id=5): linear memory definitions
  private mutating func parseMemorySection() throws(WasmError) -> [MemoryType] {
    let count = try readU32()
    var memories: [MemoryType] = []
    for _ in 0..<count {
      let (min, max) = try parseMemoryLimits()
      memories.append(MemoryType(min: min, max: max))
    }
    return memories
  }

  /// Reads memory limits (min and optional max page count)
  private mutating func parseMemoryLimits() throws(WasmError) -> (min: UInt32, max: UInt32?) {
    let limtype = try readByte()
    let min = try readU32()
    switch limtype {
    case 0x00: return (min, nil)
    case 0x01: return (min, try readU32())
    default:   throw .invalidLimitType(limtype)
    }
  }

  /// Global section (id=6): mutable/immutable global variable definitions
  ///
  /// Format: [count] ([valtype][mutability][init_expr])*
  /// init_expr is a constant expression: i32.const <val> end (only i32 supported for now)
  private mutating func parseGlobalSection() throws(WasmError) -> [GlobalDef] {
    let count = try readU32()
    var globals: [GlobalDef] = []
    for _ in 0..<count {
      let vt = try readValueType()
      let mutByte = try readByte()
      guard let mut = GlobalMutability(rawValue: mutByte) else {
        throw .invalidMutability(mutByte)
      }
      // Constant init expression: currently only i32.const <val> end
      let opcode = try readByte()
      let initValue: Value
      switch opcode {
      case 0x41: initValue = .i32(try readI32())
      default:   throw .invalidInstruction(opcode)
      }
      let endOp = try readByte()
      guard endOp == 0x0B else { throw .invalidInstruction(endOp) }
      globals.append(GlobalDef(type: GlobalType(valueType: vt, mutability: mut), initValue: initValue))
    }
    return globals
  }

  /// Element section (id=9): active table initialization segments
  ///
  /// Only MVP format (flags=0) is supported: active, table 0, i32.const offset, function indices.
  private mutating func parseElementSection() throws(WasmError) -> [ElementSegment] {
    let count = try readU32()
    var segments: [ElementSegment] = []
    for _ in 0..<count {
      let flags = try readU32()
      guard flags == 0 else { throw .unsupportedElementSegment }

      let constOp = try readByte()
      guard constOp == 0x41 else { throw .invalidInstruction(constOp) }
      let offset = try readI32()
      let endOp = try readByte()
      guard endOp == 0x0B else { throw .invalidInstruction(endOp) }

      let funcCount = try readU32()
      var funcIndices: [UInt32] = []
      for _ in 0..<funcCount { funcIndices.append(try readU32()) }
      segments.append(ElementSegment(tableIndex: 0, offset: offset, functionIndices: funcIndices))
    }
    return segments
  }

  /// Function section (id=3): type index for each local function
  private mutating func parseFunctionSection() throws(WasmError) -> [UInt32] {
    let count = try readU32()
    var indices: [UInt32] = []
    for _ in 0..<count { indices.append(try readU32()) }
    return indices
  }

  /// Export section (id=7): array of externally visible symbols
  ///
  /// Format: [count] ([name_len][name_bytes][kind][index])*
  private mutating func parseExportSection() throws(WasmError) -> [Export] {
    let count = try readU32()
    var exports: [Export] = []
    for _ in 0..<count {
      let nameLen = try readU32()
      var nameBytes: [UInt8] = []
      for _ in 0..<Int(nameLen) { nameBytes.append(try readByte()) }

      let kindByte = try readByte()
      guard let kind = ExportKind(rawValue: kindByte) else {
        throw .invalidExportKind(kindByte)
      }

      let index = try readU32()
      exports.append(Export(nameBytes: nameBytes, kind: kind, index: index))
    }
    return exports
  }

  /// Start section (id=8): index of the function to run automatically at instantiation
  private mutating func parseStartSection() throws(WasmError) -> UInt32 {
    return try readU32()
  }

  /// Code section (id=10): array of function bodies
  ///
  /// Format: [count] ([body_size][local_decls][instructions... end])*
  ///
  /// local_decls are run-length encoded as (count, type) pairs.
  /// Example: "3 i32s and 1 i64" → [(3, i32), (1, i64)]
  private mutating func parseCodeSection() throws(WasmError) -> [FunctionBody] {
    let count = try readU32()
    var bodies: [FunctionBody] = []
    for _ in 0..<count {
      let bodySize = try readU32()

      let localDeclCount = try readU32()
      var locals: [ValueType] = []
      for _ in 0..<localDeclCount {
        let n = try readU32()
        let vt = try readValueType()
        // Reject malformed files claiming more locals than the body_size can encode.
        // body_size is an upper bound on bytes in this function body.
        guard n <= bodySize else { throw .unexpectedEnd }
        for _ in 0..<n { locals.append(vt) }
      }

      let instructions = try parseInstructions()
      bodies.append(FunctionBody(locals: locals, instructions: instructions))
    }
    return bodies
  }

  /// Data section (id=11): array of initial data segments for linear memory
  ///
  /// Only active segments (flags=0) are supported (MVP).
  /// Format: flags=0, i32.const offset end, data bytes
  private mutating func parseDataSection() throws(WasmError) -> [DataSegment] {
    let count = try readU32()
    var segments: [DataSegment] = []
    for _ in 0..<count {
      _ = try readU32()  // flags: 0 = active, memory index 0

      // Constant offset expression: i32.const <value> end
      let constOp = try readByte()
      guard constOp == 0x41 else { throw .invalidInstruction(constOp) }
      let offset = try readI32()
      let endOp = try readByte()
      guard endOp == 0x0B else { throw .invalidInstruction(endOp) }

      let byteLen = try readU32()
      var bytes: [UInt8] = []
      for _ in 0..<byteLen { bytes.append(try readByte()) }
      segments.append(DataSegment(offset: offset, bytes: bytes))
    }
    return segments
  }

  // MARK: - Instruction Parsing

  /// Parses instructions until 0x0B (end) and returns them
  private mutating func parseInstructions() throws(WasmError) -> [Instruction] {
    let (instructions, _) = try parseBody()
    return instructions
  }

  /// Parses instructions until 0x0B (end) or 0x05 (else).
  /// Returns the instructions and a Bool that is true if parsing stopped at else.
  ///
  /// Used when parsing if to distinguish whether an else clause is present.
  private mutating func parseBody() throws(WasmError) -> ([Instruction], stoppedAtElse: Bool) {
    var instructions: [Instruction] = []
    while true {
      let opcode = try readByte()
      switch opcode {

      case 0x02:  // block
        let bt = try readBlockType()
        instructions.append(.block(bt, try parseInstructions()))

      case 0x03:  // loop
        let bt = try readBlockType()
        instructions.append(.loop(bt, try parseInstructions()))

      case 0x04:  // if [else] end
        let bt = try readBlockType()
        let (thenBody, hadElse) = try parseBody()
        let elseBody: [Instruction]
        if hadElse {
          let (eb, _) = try parseBody()
          elseBody = eb
        } else {
          elseBody = []
        }
        instructions.append(.ifElse(bt, thenBody: thenBody, elseBody: elseBody))

      case 0x05:  // else: terminates the then-body
        return (instructions, stoppedAtElse: true)

      case 0x0B:  // end: terminates a block or function
        return (instructions, stoppedAtElse: false)

      case 0x0C:  // br
        instructions.append(.br(try readU32()))

      case 0x0D:  // br_if
        instructions.append(.brIf(try readU32()))

      case 0x10:  // call
        instructions.append(.call(try readU32()))

      case 0x20:  // local.get
        instructions.append(.localGet(try readU32()))

      case 0x21:  // local.set
        instructions.append(.localSet(try readU32()))

      case 0x23:  // global.get
        instructions.append(.globalGet(try readU32()))

      case 0x24:  // global.set
        instructions.append(.globalSet(try readU32()))

      case 0x41:  // i32.const (signed LEB128)
        instructions.append(.i32Const(try readI32()))

      case 0x46:  // i32.eq
        instructions.append(.i32Eq)

      case 0x4E:  // i32.ge_s
        instructions.append(.i32GeS)

      case 0x6A:  // i32.add
        instructions.append(.i32Add)

      case 0x6B:  // i32.sub
        instructions.append(.i32Sub)

      case 0x70:  // i32.rem_u
        instructions.append(.i32RemU)

      default:
        throw .invalidInstruction(opcode)
      }
    }
  }

  private mutating func readBlockType() throws(WasmError) -> BlockType {
    let byte = try readByte()
    if byte == 0x40 { return .void }
    guard let vt = ValueType(rawValue: byte) else { throw .invalidValueType(byte) }
    return .value(vt)
  }

  // MARK: - Primitives

  @inline(__always)
  private mutating func readByte() throws(WasmError) -> UInt8 {
    do {
      return try stream.consume()
    } catch {
      throw .unexpectedEnd
    }
  }

  @inline(__always)
  private mutating func readU32() throws(WasmError) -> UInt32 {
    do {
      return try decodeULEB128(from: &stream)
    } catch {
      throw .leb128Error(error)
    }
  }

  @inline(__always)
  private mutating func readI32() throws(WasmError) -> Int32 {
    do {
      return try decodeSLEB128(from: &stream)
    } catch {
      throw .leb128Error(error)
    }
  }

  private mutating func readValueType() throws(WasmError) -> ValueType {
    let byte = try readByte()
    guard let vt = ValueType(rawValue: byte) else { throw .invalidValueType(byte) }
    return vt
  }
}
