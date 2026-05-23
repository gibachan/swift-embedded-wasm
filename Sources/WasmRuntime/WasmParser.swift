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
    var functions: [UInt32] = []
    var memories: [MemoryType] = []
    var exports: [Export] = []
    var code: [FunctionBody] = []
    var start: UInt32? = nil

    while !stream.isExhausted {
      let id = try readByte()
      let size = try readU32()

      switch id {
      case 1:  types     = try parseTypeSection()
      case 3:  functions = try parseFunctionSection()
      case 5:  memories  = try parseMemorySection()
      case 7:  exports   = try parseExportSection()
      case 8:  start     = try parseStartSection()
      case 10: code      = try parseCodeSection()
      default:
        // 未知のセクションはサイズ分スキップ（Wasm 仕様: 拡張性のため必須）
        for _ in 0..<Int(size) { _ = try readByte() }
      }
    }

    return WasmModule(types: types, functions: functions, memories: memories, exports: exports, code: code, start: start)
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
  ///
  /// 形式: [count] ([0x60][params][results])*
  private mutating func parseTypeSection() throws(WasmError) -> [FunctionType] {
    let count = try readU32()
    var types: [FunctionType] = []
    for _ in 0..<count {
      // 0x60 は functype を示すマーカーバイト
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
  
  /// Start section (id=8): インスタンス化時に自動実行する関数インデックス
  ///
  /// 形式: [func_index: u32]
  /// Wasm 仕様: インスタンス化完了直後、エクスポートへのアクセス前に呼び出される。
  private mutating func parseStartSection() throws(WasmError) -> UInt32 {
    return try readU32()
  }

  /// Memory section (id=5): Linear Memory の定義
  ///
  /// 形式: [count] ([limtype] [min] ([max])?)*
  /// limtype: 0x00 = min のみ、0x01 = min と max の両方
  private mutating func parseMemorySection() throws(WasmError) -> [MemoryType] {
    let count = try readU32()
    var memories: [MemoryType] = []
    for _ in 0..<count {
      let limtype = try readByte()
      let min = try readU32()
      let max: UInt32?
      switch limtype {
      case 0x00: max = nil
      case 0x01: max = try readU32()
      default:   throw .invalidLimitType(limtype)
      }
      memories.append(MemoryType(min: min, max: max))
    }
    return memories
  }

  /// Function section (id=3): 各関数が参照する type index の配列
  private mutating func parseFunctionSection() throws(WasmError) -> [UInt32] {
    let count = try readU32()
    var indices: [UInt32] = []
    for _ in 0..<count { indices.append(try readU32()) }
    return indices
  }
  
  /// Export section (id=7): 外部公開するシンボルの配列
  ///
  /// 形式: [count] ([name_len][name_bytes][kind][index])*
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
  
  /// Code section (id=10): 関数本体の配列
  ///
  /// 形式: [count] ([body_size][local_decls][instructions... end])*
  ///
  /// local_decls は (count, type) のペアで圧縮されている。
  /// 例: "3 個の i32 と 1 個の i64" → [(3, i32), (1, i64)]
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
  
  /// 命令列を再帰的にパースする。0x0B (end) を読んだ時点で返る。
  ///
  /// block / loop は再帰呼び出しで内部命令列を取得する。
  /// これにより構造的制御フローを [Instruction] のネスト構造として表現できる。
  private mutating func parseInstructions() throws(WasmError) -> [Instruction] {
    var instructions: [Instruction] = []
    while true {
      let opcode = try readByte()
      switch opcode {
      case 0x02:  // block: 前向きジャンプ用ブロック
        let bt = try readBlockType()
        instructions.append(.block(bt, try parseInstructions()))
      case 0x03:  // loop: br(0) でブロック先頭に戻れるブロック
        let bt = try readBlockType()
        instructions.append(.loop(bt, try parseInstructions()))
      case 0x0B:  // end: このブロックの終端 → 呼び出し元へ返る
        return instructions
      case 0x0C:  // br
        instructions.append(.br(try readU32()))
      case 0x0D:  // br_if
        instructions.append(.brIf(try readU32()))
      case 0x20:  // local.get
        instructions.append(.localGet(try readU32()))
      case 0x21:  // local.set
        instructions.append(.localSet(try readU32()))
      case 0x41:  // i32.const (符号付き LEB128)
        instructions.append(.i32Const(try readI32()))
      case 0x46:  // i32.eq
        instructions.append(.i32Eq)
      case 0x6A:  // i32.add
        instructions.append(.i32Add)
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
