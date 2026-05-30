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
      case 1: types = try parseTypeSection()
      case 2: imports = try parseImportSection()
      case 3: functions = try parseFunctionSection()
      case 4: tables = try parseTableSection()
      case 5: memories = try parseMemorySection()
      case 6: globals = try parseGlobalSection()
      case 7: exports = try parseExportSection()
      case 8: start = try parseStartSection()
      case 9: elements = try parseElementSection()
      case 10: code = try parseCodeSection()
      case 11: data = try parseDataSection()
      default:
        // Unknown sections are skipped by size (required by the Wasm spec for extensibility)
        for _ in 0..<Int(size) { _ = try readByte() }
      }
    }

    let module = WasmModule(
      types: types, imports: imports, functions: functions,
      tables: tables, memories: memories, globals: globals,
      exports: exports, code: code,
      start: start, elements: elements, data: data
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
    default: throw .invalidLimitType(limtype)
    }
  }

  /// Global section (id=6): mutable/immutable global variable definitions
  ///
  /// Format: [count] ([valtype][mutability][init_expr])*
  /// init_expr is a constant expression followed by end (0x0B).
  private mutating func parseGlobalSection() throws(WasmError) -> [GlobalDef] {
    let count = try readU32()
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
  /// Supported flags:
  ///   0 — active, table 0, i32.const offset, function indices (MVP)
  ///   1 — passive, elemkind(0x00), function indices
  ///   2 — active, explicit table index, i32.const offset, elemkind(0x00), function indices
  private mutating func parseElementSection() throws(WasmError) -> [ElementSegment] {
    let count = try readU32()
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
        var funcIndices: [UInt32] = []
        for _ in 0..<funcCount { funcIndices.append(try readU32()) }
        segments.append(
          ElementSegment(
            isPassive: false, tableIndex: 0, offset: offset, functionIndices: funcIndices))
      case 1:
        // Passive segment: elemkind byte (0x00 = funcref), then function index list.
        // Not applied at instantiation; used by table.init / elem.drop at runtime.
        let elemkind1 = try readByte()
        guard elemkind1 == 0x00 else { throw .invalidValueType(elemkind1) }
        let funcCount = try readU32()
        var funcIndices: [UInt32] = []
        for _ in 0..<funcCount { funcIndices.append(try readU32()) }
        segments.append(
          ElementSegment(isPassive: true, tableIndex: 0, offset: 0, functionIndices: funcIndices))
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
        var funcIndices: [UInt32] = []
        for _ in 0..<funcCount { funcIndices.append(try readU32()) }
        segments.append(
          ElementSegment(
            isPassive: false, tableIndex: tableIndex, offset: offset, functionIndices: funcIndices))
      default:
        throw .unsupportedElementSegment
      }
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

      var instructions: [Instruction] = []
      _ = try parseFlatBody(into: &instructions)
      bodies.append(FunctionBody(locals: locals, instructions: instructions))
    }
    return bodies
  }

  /// Data section (id=11): array of initial data segments for linear memory
  ///
  /// Supported flags:
  ///   0 — active, memory 0, i32.const offset expression, data bytes
  ///   1 — passive: no offset expression; segment is not applied at instantiation
  ///   2 — active with explicit memory index, i32.const offset expression, data bytes
  private mutating func parseDataSection() throws(WasmError) -> [DataSegment] {
    let count = try readU32()
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

  // MARK: - Instruction Parsing

  /// Parses instructions into a flat array until `end` (0x0B) or `else` (0x05).
  /// Returns true if parsing stopped at `else`, false if stopped at `end`.
  ///
  /// block/loop/if jump offsets are backpatched into the array once the end positions
  /// are known, so the entire function body is one contiguous flat [Instruction].
  ///
  /// Flat bytecode layout for each construct:
  ///
  ///   block:
  ///     [blockPc] block(bt, endPc)   ← endPc = blockEndPc + 1
  ///     ... body ...
  ///     [blockEndPc] blockEnd
  ///
  ///   loop:
  ///     [loopPc] loop(bt, loopPc+1)  ← startPc = first body instruction
  ///     ... body ...
  ///     [blockEndPc] blockEnd
  ///
  ///   if (no else):
  ///     [ifPc] ifElse(bt, blockEndPc, blockEndPc+1)
  ///     ... then body ...
  ///     [blockEndPc] blockEnd
  ///
  ///   if/else:
  ///     [ifPc] ifElse(bt, elsePc, endPc)
  ///     ... then body ...
  ///     [thenEndPc] blockEnd          ← pops if label for then path
  ///     [jumpPc]    jump(endPc)       ← skips else body
  ///     [elsePc]    ... else body ...
  ///     [elseEndPc] blockEnd          ← pops if label for else path
  ///     [endPc]     ...               ← both paths converge here
  private mutating func parseFlatBody(into instructions: inout [Instruction]) throws(WasmError)
    -> Bool
  {
    while true {
      let opcode = try readByte()
      switch opcode {

      case 0x02:  // block
        let bt = try readBlockType()
        let blockPc = instructions.count
        instructions.append(.block(bt, 0))  // placeholder; endPc backpatched below
        _ = try parseFlatBody(into: &instructions)
        let blockEndPc = instructions.count
        instructions.append(.blockEnd)
        instructions[blockPc] = .block(bt, blockEndPc + 1)

      case 0x03:  // loop
        let bt = try readBlockType()
        let startPc = instructions.count + 1  // first body instruction follows the loop instr
        instructions.append(.loop(bt, startPc))
        _ = try parseFlatBody(into: &instructions)
        instructions.append(.blockEnd)

      case 0x04:  // if [else] end
        let bt = try readBlockType()
        let ifPc = instructions.count
        instructions.append(.ifElse(bt, 0, 0))  // placeholder; both PCs backpatched below

        let stoppedAtElse = try parseFlatBody(into: &instructions)

        if stoppedAtElse {
          // Has else clause:
          //   then path: blockEnd pops if label, then jump skips else body
          //   else path: jumps to elsePc, falls through to elseBlockEnd which pops if label
          let thenEndPc = instructions.count
          instructions.append(.blockEnd)
          _ = thenEndPc  // unused after backpatch; compiler hint only
          let jumpPc = instructions.count
          instructions.append(.jump(0))  // placeholder; target backpatched below

          let elsePc = instructions.count
          _ = try parseFlatBody(into: &instructions)

          let elseEndPc = instructions.count
          instructions.append(.blockEnd)
          let endPc = instructions.count  // both paths converge here

          instructions[ifPc] = .ifElse(bt, elsePc, endPc)
          instructions[jumpPc] = .jump(endPc)
          _ = elseEndPc  // consumed above

        } else {
          // No else: else path jumps directly to blockEnd; both paths pop the label there
          let blockEndPc = instructions.count
          instructions.append(.blockEnd)
          let endPc = instructions.count  // past blockEnd; br-continuation

          instructions[ifPc] = .ifElse(bt, blockEndPc, endPc)
        }

      case 0x00:  // unreachable
        instructions.append(.unreachable)

      case 0x01:  // nop
        instructions.append(.nop)

      case 0x05:  // else: terminates the then-body
        return true

      case 0x0B:  // end: terminates a block or function body
        return false

      case 0x0C:  // br
        instructions.append(.br(try readU32()))

      case 0x0D:  // br_if
        instructions.append(.brIf(try readU32()))

      case 0x0E:  // br_table
        let count = try readU32()
        var labels: [UInt32] = []
        for _ in 0..<count { labels.append(try readU32()) }
        let default_ = try readU32()
        instructions.append(.brTable(labels, default_))

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

      case 0x40:  // memory.grow (1-byte reserved operand = 0x00)
        _ = try readByte()
        instructions.append(.memoryGrow)

      case 0xFC:  // bulk memory / SIMD-saturating-truncate prefix
        let subOp = try readByte()
        switch subOp {
        case 0x00...0x07:
          // i32/i64.trunc_sat_f32/f64_s/u — saturating truncations; no extra operands.
          // Parsed but not executed (fall through to .unimplemented at runtime).
          instructions.append(.unimplemented(0xFC))
        case 0x08:
          // memory.init seg_idx mem_idx
          // Copies n bytes from a passive data segment into linear memory.
          let segIdx = try readU32()
          _ = try readByte()  // mem_idx: always 0x00 in MVP (single memory)
          instructions.append(.memoryInit(segIdx))
        case 0x09:
          // data.drop seg_idx
          // Marks a data segment as dropped (idempotent; frees its bytes per the spec).
          instructions.append(.dataDrop(try readU32()))
        case 0x0A:
          // memory.copy dst_mem src_mem
          _ = try readByte()  // dst memory index (always 0x00 in MVP)
          _ = try readByte()  // src memory index (always 0x00 in MVP)
          instructions.append(.memoryCopy)
        case 0x0B:
          // memory.fill dst val n: [dst: i32, val: i32, n: i32] → []
          _ = try readByte()  // memory index (always 0x00 in MVP)
          instructions.append(.memoryFill)
        case 0x0C:
          // table.init elem_idx table_idx: [dst: i32, src: i32, n: i32] → []
          let elemIdx = try readU32()
          let tableIdx = try readU32()
          instructions.append(.tableInit(elemIdx, tableIdx))
        case 0x0D:
          // elem.drop elem_idx: [] → []
          instructions.append(.elemDrop(try readU32()))
        case 0x0E:
          // table.copy dst_table src_table: [dst: i32, src: i32, n: i32] → []
          let dstTable = try readU32()
          let srcTable = try readU32()
          instructions.append(.tableCopy(dstTable, srcTable))
        case 0x0F:
          // table.grow table_idx
          _ = try readU32()  // table index
          instructions.append(.unimplemented(0xFC))
        case 0x10:
          // table.size table_idx
          _ = try readU32()  // table index
          instructions.append(.unimplemented(0xFC))
        case 0x11:
          // table.fill table_idx
          _ = try readU32()  // table index
          instructions.append(.unimplemented(0xFC))
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

      case 0xAC:  // i64.extend_i32_s
        instructions.append(.i64ExtendI32S)

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

      // Other conversion instructions — parsed but not executed.
      // Encountering them at runtime throws invalidInstruction, causing spec tests to skip.
      case 0xA7, 0xA8, 0xA9, 0xAA,  // i32.wrap_i64, i32.trunc_f32_s/u, i32.trunc_f64_s
        0xAB, 0xAD, 0xAE, 0xAF,  // i32.trunc_f64_u, i64 extend/trunc ops (0xAC handled above)
        0xB0, 0xB1, 0xB2, 0xB3, 0xB4,  // more i64 trunc/convert ops
        0xB5, 0xB6, 0xB7, 0xB8,  // f32.demote_f64, f64.convert ops
        0xB9, 0xBA, 0xBB,  // f64.convert ops / f64.promote_f32
        0xBC, 0xBD, 0xBE, 0xBF:  // reinterpret ops
        instructions.append(.unimplemented(opcode))

      default:
        throw .invalidInstruction(opcode)
      }
    }
  }

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
