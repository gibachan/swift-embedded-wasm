// Wasm バイナリパーサー
//
// Wasm バイナリは「セクション」の列で構成される。
// 各セクションは [id: u8][size: u32(leb128)][content] の形式。
//
// 参照: https://webassembly.github.io/spec/core/binary/modules.html

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
    var memories: [MemoryType] = []
    var exports: [Export] = []
    var code: [FunctionBody] = []
    var start: UInt32? = nil
    var data: [DataSegment] = []

    while !stream.isExhausted {
      let id = try readByte()
      let size = try readU32()

      switch id {
      case 1:  types     = try parseTypeSection()
      case 2:  imports   = try parseImportSection()
      case 3:  functions = try parseFunctionSection()
      case 5:  memories  = try parseMemorySection()
      case 7:  exports   = try parseExportSection()
      case 8:  start     = try parseStartSection()
      case 10: code      = try parseCodeSection()
      case 11: data      = try parseDataSection()
      default:
        // 未知のセクションはサイズ分スキップ（Wasm 仕様: 拡張性のため必須）
        for _ in 0..<Int(size) { _ = try readByte() }
      }
    }

    return WasmModule(
      types: types, imports: imports, functions: functions,
      memories: memories, exports: exports, code: code,
      start: start, data: data
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

  /// Type section (id=1): 関数シグネチャの配列
  private mutating func parseTypeSection() throws(WasmError) -> [FunctionType] {
    let count = try readU32()
    var types: [FunctionType] = []
    for _ in 0..<count {
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

  /// Import section (id=2): 外部から提供される関数・メモリ等の配列
  ///
  /// 関数インポートは関数インデックス空間の先頭を占め、ローカル関数はその後に続く。
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
      case 0x00:  // 関数インポート: type index を読む
        let typeIndex = try readU32()
        imports.append(.function(FunctionImport(module: modBytes, name: nameBytes, typeIndex: typeIndex)))
      case 0x02:  // メモリインポート: limits を読む
        let (min, max) = try parseMemoryLimits()
        imports.append(.memory(MemoryImport(module: modBytes, name: nameBytes, type: MemoryType(min: min, max: max))))
      default:
        throw .invalidImportKind(kind)
      }
    }
    return imports
  }

  /// Memory section (id=5): Linear Memory の定義
  private mutating func parseMemorySection() throws(WasmError) -> [MemoryType] {
    let count = try readU32()
    var memories: [MemoryType] = []
    for _ in 0..<count {
      let (min, max) = try parseMemoryLimits()
      memories.append(MemoryType(min: min, max: max))
    }
    return memories
  }

  /// メモリの limits（min と省略可能な max）を読む
  private mutating func parseMemoryLimits() throws(WasmError) -> (min: UInt32, max: UInt32?) {
    let limtype = try readByte()
    let min = try readU32()
    switch limtype {
    case 0x00: return (min, nil)
    case 0x01: return (min, try readU32())
    default:   throw .invalidLimitType(limtype)
    }
  }

  /// Function section (id=3): 各ローカル関数が参照する type index の配列
  private mutating func parseFunctionSection() throws(WasmError) -> [UInt32] {
    let count = try readU32()
    var indices: [UInt32] = []
    for _ in 0..<count { indices.append(try readU32()) }
    return indices
  }

  /// Export section (id=7): 外部公開するシンボルの配列
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

  /// Start section (id=8): インスタンス化時に自動実行する関数インデックス
  private mutating func parseStartSection() throws(WasmError) -> UInt32 {
    return try readU32()
  }

  /// Code section (id=10): 関数本体の配列
  private mutating func parseCodeSection() throws(WasmError) -> [FunctionBody] {
    let count = try readU32()
    var bodies: [FunctionBody] = []
    for _ in 0..<count {
      _ = try readU32()  // body_size: このインタプリタでは使わない

      let localDeclCount = try readU32()
      var locals: [ValueType] = []
      for _ in 0..<localDeclCount {
        let n = try readU32()
        let vt = try readValueType()
        for _ in 0..<n { locals.append(vt) }
      }

      let instructions = try parseInstructions()
      bodies.append(FunctionBody(locals: locals, instructions: instructions))
    }
    return bodies
  }

  /// Data section (id=11): memory への初期データセグメントの配列
  ///
  /// MVP では Active セグメント（flags=0）のみ対応する。
  /// 形式: flags=0, i32.const offset end, データバイト列
  private mutating func parseDataSection() throws(WasmError) -> [DataSegment] {
    let count = try readU32()
    var segments: [DataSegment] = []
    for _ in 0..<count {
      _ = try readU32()  // flags: 0 = active, memory index 0

      // オフセット定数式: i32.const <value> end
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

  /// 0x0B (end) を読むまで命令列をパースして返す
  private mutating func parseInstructions() throws(WasmError) -> [Instruction] {
    let (instructions, _) = try parseBody()
    return instructions
  }

  /// 0x0B (end) または 0x05 (else) を読むまで命令列をパースして返す。
  /// 戻り値の Bool は「else で止まった」場合に true。
  ///
  /// if 命令のパースで else/end どちらで止まったかを区別するために使う。
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
          // else の後を end まで続けてパース
          let (eb, _) = try parseBody()
          elseBody = eb
        } else {
          elseBody = []
        }
        instructions.append(.ifElse(bt, thenBody: thenBody, elseBody: elseBody))

      case 0x05:  // else: then-body の終端
        return (instructions, stoppedAtElse: true)

      case 0x0B:  // end: ブロック/関数の終端
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

      case 0x41:  // i32.const
        instructions.append(.i32Const(try readI32()))

      case 0x46:  // i32.eq
        instructions.append(.i32Eq)

      case 0x6A:  // i32.add
        instructions.append(.i32Add)

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
