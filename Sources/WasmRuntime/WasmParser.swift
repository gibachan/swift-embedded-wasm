// Wasm binary parser
//
// A Wasm binary is a sequence of sections.
// Each section has the format: [id: u8][size: u32(leb128)][content]
//
// Reference: https://webassembly.github.io/spec/core/binary/modules.html

// Stack entry used by parseFlatBodyTracked to track open block/loop/if scopes
// without recursive calls.  Each case stores only the values needed for backpatching
// when the matching `end` (or `else`) byte is encountered.
//
// No indirect cases, no class storage — plain value enum.
private enum PendingBlock {
  // A `block` instruction awaiting its `end`; stores the pc of the block header instruction
  // so that endPc can be backpatched, plus the jumpTable slot for byte-offset backpatch.
  case block(
    headerPc: Int, bt: BlockType, brArity: Int, paramCount: Int,
    jumpEntryIdx: Int, opcodeByteOffset: UInt32)
  // A `loop` instruction: startPc and the full JumpEntry are baked in at parse time;
  // no backpatch is required at `end`.
  case loop
  // An `if` without an `else` yet; stores the header pc and jumpTable slot for
  // backpatching both elsePc/endPc and the byte-offset targets when `else` or `end` arrives.
  case ifThen(
    headerPc: Int, bt: BlockType, brArity: Int, paramCount: Int,
    jumpEntryIdx: Int, opcodeByteOffset: UInt32)
  // An `if` after `else` has been seen; stores header pc (for ifElse backpatch),
  // jumpPc (the `.jump` placeholder in the then-path), elsePc (first instruction of
  // the else body), elseByteOffset (byte position for JumpEntry.target1), and the
  // jumpTable slot for final backpatching at `end`.
  case ifElse(
    headerPc: Int, jumpPc: Int, elsePc: Int,
    bt: BlockType, brArity: Int, paramCount: Int,
    jumpEntryIdx: Int, opcodeByteOffset: UInt32, elseByteOffset: UInt32)
}

struct WasmParser {
  private var stream: BufferStream
  // Retain the original buffer so that Embedded builds can re-scan function body
  // byte ranges for lazy decode (FunctionHandle) without re-allocating.
  private let buffer: UnsafeBufferPointer<UInt8>
  // Type section contents, populated during parse() before the code section is reached.
  // Used by parseFlatBody / parseFlatBodyTracked to pre-compute block/loop/if arity at
  // parse time, eliminating the runtime module.types lookup in the interpreter hot path.
  private var types: [FunctionType] = []

  init(_ buffer: UnsafeBufferPointer<UInt8>) {
    self.buffer = buffer
    self.stream = BufferStream(buffer)
  }

  // MARK: - Block arity helpers (parse-time pre-computation)

  /// Returns (brArity, paramCount) for a block/if instruction from its BlockType.
  ///
  /// brArity   = result count of the block type (carried on br / fall-through).
  /// paramCount = parameter count (consumed and re-pushed when entering the block).
  private func blockArityForBlock(_ bt: BlockType) throws(WasmError) -> (
    brArity: Int, paramCount: Int
  ) {
    switch bt {
    case .void: return (brArity: 0, paramCount: 0)
    case .value: return (brArity: 1, paramCount: 0)
    case .typeIndex(let idx):
      guard Int(idx) < types.count else { throw WasmError.typeMismatch }
      let ft = types[Int(idx)]
      return (brArity: ft.results.count, paramCount: ft.params.count)
    }
  }

  /// Returns the brArity for a loop instruction from its BlockType.
  ///
  /// For loops, `br` restarts the loop — the continuation takes the loop's *parameters*,
  /// not its results.  So brArity = param count of the block type.
  private func loopBrArityFromBlockType(_ bt: BlockType) throws(WasmError) -> Int {
    switch bt {
    case .void: return 0
    case .value: return 0  // single-result loop has 0 params → br restarts with 0 values
    case .typeIndex(let idx):
      guard Int(idx) < types.count else { throw WasmError.typeMismatch }
      return types[Int(idx)].params.count
    }
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
    var code: [FunctionHandle] = []
    var start: UInt32? = nil
    var elements: [ElementSegment] = []
    var data: [DataSegment] = []
    // dataCount is the value from the optional Data Count section (id=12).
    // When present it must equal the number of data segments in the Data section.
    // It is also required when any bulk-memory instruction (memory.init / data.drop)
    // appears in the code section.
    var dataCount: UInt32? = nil

    // Section ordering / duplicate detection.
    // The Wasm spec requires non-custom sections to appear in ascending id order,
    // each at most once. We track the highest non-custom id seen so far.
    var lastNonCustomSectionId: UInt8 = 0

    while !stream.isExhausted {
      let id = try readByte()
      let size = try readU32()

      // Record the stream offset before parsing the section content so we can
      // verify that the parser consumed exactly `size` bytes (§5.5.2).
      let sectionStart = stream.offset

      // Section id validation and ordering / duplicate checks.
      // Custom sections (id=0) may appear anywhere in any quantity.
      // Data Count section (id=12) is valid; ids > 12 are malformed.
      if id > 12 {
        throw .malformedSectionId
      }
      if id != 0 {
        // Non-custom section: must appear in strictly ascending order and only once.
        if id < lastNonCustomSectionId {
          throw .sectionOutOfOrder
        }
        if id == lastNonCustomSectionId {
          throw .duplicateSection
        }
        lastNonCustomSectionId = id
      }

      switch id {
      case 0: try parseCustomSection(size: Int(size))  // custom section: validate name UTF-8
      case 1:
        let parsedTypes = try parseTypeSection()
        types = parsedTypes  // local: passed to WasmModule
        self.types = parsedTypes  // stored field: used by parseFlatBody for arity pre-computation
      case 2: imports = try parseImportSection()
      case 3: functions = try parseFunctionSection()
      case 4: tables = try parseTableSection()
      case 5: memories = try parseMemorySection()
      case 6: globals = try parseGlobalSection()
      case 7: exports = try parseExportSection()
      case 8: start = try parseStartSection()
      case 9: elements = try parseElementSection()
      case 10: code = try parseFunctionHandles()
      case 11: data = try parseDataSection()
      case 12:
        // Data Count section (§5.5.15): a single u32 that must equal the number of
        // data segments in the Data section. Required when bulk-memory instructions
        // (memory.init / data.drop) reference data segments.
        dataCount = try readU32()
      default:
        // Unreachable: id > 12 is rejected above; all ids 0-12 are handled.
        for _ in 0..<Int(size) { _ = try readByte() }
      }

      // Verify that the section parser consumed exactly `size` bytes (§5.5.2).
      // Custom sections (id=0) manage their own byte consumption internally.
      if id != 0 {
        let consumed = stream.offset - sectionStart
        guard consumed == Int(size) else { throw .sectionSizeMismatch }
      }
    }

    // Cross-section consistency checks performed after all sections are parsed.

    // Data Count section vs actual data segment count must match (§5.5.15).
    if let declared = dataCount {
      guard declared == UInt32(data.count) else { throw .dataCountMismatch }
    }

    // If any bulk-memory instruction (memory.init or data.drop) is present in the
    // code section, the Data Count section is required (§5.5.15, §A.2).
    // Use explicit loops instead of nested closures to avoid heap-capturing closures
    // that are not supported in Embedded Swift.
    var hasBulkMemoryInstruction = false
    for body in code {
      if body.hasBulkMemoryInstruction {
        hasBulkMemoryInstruction = true
        break
      }
    }
    if hasBulkMemoryInstruction && dataCount == nil {
      throw .dataCountRequired
    }

    let module = WasmModule(
      types: types, imports: imports, functions: functions,
      tables: tables, memories: memories, globals: globals,
      exports: exports, code: code,
      start: start, elements: elements, data: data,
      rawBytes: Array(buffer)
    )
    #if !hasFeature(Embedded)
      try WasmValidator(module: module).validate()
    #endif
    return module
  }

  // MARK: - Header

  private mutating func validateHeader() throws(WasmError) {
    let magic: [UInt8] = [try readByte(), try readByte(), try readByte(), try readByte()]
    guard magic == wasmMagic else { throw .invalidMagic }

    let version: [UInt8] = [try readByte(), try readByte(), try readByte(), try readByte()]
    guard version == wasmVersion else { throw .invalidVersion }
  }

  // MARK: - Section Parsers

  /// Custom section (id=0): name + arbitrary bytes.
  ///
  /// The Wasm spec (§5.5.3) requires the section name to be a valid UTF-8 string.
  /// We validate the name and skip the section payload, as the runtime does not
  /// use custom section content.
  private mutating func parseCustomSection(size: Int) throws(WasmError) {
    // Read the name length and name bytes within the section.
    // We must be careful: 'size' includes the name-length field and name bytes.
    let startOffset = stream.offset
    let nameLen = try readU32()
    var nameBytes: [UInt8] = []
    for _ in 0..<nameLen { nameBytes.append(try readByte()) }

    // Validate the section name is well-formed UTF-8 (Wasm spec §5.5.3).
    try validateUTF8(nameBytes)

    // Skip the rest of the custom section payload.
    let consumed = stream.offset - startOffset
    let remaining = size - consumed
    guard remaining >= 0 else { throw .unexpectedEnd }
    for _ in 0..<remaining { _ = try readByte() }
  }

  /// Validates that `bytes` is a valid UTF-8 sequence.
  ///
  /// Checks:
  ///   - Each sequence starts with a valid leading byte.
  ///   - Continuation bytes are present and well-formed (0x80..0xBF).
  ///   - No overlong encodings (e.g. 0xC0 0x80 for U+0000).
  ///   - No surrogate pairs (U+D800..U+DFFF).
  ///   - Code points are within the valid Unicode range (≤ U+10FFFF).
  private func validateUTF8(_ bytes: [UInt8]) throws(WasmError) {
    var i = 0
    while i < bytes.count {
      let b = bytes[i]
      let seqLen: Int
      if b & 0x80 == 0 {
        // ASCII: U+0000..U+007F
        seqLen = 1
      } else if b & 0xE0 == 0xC0 {
        // 2-byte sequence: U+0080..U+07FF
        seqLen = 2
      } else if b & 0xF0 == 0xE0 {
        // 3-byte sequence: U+0800..U+FFFF
        seqLen = 3
      } else if b & 0xF8 == 0xF0 {
        // 4-byte sequence: U+10000..U+10FFFF
        seqLen = 4
      } else {
        // Invalid leading byte (0x80..0xBF continuation or 0xF8..0xFF)
        throw .malformedUTF8
      }

      guard i + seqLen <= bytes.count else { throw .malformedUTF8 }

      // Validate continuation bytes (all must be 0x80..0xBF)
      for j in 1..<seqLen {
        guard bytes[i + j] & 0xC0 == 0x80 else { throw .malformedUTF8 }
      }

      // Decode code point and check for overlong encodings and surrogates.
      switch seqLen {
      case 2:
        let cp = (UInt32(b & 0x1F) << 6) | UInt32(bytes[i + 1] & 0x3F)
        // Overlong: must be >= 0x80 (otherwise it should be encoded as 1 byte)
        guard cp >= 0x80 else { throw .malformedUTF8 }
      case 3:
        let cp =
          (UInt32(b & 0x0F) << 12) | (UInt32(bytes[i + 1] & 0x3F) << 6)
          | UInt32(bytes[i + 2] & 0x3F)
        // Overlong: must be >= 0x800; surrogates U+D800..U+DFFF are forbidden
        guard cp >= 0x800 && !(cp >= 0xD800 && cp <= 0xDFFF) else { throw .malformedUTF8 }
      case 4:
        let cp =
          (UInt32(b & 0x07) << 18) | (UInt32(bytes[i + 1] & 0x3F) << 12)
          | (UInt32(bytes[i + 2] & 0x3F) << 6) | UInt32(bytes[i + 3] & 0x3F)
        // Overlong: must be >= 0x10000; must not exceed U+10FFFF
        guard cp >= 0x10000 && cp <= 0x10FFFF else { throw .malformedUTF8 }
      default:
        break  // seqLen == 1 (ASCII): always valid
      }

      i += seqLen
    }
  }

  /// Type section (id=1): array of function signatures
  ///
  /// Format: [count] ([0x60][params][results])*
  private mutating func parseTypeSection() throws(WasmError) -> [FunctionType] {
    let count = try readU32()
    guard count <= WasmLimits.maxTypes else { throw .resourceLimitExceeded }
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
    guard count <= WasmLimits.maxImports else { throw .resourceLimitExceeded }
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
        imports.append(
          .function(FunctionImport(module: modBytes, name: nameBytes, typeIndex: typeIndex)))
      case 0x02:  // memory import: read limits
        let (min, max) = try parseMemoryLimits()
        imports.append(
          .memory(
            MemoryImport(module: modBytes, name: nameBytes, type: MemoryType(min: min, max: max))))
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
    guard count <= WasmLimits.maxTables else { throw .resourceLimitExceeded }
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
    guard count <= WasmLimits.maxMemories else { throw .resourceLimitExceeded }
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
    default: throw .invalidLimitType(limtype)
    }
  }

  /// Global section (id=6): mutable/immutable global variable definitions
  ///
  /// Format: [count] ([valtype][mutability][init_expr])*
  /// init_expr is a constant expression followed by end (0x0B).
  private mutating func parseGlobalSection() throws(WasmError) -> [GlobalDef] {
    let count = try readU32()
    guard count <= WasmLimits.maxGlobals else { throw .resourceLimitExceeded }
    var globals: [GlobalDef] = []
    for _ in 0..<count {
      let vt = try readValueType()
      let mutByte = try readByte()
      guard let mut = GlobalMutability(rawValue: mutByte) else {
        throw .invalidMutability(mutByte)
      }
      let opcode = try readByte()
      let initValue: Value
      switch opcode {
      case 0x41: initValue = .i32(try readI32())
      case 0x42: initValue = .i64(try readI64())
      case 0x43: initValue = .f32(try readF32())
      case 0x44: initValue = .f64(try readF64())
      case 0xD0:  // ref.null: null funcref/externref
        let refByte = try readByte()  // reftype byte (0x70 = funcref, 0x6F = externref)
        guard let refType = RefType(rawValue: refByte) else {
          throw .invalidRefType(refByte)
        }
        initValue = refType == .funcRef ? .funcref(nil) : .externref(nil)
      case 0xD2:  // ref.func: non-null funcref for the given function index
        let funcIdx = try readU32()
        initValue = .funcref(funcIdx)
      default: throw .invalidInstruction(opcode)
      }
      let endOp = try readByte()
      guard endOp == 0x0B else { throw .invalidInstruction(endOp) }
      globals.append(
        GlobalDef(type: GlobalType(valueType: vt, mutability: mut), initValue: initValue))
    }
    return globals
  }

  /// Element section (id=9): table initialization segments
  ///
  /// Supported flags (Wasm 2.0 encoding):
  ///   0 — active, table 0, i32.const offset, function indices (MVP)
  ///   1 — passive, elemkind(0x00), function indices
  ///   2 — active, explicit table index, i32.const offset, elemkind(0x00), function indices
  ///   3 — declarative, elemkind(0x00), init_expr* list (ref.func / ref.null per element)
  ///   4 — active, table 0, i32.const offset, init_expr* list
  ///   5 — passive, reftype byte, init_expr* list
  ///   6 — active, explicit table index, offset expr, reftype byte, init_expr* list
  ///   7 — declarative, reftype byte, init_expr* list
  private mutating func parseElementSection() throws(WasmError) -> [ElementSegment] {
    let count = try readU32()
    guard count <= WasmLimits.maxElements else { throw .resourceLimitExceeded }
    var segments: [ElementSegment] = []
    for _ in 0..<count {
      let flags = try readU32()
      switch flags {
      case 0:
        // MVP: active, table 0, i32.const offset, funcidx list
        let constOp = try readByte()
        guard constOp == 0x41 else { throw .invalidInstruction(constOp) }
        let offset = try readI32()
        let endOp = try readByte()
        guard endOp == 0x0B else { throw .invalidInstruction(endOp) }
        let funcCount = try readU32()
        var funcIndices: [UInt32?] = []
        for _ in 0..<funcCount { funcIndices.append(try readU32()) }
        segments.append(
          ElementSegment(
            isPassive: false, isDeclarative: false, tableIndex: 0, offset: offset,
            functionIndices: funcIndices))
      case 1:
        // Passive segment: elemkind byte (0x00 = funcref), then function index list.
        // Not applied at instantiation; used by table.init / elem.drop at runtime.
        let elemkind1 = try readByte()
        guard elemkind1 == 0x00 else { throw .invalidValueType(elemkind1) }
        let funcCount = try readU32()
        var funcIndices: [UInt32?] = []
        for _ in 0..<funcCount { funcIndices.append(try readU32()) }
        segments.append(
          ElementSegment(
            isPassive: true, isDeclarative: false, tableIndex: 0, offset: 0,
            functionIndices: funcIndices))
      case 2:
        // Active with explicit table index: table_idx, i32.const offset, elemkind(0x00), funcidx list
        let tableIndex = try readU32()
        let constOp = try readByte()
        guard constOp == 0x41 else { throw .invalidInstruction(constOp) }
        let offset = try readI32()
        let endOp = try readByte()
        guard endOp == 0x0B else { throw .invalidInstruction(endOp) }
        let elemkind2 = try readByte()
        guard elemkind2 == 0x00 else { throw .invalidValueType(elemkind2) }
        let funcCount = try readU32()
        var funcIndices: [UInt32?] = []
        for _ in 0..<funcCount { funcIndices.append(try readU32()) }
        segments.append(
          ElementSegment(
            isPassive: false, isDeclarative: false, tableIndex: tableIndex, offset: offset,
            functionIndices: funcIndices))
      case 3:
        // Declarative segment: elemkind(0x00), init_expr* list.
        // Declarative segments are never applied to a table; they exist only to make
        // ref.func instructions valid. Per Wasm spec §4.5.4 they must be pre-dropped at
        // instantiation — table.init must not be able to access them.
        let elemkind3 = try readByte()
        guard elemkind3 == 0x00 else { throw .invalidValueType(elemkind3) }
        let elemCount3 = try readU32()
        var funcIndices: [UInt32?] = []
        for _ in 0..<elemCount3 { funcIndices.append(try readFuncrefInitExpr()) }
        segments.append(
          ElementSegment(
            isPassive: true, isDeclarative: true, tableIndex: 0, offset: 0,
            functionIndices: funcIndices))
      case 4:
        // Active, table 0, i32.const offset, init_expr* list.
        let constOp4 = try readByte()
        guard constOp4 == 0x41 else { throw .invalidInstruction(constOp4) }
        let offset4 = try readI32()
        let endOp4 = try readByte()
        guard endOp4 == 0x0B else { throw .invalidInstruction(endOp4) }
        let elemCount4 = try readU32()
        var funcIndices: [UInt32?] = []
        for _ in 0..<elemCount4 { funcIndices.append(try readFuncrefInitExpr()) }
        segments.append(
          ElementSegment(
            isPassive: false, isDeclarative: false, tableIndex: 0, offset: offset4,
            functionIndices: funcIndices))
      case 5:
        // Passive (not declarative), reftype byte, init_expr* list.
        // Like flags=1 but uses a reftype byte and init_expr per element instead of elemkind.
        // Available to table.init at runtime (isDeclarative: false).
        let refTypeByte5 = try readByte()
        guard RefType(rawValue: refTypeByte5) != nil else { throw .invalidRefType(refTypeByte5) }
        let elemCount5 = try readU32()
        var funcIndices: [UInt32?] = []
        for _ in 0..<elemCount5 { funcIndices.append(try readFuncrefInitExpr()) }
        segments.append(
          ElementSegment(
            isPassive: true, isDeclarative: false, tableIndex: 0, offset: 0,
            functionIndices: funcIndices))
      case 6:
        // Active, explicit table index, offset expr, reftype byte, init_expr* list.
        let tableIndex6 = try readU32()
        let constOp6 = try readByte()
        guard constOp6 == 0x41 else { throw .invalidInstruction(constOp6) }
        let offset6 = try readI32()
        let endOp6 = try readByte()
        guard endOp6 == 0x0B else { throw .invalidInstruction(endOp6) }
        let refTypeByte6 = try readByte()
        guard RefType(rawValue: refTypeByte6) != nil else { throw .invalidRefType(refTypeByte6) }
        let elemCount6 = try readU32()
        var funcIndices: [UInt32?] = []
        for _ in 0..<elemCount6 { funcIndices.append(try readFuncrefInitExpr()) }
        segments.append(
          ElementSegment(
            isPassive: false, isDeclarative: false, tableIndex: tableIndex6, offset: offset6,
            functionIndices: funcIndices))
      case 7:
        // Declarative, reftype byte, init_expr* list.
        // Like flags=3 but uses a reftype byte instead of elemkind(0x00).
        // Per Wasm spec §4.5.4 declarative segments are pre-dropped at instantiation.
        let refTypeByte7 = try readByte()
        guard RefType(rawValue: refTypeByte7) != nil else { throw .invalidRefType(refTypeByte7) }
        let elemCount7 = try readU32()
        var funcIndices: [UInt32?] = []
        for _ in 0..<elemCount7 { funcIndices.append(try readFuncrefInitExpr()) }
        segments.append(
          ElementSegment(
            isPassive: true, isDeclarative: true, tableIndex: 0, offset: 0,
            functionIndices: funcIndices))
      default:
        throw .unsupportedElementSegment
      }
    }
    return segments
  }

  /// Reads a single init_expr from an expression-based element segment.
  ///
  /// Valid forms in Wasm 2.0 element segments:
  ///   ref.null reftype 0x0B  → nil (null reference)
  ///   ref.func funcidx 0x0B  → funcidx
  ///
  /// Returns nil for a null reference, or the function index for a non-null funcref.
  private mutating func readFuncrefInitExpr() throws(WasmError) -> UInt32? {
    let opcode = try readByte()
    switch opcode {
    case 0xD0:  // ref.null
      _ = try readByte()  // reftype byte (0x70 = funcref)
      let endByte = try readByte()
      guard endByte == 0x0B else { throw .invalidInstruction(endByte) }
      return nil
    case 0xD2:  // ref.func
      let funcIdx = try readU32()
      let endByte = try readByte()
      guard endByte == 0x0B else { throw .invalidInstruction(endByte) }
      return funcIdx
    default:
      throw .invalidInstruction(opcode)
    }
  }

  /// Function section (id=3): type index for each local function
  private mutating func parseFunctionSection() throws(WasmError) -> [UInt32] {
    let count = try readU32()
    guard count <= WasmLimits.maxFunctions else { throw .resourceLimitExceeded }
    var indices: [UInt32] = []
    for _ in 0..<count { indices.append(try readU32()) }
    return indices
  }

  /// Export section (id=7): array of externally visible symbols
  ///
  /// Format: [count] ([name_len][name_bytes][kind][index])*
  private mutating func parseExportSection() throws(WasmError) -> [Export] {
    let count = try readU32()
    guard count <= WasmLimits.maxExports else { throw .resourceLimitExceeded }
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

  /// Code section (id=10): records byte ranges with pre-computed jump tables.
  ///
  /// For each function body: reads local declarations, records the byte offset of the instruction
  /// stream, advances the stream by calling parseFlatBodyTracked (which builds both the flat
  /// [Instruction] array and the jump table), then stores the byte range, local types, bulk-memory
  /// flag, and jump table in a FunctionHandle.
  // TODO: Phase 5 — replace parseFlatBodyTracked call with a zero-allocation byte skipper.
  private mutating func parseFunctionHandles() throws(WasmError) -> [FunctionHandle] {
    let count = try readU32()
    // Check before allocating any FunctionHandle entries to fail fast on oversized modules.
    guard count <= WasmLimits.maxFunctions else { throw .resourceLimitExceeded }
    var handles: [FunctionHandle] = []
    for _ in 0..<count {
      let bodySize = try readU32()

      let localDeclCount = try readU32()
      var locals: [ValueType] = []
      for _ in 0..<localDeclCount {
        let n = try readU32()
        let vt = try readValueType()
        guard n <= bodySize else { throw .unexpectedEnd }
        for _ in 0..<n { locals.append(vt) }
      }

      let codeStart = UInt32(stream.offset)
      var tempInstructions: [Instruction] = []
      var jumpTable: [JumpEntry] = []
      try parseFlatBodyTracked(into: &tempInstructions, jumpTable: &jumpTable)
      let codeEnd = UInt32(stream.offset)

      var hasBulkMemory = false
      for instr in tempInstructions {
        switch instr {
        case .memoryInit: hasBulkMemory = true
        case .dataDrop: hasBulkMemory = true
        default: break
        }
        if hasBulkMemory { break }
      }

      handles.append(
        FunctionHandle(
          codeOffset: codeStart,
          codeSize: codeEnd - codeStart,
          locals: locals,
          hasBulkMemoryInstruction: hasBulkMemory,
          jumpTable: jumpTable
        ))
    }
    return handles
  }

  /// Parses instructions into a flat array, tracking control-flow byte offsets for the jump table.
  ///
  /// Captures the absolute byte offset of each opcode before consuming it, and appends a
  /// JumpEntry to `jumpTable` for every block/loop/if with the pre-computed byte targets.
  ///
  /// All `instrOffset`, `target1`, and `target2` values are absolute positions within the
  /// original buffer passed to WasmParser.init — the same coordinate space as the
  /// on-the-fly decoder's `ip`.
  ///
  /// Iterative: uses an explicit `pending` stack instead of recursion to avoid Swift call-stack
  /// overflow on deeply nested control structures (e.g. the `deep` function in block.0.wasm).
  private mutating func parseFlatBodyTracked(
    into instructions: inout [Instruction],
    jumpTable: inout [JumpEntry]
  ) throws(WasmError) {
    // TODO: Embedded Phase 5 — replace with a fixed-capacity buffer to avoid heap allocation.
    var pending: [PendingBlock] = []

    while true {
      // Capture the absolute byte offset of this opcode BEFORE consuming it.
      // This is the instrOffset stored in JumpEntry for block/loop/if opcodes.
      let opcodeByteOffset = UInt32(stream.offset)
      let opcode = try readByte()
      switch opcode {

      case 0x02:  // block
        let bt = try readBlockType()
        let (brArity, paramCount) = try blockArityForBlock(bt)
        let headerPc = instructions.count
        // Placeholder; endPc backpatched on matching `end`.
        instructions.append(.block(bt, brArity: brArity, paramCount: paramCount, endPc: 0))
        // Pre-append placeholder so outer block's entry precedes inner blocks' entries
        // (pre-order). Phase 4's monotonically-advancing cursor requires this ordering.
        let jumpEntryIdx = jumpTable.count
        jumpTable.append(JumpEntry(instrOffset: opcodeByteOffset, target1: 0, target2: 0))
        pending.append(
          .block(
            headerPc: headerPc, bt: bt, brArity: brArity, paramCount: paramCount,
            jumpEntryIdx: jumpEntryIdx, opcodeByteOffset: opcodeByteOffset))

      case 0x03:  // loop
        let bt = try readBlockType()
        let loopBrArity = try loopBrArityFromBlockType(bt)
        // stream.offset now points at the first byte of the loop body.
        // Phase 4 decoder will restart here on a br targeting this loop.
        let startByteOffset = UInt32(stream.offset)
        let startPc = instructions.count + 1  // first body instruction follows the loop instr
        instructions.append(.loop(bt, brArity: loopBrArity, startPc: startPc))
        // target1 (startByteOffset) is already known; the entry is fully written here — no
        // backpatch needed. Pre-order: this loop's entry precedes any inner blocks' entries.
        jumpTable.append(
          JumpEntry(instrOffset: opcodeByteOffset, target1: startByteOffset, target2: 0))
        pending.append(.loop)

      case 0x04:  // if [else] end
        let bt = try readBlockType()
        let (brArity, paramCount) = try blockArityForBlock(bt)
        let headerPc = instructions.count
        // Placeholder; both PCs backpatched on matching `else`/`end`.
        instructions.append(
          .ifElse(bt, brArity: brArity, paramCount: paramCount, elsePc: 0, endPc: 0))
        // Pre-append placeholder BEFORE the then-body so that this if's entry precedes
        // any inner blocks in both then-body and else-body (pre-order).
        let jumpEntryIdx = jumpTable.count
        jumpTable.append(JumpEntry(instrOffset: opcodeByteOffset, target1: 0, target2: 0))
        pending.append(
          .ifThen(
            headerPc: headerPc, bt: bt, brArity: brArity, paramCount: paramCount,
            jumpEntryIdx: jumpEntryIdx, opcodeByteOffset: opcodeByteOffset))

      case 0x05:  // else: closes then-body, opens else-body
        guard !pending.isEmpty else { throw WasmError.invalidInstruction(0x05) }
        let top = pending.removeLast()
        guard
          case .ifThen(
            let headerPc, let bt, let brArity, let paramCount,
            let jumpEntryIdx, let outerByteOffset) = top
        else { throw WasmError.invalidInstruction(0x05) }
        _ = headerPc  // used below in ifElse push
        instructions.append(.blockEnd)  // ends the then-path
        let jumpPc = instructions.count
        instructions.append(.jump(0))  // placeholder; backpatched at matching `end`
        let elsePc = instructions.count
        // stream.offset is now just after the 0x05 else opcode — first byte of else body.
        let elseByteOffset = UInt32(stream.offset)
        pending.append(
          .ifElse(
            headerPc: headerPc, jumpPc: jumpPc, elsePc: elsePc,
            bt: bt, brArity: brArity, paramCount: paramCount,
            jumpEntryIdx: jumpEntryIdx, opcodeByteOffset: outerByteOffset,
            elseByteOffset: elseByteOffset))

      case 0x0B:  // end: closes a block/loop/if body or the function body
        guard let top = pending.popLast() else { return }  // function body end
        switch top {
        case .block(
          let headerPc, let bt, let brArity, let paramCount,
          let jumpEntryIdx, let outerByteOffset):
          let blockEndPc = instructions.count
          instructions.append(.blockEnd)
          // stream.offset now sits just past the 0x0B end opcode.
          let endByteOffset = UInt32(stream.offset)
          instructions[headerPc] = .block(
            bt, brArity: brArity, paramCount: paramCount, endPc: blockEndPc + 1)
          jumpTable[jumpEntryIdx] = JumpEntry(
            instrOffset: outerByteOffset, target1: endByteOffset, target2: 0)
        case .loop:
          instructions.append(.blockEnd)
        case .ifThen(
          let headerPc, let bt, let brArity, let paramCount,
          let jumpEntryIdx, let outerByteOffset):
          // No else clause.
          // target1 = opcodeByteOffset (the `end` byte itself): condition-false jumps here
          //   so the interpreter executes `end` which pops the if label naturally.
          // target2 = stream.offset (byte after `end`): br-continuation; handleEmbeddedBranch
          //   already pops the label, so ip must land past the `end`, not on it.
          let blockEndPc = instructions.count
          instructions.append(.blockEnd)
          let endPc = instructions.count
          instructions[headerPc] = .ifElse(
            bt, brArity: brArity, paramCount: paramCount, elsePc: blockEndPc, endPc: endPc)
          jumpTable[jumpEntryIdx] = JumpEntry(
            instrOffset: outerByteOffset,
            target1: opcodeByteOffset,
            target2: UInt32(stream.offset))
        case .ifElse(
          let headerPc, let jumpPc, let elsePc, let bt, let brArity, let paramCount,
          let jumpEntryIdx, let outerByteOffset, let elseByteOffset):
          // Has else clause: then-path jumps past end; else-path falls through to here.
          instructions.append(.blockEnd)
          let endByteOffset = UInt32(stream.offset)
          let endPc = instructions.count
          instructions[headerPc] = .ifElse(
            bt, brArity: brArity, paramCount: paramCount, elsePc: elsePc, endPc: endPc)
          instructions[jumpPc] = .jump(endPc)
          jumpTable[jumpEntryIdx] = JumpEntry(
            instrOffset: outerByteOffset, target1: elseByteOffset, target2: endByteOffset)
        }

      // ── All remaining cases (non-control-flow) ───────────────────────────────────────
      // The opcodeByteOffset captured above is not used for non-control-flow instructions.

      case 0x00:  // unreachable
        instructions.append(.unreachable)

      case 0x01:  // nop
        instructions.append(.nop)

      case 0x0C:  // br
        instructions.append(.br(try readU32()))

      case 0x0D:  // br_if
        instructions.append(.brIf(try readU32()))

      case 0x0E:  // br_table
        let count = try readU32()
        let headerPc = instructions.count
        instructions.append(.brTable(count: count, default_: 0))  // placeholder; backpatched below
        for _ in 0..<count {
          instructions.append(.brTableEntry(try readU32()))
        }
        let default_ = try readU32()
        instructions[headerPc] = .brTable(count: count, default_: default_)  // backpatch

      case 0x0F:  // return
        instructions.append(.return_)

      case 0x10:  // call
        instructions.append(.call(try readU32()))

      case 0x11:  // call_indirect: type_idx, table_idx
        let typeIdx = try readU32()
        let tableIdx = try readU32()
        instructions.append(.callIndirect(typeIdx, tableIdx))

      case 0x1A:  // drop
        instructions.append(.drop)

      case 0x1B:  // select
        instructions.append(.select)

      case 0x20:  // local.get
        instructions.append(.localGet(try readU32()))

      case 0x21:  // local.set
        instructions.append(.localSet(try readU32()))

      case 0x22:  // local.tee
        instructions.append(.localTee(try readU32()))

      case 0x23:  // global.get
        instructions.append(.globalGet(try readU32()))

      case 0x24:  // global.set
        instructions.append(.globalSet(try readU32()))

      case 0x25:  // table.get
        instructions.append(.tableGet(try readU32()))

      case 0x26:  // table.set
        instructions.append(.tableSet(try readU32()))

      case 0x28:  // i32.load
        instructions.append(.i32Load(try readU32(), try readU32()))

      case 0x29:  // i64.load
        instructions.append(.i64Load(try readU32(), try readU32()))

      case 0x2A:  // f32.load
        instructions.append(.f32Load(try readU32(), try readU32()))

      case 0x2B:  // f64.load
        instructions.append(.f64Load(try readU32(), try readU32()))

      case 0x2C:  // i32.load8_s
        instructions.append(.i32Load8S(try readU32(), try readU32()))

      case 0x2D:  // i32.load8_u
        instructions.append(.i32Load8U(try readU32(), try readU32()))

      case 0x2E:  // i32.load16_s
        instructions.append(.i32Load16S(try readU32(), try readU32()))

      case 0x2F:  // i32.load16_u
        instructions.append(.i32Load16U(try readU32(), try readU32()))

      case 0x30:  // i64.load8_s
        instructions.append(.i64Load8S(try readU32(), try readU32()))

      case 0x31:  // i64.load8_u
        instructions.append(.i64Load8U(try readU32(), try readU32()))

      case 0x32:  // i64.load16_s
        instructions.append(.i64Load16S(try readU32(), try readU32()))

      case 0x33:  // i64.load16_u
        instructions.append(.i64Load16U(try readU32(), try readU32()))

      case 0x34:  // i64.load32_s
        instructions.append(.i64Load32S(try readU32(), try readU32()))

      case 0x35:  // i64.load32_u
        instructions.append(.i64Load32U(try readU32(), try readU32()))

      case 0x36:  // i32.store
        instructions.append(.i32Store(try readU32(), try readU32()))

      case 0x37:  // i64.store
        instructions.append(.i64Store(try readU32(), try readU32()))

      case 0x38:  // f32.store
        instructions.append(.f32Store(try readU32(), try readU32()))

      case 0x39:  // f64.store
        instructions.append(.f64Store(try readU32(), try readU32()))

      case 0x3A:  // i32.store8
        instructions.append(.i32Store8(try readU32(), try readU32()))

      case 0x3B:  // i32.store16
        instructions.append(.i32Store16(try readU32(), try readU32()))

      case 0x3C:  // i64.store8
        instructions.append(.i64Store8(try readU32(), try readU32()))

      case 0x3D:  // i64.store16
        instructions.append(.i64Store16(try readU32(), try readU32()))

      case 0x3E:  // i64.store32
        instructions.append(.i64Store32(try readU32(), try readU32()))

      case 0x3F:  // memory.size (1-byte reserved operand = 0x00)
        _ = try readByte()
        instructions.append(.memorySize)

      case 0x40:  // memory.grow (1-byte reserved operand = 0x00)
        _ = try readByte()
        instructions.append(.memoryGrow)

      case 0xFC:  // bulk memory / SIMD-saturating-truncate prefix
        let subOp = try readByte()
        switch subOp {
        case 0x00: instructions.append(.i32TruncSatF32S)
        case 0x01: instructions.append(.i32TruncSatF32U)
        case 0x02: instructions.append(.i32TruncSatF64S)
        case 0x03: instructions.append(.i32TruncSatF64U)
        case 0x04: instructions.append(.i64TruncSatF32S)
        case 0x05: instructions.append(.i64TruncSatF32U)
        case 0x06: instructions.append(.i64TruncSatF64S)
        case 0x07: instructions.append(.i64TruncSatF64U)
        case 0x08:
          let segIdx = try readU32()
          _ = try readByte()  // mem_idx: always 0x00 in MVP (single memory)
          instructions.append(.memoryInit(segIdx))
        case 0x09:
          instructions.append(.dataDrop(try readU32()))
        case 0x0A:
          _ = try readByte()  // dst memory index (always 0x00 in MVP)
          _ = try readByte()  // src memory index (always 0x00 in MVP)
          instructions.append(.memoryCopy)
        case 0x0B:
          _ = try readByte()  // memory index (always 0x00 in MVP)
          instructions.append(.memoryFill)
        case 0x0C:
          let elemIdx = try readU32()
          let tableIdx = try readU32()
          instructions.append(.tableInit(elemIdx, tableIdx))
        case 0x0D:
          instructions.append(.elemDrop(try readU32()))
        case 0x0E:
          let dstTable = try readU32()
          let srcTable = try readU32()
          instructions.append(.tableCopy(dstTable, srcTable))
        case 0x0F:
          instructions.append(.tableGrow(try readU32()))
        case 0x10:
          instructions.append(.tableSize(try readU32()))
        case 0x11:
          instructions.append(.tableFill(try readU32()))
        default:
          throw .invalidInstruction(0xFC)
        }

      case 0x41:  // i32.const (signed LEB128)
        instructions.append(.i32Const(try readI32()))

      case 0x42:  // i64.const (signed LEB128, 64-bit)
        instructions.append(.i64Const(try readI64()))

      case 0x43:  // f32.const (4 bytes, little-endian IEEE 754)
        instructions.append(.f32Const(try readF32()))

      case 0x44:  // f64.const (8 bytes, little-endian IEEE 754)
        instructions.append(.f64Const(try readF64()))

      // f32 comparisons (return i32)
      case 0x5B: instructions.append(.f32Eq)
      case 0x5C: instructions.append(.f32Ne)
      case 0x5D: instructions.append(.f32Lt)
      case 0x5E: instructions.append(.f32Gt)
      case 0x5F: instructions.append(.f32Le)
      case 0x60: instructions.append(.f32Ge)

      // i32 unary
      case 0x45: instructions.append(.i32Eqz)
      case 0x67: instructions.append(.i32Clz)
      case 0x68: instructions.append(.i32Ctz)
      case 0x69: instructions.append(.i32Popcnt)
      case 0xC0: instructions.append(.i32Extend8S)
      case 0xC1: instructions.append(.i32Extend16S)

      // i32 comparisons
      case 0x46: instructions.append(.i32Eq)
      case 0x47: instructions.append(.i32Ne)
      case 0x48: instructions.append(.i32LtS)
      case 0x49: instructions.append(.i32LtU)
      case 0x4A: instructions.append(.i32GtS)
      case 0x4B: instructions.append(.i32GtU)
      case 0x4C: instructions.append(.i32LeS)
      case 0x4D: instructions.append(.i32LeU)
      case 0x4E: instructions.append(.i32GeS)
      case 0x4F: instructions.append(.i32GeU)

      // i32 arithmetic
      case 0x6A: instructions.append(.i32Add)
      case 0x6B: instructions.append(.i32Sub)
      case 0x6C: instructions.append(.i32Mul)
      case 0x6D: instructions.append(.i32DivS)
      case 0x6E: instructions.append(.i32DivU)
      case 0x6F: instructions.append(.i32RemS)
      case 0x70: instructions.append(.i32RemU)

      // i32 bitwise
      case 0x71: instructions.append(.i32And)
      case 0x72: instructions.append(.i32Or)
      case 0x73: instructions.append(.i32Xor)
      case 0x74: instructions.append(.i32Shl)
      case 0x75: instructions.append(.i32ShrS)
      case 0x76: instructions.append(.i32ShrU)
      case 0x77: instructions.append(.i32Rotl)
      case 0x78: instructions.append(.i32Rotr)

      // f32 unary
      case 0x8B: instructions.append(.f32Abs)
      case 0x8C: instructions.append(.f32Neg)
      case 0x8D: instructions.append(.f32Ceil)
      case 0x8E: instructions.append(.f32Floor)
      case 0x8F: instructions.append(.f32Trunc)
      case 0x90: instructions.append(.f32Nearest)
      case 0x91: instructions.append(.f32Sqrt)

      // f32 binary arithmetic
      case 0x92: instructions.append(.f32Add)
      case 0x93: instructions.append(.f32Sub)
      case 0x94: instructions.append(.f32Mul)
      case 0x95: instructions.append(.f32Div)
      case 0x96: instructions.append(.f32Min)
      case 0x97: instructions.append(.f32Max)
      case 0x98: instructions.append(.f32Copysign)

      // i64 unary
      case 0x50: instructions.append(.i64Eqz)
      case 0x79: instructions.append(.i64Clz)
      case 0x7A: instructions.append(.i64Ctz)
      case 0x7B: instructions.append(.i64Popcnt)
      case 0xC2: instructions.append(.i64Extend8S)
      case 0xC3: instructions.append(.i64Extend16S)
      case 0xC4: instructions.append(.i64Extend32S)

      // i64 comparisons (return i32)
      case 0x51: instructions.append(.i64Eq)
      case 0x52: instructions.append(.i64Ne)
      case 0x53: instructions.append(.i64LtS)
      case 0x54: instructions.append(.i64LtU)
      case 0x55: instructions.append(.i64GtS)
      case 0x56: instructions.append(.i64GtU)
      case 0x57: instructions.append(.i64LeS)
      case 0x58: instructions.append(.i64LeU)
      case 0x59: instructions.append(.i64GeS)
      case 0x5A: instructions.append(.i64GeU)

      // i64 arithmetic
      case 0x7C: instructions.append(.i64Add)
      case 0x7D: instructions.append(.i64Sub)
      case 0x7E: instructions.append(.i64Mul)
      case 0x7F: instructions.append(.i64DivS)
      case 0x80: instructions.append(.i64DivU)
      case 0x81: instructions.append(.i64RemS)
      case 0x82: instructions.append(.i64RemU)

      // i64 bitwise
      case 0x83: instructions.append(.i64And)
      case 0x84: instructions.append(.i64Or)
      case 0x85: instructions.append(.i64Xor)
      case 0x86: instructions.append(.i64Shl)
      case 0x87: instructions.append(.i64ShrS)
      case 0x88: instructions.append(.i64ShrU)
      case 0x89: instructions.append(.i64Rotl)
      case 0x8A: instructions.append(.i64Rotr)

      case 0xA7: instructions.append(.i32WrapI64)
      case 0xA8: instructions.append(.i32TruncF32S)
      case 0xA9: instructions.append(.i32TruncF32U)
      case 0xAA: instructions.append(.i32TruncF64S)
      case 0xAB: instructions.append(.i32TruncF64U)
      case 0xAC: instructions.append(.i64ExtendI32S)
      case 0xAD: instructions.append(.i64ExtendI32U)
      case 0xAE: instructions.append(.i64TruncF32S)
      case 0xAF: instructions.append(.i64TruncF32U)
      case 0xB0: instructions.append(.i64TruncF64S)
      case 0xB1: instructions.append(.i64TruncF64U)
      case 0xB2: instructions.append(.f32ConvertI32S)
      case 0xB3: instructions.append(.f32ConvertI32U)
      case 0xB4: instructions.append(.f32ConvertI64S)
      case 0xB5: instructions.append(.f32ConvertI64U)
      case 0xB6: instructions.append(.f32DemoteF64)
      case 0xB7: instructions.append(.f64ConvertI32S)
      case 0xB8: instructions.append(.f64ConvertI32U)
      case 0xB9: instructions.append(.f64ConvertI64S)
      case 0xBA: instructions.append(.f64ConvertI64U)
      case 0xBB: instructions.append(.f64PromoteF32)
      case 0xBC: instructions.append(.i32ReinterpretF32)
      case 0xBD: instructions.append(.i64ReinterpretF64)
      case 0xBE: instructions.append(.f32ReinterpretI32)
      case 0xBF: instructions.append(.f64ReinterpretI64)

      // f64 comparisons (return i32)
      case 0x61: instructions.append(.f64Eq)
      case 0x62: instructions.append(.f64Ne)
      case 0x63: instructions.append(.f64Lt)
      case 0x64: instructions.append(.f64Gt)
      case 0x65: instructions.append(.f64Le)
      case 0x66: instructions.append(.f64Ge)

      // f64 unary
      case 0x99: instructions.append(.f64Abs)
      case 0x9A: instructions.append(.f64Neg)
      case 0x9B: instructions.append(.f64Ceil)
      case 0x9C: instructions.append(.f64Floor)
      case 0x9D: instructions.append(.f64Trunc)
      case 0x9E: instructions.append(.f64Nearest)
      case 0x9F: instructions.append(.f64Sqrt)

      // f64 binary arithmetic
      case 0xA0: instructions.append(.f64Add)
      case 0xA1: instructions.append(.f64Sub)
      case 0xA2: instructions.append(.f64Mul)
      case 0xA3: instructions.append(.f64Div)
      case 0xA4: instructions.append(.f64Min)
      case 0xA5: instructions.append(.f64Max)
      case 0xA6: instructions.append(.f64Copysign)

      // ref instructions
      case 0xD0:  // ref.null reftype: [] → [funcref | externref]
        let reftypeByte = try readByte()
        guard let refType = RefType(rawValue: reftypeByte) else {
          throw .invalidRefType(reftypeByte)
        }
        instructions.append(.refNull(refType))

      case 0xD1:  // ref.is_null: [funcref] → [i32]
        instructions.append(.refIsNull)

      case 0xD2:  // ref.func funcIdx: [] → [funcref]
        instructions.append(.refFunc(try readU32()))

      default:
        throw .invalidInstruction(opcode)
      }
    }
  }

  /// Data section (id=11): array of initial data segments for linear memory
  ///
  /// Supported flags:
  ///   0 — active, memory 0, i32.const offset expression, data bytes
  ///   1 — passive: no offset expression; segment is not applied at instantiation
  ///   2 — active with explicit memory index, i32.const offset expression, data bytes
  private mutating func parseDataSection() throws(WasmError) -> [DataSegment] {
    let count = try readU32()
    guard count <= WasmLimits.maxData else { throw .resourceLimitExceeded }
    var segments: [DataSegment] = []
    for _ in 0..<count {
      let flags = try readU32()
      switch flags {
      case 0:
        // Active segment: memory 0 (implicit), constant offset expression, then data bytes.
        let constOp = try readByte()
        guard constOp == 0x41 else { throw .invalidInstruction(constOp) }
        let offset = try readI32()
        let endOp = try readByte()
        guard endOp == 0x0B else { throw .invalidInstruction(endOp) }
        let byteLen = try readU32()
        var bytes: [UInt8] = []
        for _ in 0..<byteLen { bytes.append(try readByte()) }
        segments.append(DataSegment(offset: offset, bytes: bytes))
      case 1:
        // Passive segment: no memory index, no offset expression; just raw data bytes.
        // Not applied at instantiation; used by memory.init / data.drop at runtime.
        let byteLen = try readU32()
        var bytes: [UInt8] = []
        for _ in 0..<byteLen { bytes.append(try readByte()) }
        segments.append(DataSegment(offset: nil, bytes: bytes))
      case 2:
        // Active segment with explicit memory index.
        _ = try readU32()  // memory index (always 0 in MVP; multi-memory is not supported here)
        let constOp = try readByte()
        guard constOp == 0x41 else { throw .invalidInstruction(constOp) }
        let offset = try readI32()
        let endOp = try readByte()
        guard endOp == 0x0B else { throw .invalidInstruction(endOp) }
        let byteLen = try readU32()
        var bytes: [UInt8] = []
        for _ in 0..<byteLen { bytes.append(try readByte()) }
        segments.append(DataSegment(offset: offset, bytes: bytes))
      default:
        throw .unsupportedElementSegment
      }
    }
    return segments
  }

  // MARK: - Validation helper (non-Embedded only)

  #if !hasFeature(Embedded)
    /// Decodes a FunctionHandle's instruction bytes into a flat [Instruction] array.
    ///
    /// Used by WasmValidator to iterate instructions for type-checking without storing
    /// decoded instructions in FunctionHandle (which would double memory usage).
    ///
    /// Creates a temporary WasmParser positioned at handle.codeOffset within rawBytes,
    /// pre-populating the types table needed for block-arity computation.
    static func decodeInstructions(
      handle: FunctionHandle,
      rawBytes: [UInt8],
      types: [FunctionType]
    ) throws(WasmError) -> [Instruction] {
      var instructions: [Instruction] = []
      var jumpTable: [JumpEntry] = []
      // withUnsafeBufferPointer is rethrows; catch and rethrow as typed WasmError
      // to satisfy the typed-throws function signature.
      do {
        try rawBytes.withUnsafeBufferPointer { buf in
          var parser = WasmParser(buf)
          parser.stream = BufferStream(buf, offset: Int(handle.codeOffset))
          parser.types = types
          try parser.parseFlatBodyTracked(into: &instructions, jumpTable: &jumpTable)
        }
      } catch let e as WasmError {
        throw e
      } catch {
        fatalError("unexpected error from parseFlatBodyTracked: \(error)")
      }
      return instructions
    }
  #endif

  private mutating func readBlockType() throws(WasmError) -> BlockType {
    // Block types are encoded as signed LEB128 (s33):
    //   non-negative values → type index (multi-value extension)
    //   negative values    → value type byte or void (0x40 = -64)
    let raw: Int32 = try readI32()
    if raw >= 0 { return .typeIndex(UInt32(raw)) }
    // Recover the original 7-bit byte from the signed value.
    // e.g. -1 → 0x7F (i32), -64 → 0x40 (void)
    let byte = UInt8(raw & 0x7F)
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

  @inline(__always)
  private mutating func readI64() throws(WasmError) -> Int64 {
    do {
      return try decodeSLEB128(from: &stream)
    } catch {
      throw .leb128Error(error)
    }
  }

  // Reads a 4-byte little-endian IEEE 754 float (used by f32.const)
  @inline(__always)
  private mutating func readF32() throws(WasmError) -> Float {
    let b0 = UInt32(try readByte())
    let b1 = UInt32(try readByte())
    let b2 = UInt32(try readByte())
    let b3 = UInt32(try readByte())
    let bits = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    return Float(bitPattern: bits)
  }

  // Reads an 8-byte little-endian IEEE 754 double (used by f64.const)
  @inline(__always)
  private mutating func readF64() throws(WasmError) -> Double {
    let b0 = UInt64(try readByte())
    let b1 = UInt64(try readByte())
    let b2 = UInt64(try readByte())
    let b3 = UInt64(try readByte())
    let b4 = UInt64(try readByte())
    let b5 = UInt64(try readByte())
    let b6 = UInt64(try readByte())
    let b7 = UInt64(try readByte())
    let bits =
      b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) | (b4 << 32) | (b5 << 40) | (b6 << 48)
      | (b7 << 56)
    return Double(bitPattern: bits)
  }

  private mutating func readValueType() throws(WasmError) -> ValueType {
    let byte = try readByte()
    guard let vt = ValueType(rawValue: byte) else { throw .invalidValueType(byte) }
    return vt
  }
}
