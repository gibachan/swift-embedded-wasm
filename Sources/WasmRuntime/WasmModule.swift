// WebAssembly バイナリパーサー・インタプリタで使うコアデータ型

// MARK: - Value Types

enum ValueType: UInt8, Sendable {
  case i32 = 0x7F
  case i64 = 0x7E
  case f32 = 0x7D
  case f64 = 0x7C
}

// MARK: - Block Type

/// block / loop / if の結果型
enum BlockType: Sendable {
  case void              // 0x40: 結果なし
  case value(ValueType)  // 0x7F 等: 結果1つ
}

// MARK: - Function Type (シグネチャ)

struct FunctionType: Sendable {
  let params: [ValueType]
  let results: [ValueType]

  init(params: [ValueType], results: [ValueType]) {
    self.params = params
    self.results = results
  }
}

// MARK: - Instructions

/// このインタプリタが対応する命令セット
///
/// block/loop/if は子命令を持つため indirect case を使用する。
/// macOS フェーズでは indirect（ヒープ確保）を許容し、正確さを優先する。
enum Instruction: Sendable {
  case localGet(UInt32)                                                         // 0x20
  case localSet(UInt32)                                                         // 0x21
  case i32Const(Int32)                                                          // 0x41
  case i32Add                                                                   // 0x6A
  case i32Eq                                                                    // 0x46
  case i32RemU                                                                  // 0x70: 符号なし余り
  case call(UInt32)                                                             // 0x10: 関数呼び出し
  indirect case block(BlockType, [Instruction])                                 // 0x02
  indirect case loop(BlockType, [Instruction])                                  // 0x03
  indirect case ifElse(BlockType, thenBody: [Instruction], elseBody: [Instruction]) // 0x04
  case br(UInt32)                                                               // 0x0C
  case brIf(UInt32)                                                             // 0x0D
}

// MARK: - Function Body

struct FunctionBody: Sendable {
  /// 関数内で宣言されたローカル変数の型（引数とは別）
  let locals: [ValueType]
  let instructions: [Instruction]

  init(locals: [ValueType], instructions: [Instruction]) {
    self.locals = locals
    self.instructions = instructions
  }
}

// MARK: - Memory

/// Wasm Linear Memory の制限（ページ数、1 ページ = 64 KiB）
struct MemoryType: Sendable, Equatable {
  let min: UInt32
  let max: UInt32?  // nil = 無制限
}

// MARK: - Imports

/// Import section の関数インポートエントリ
struct FunctionImport: Sendable {
  let module: [UInt8]    // モジュール名（UTF-8 バイト列）
  let name: [UInt8]      // フィールド名（UTF-8 バイト列）
  let typeIndex: UInt32  // Type section のインデックス
}

/// Import section のメモリインポートエントリ
struct MemoryImport: Sendable {
  let module: [UInt8]
  let name: [UInt8]
  let type: MemoryType
}

/// Import section の各エントリ（関数とメモリのみ対応）
enum Import: Sendable {
  case function(FunctionImport)
  case memory(MemoryImport)
}

// MARK: - Data Segments

/// Data section の初期化セグメント（Active 形式のみ対応）
struct DataSegment: Sendable {
  let offset: Int32   // memory への書き込み開始位置
  let bytes: [UInt8]  // 書き込むデータ
}

// MARK: - Exports

enum ExportKind: UInt8, Sendable {
  case function = 0x00
  case table    = 0x01
  case memory   = 0x02
  case global   = 0x03
}

struct Export: Sendable {
  // エクスポート名を UTF-8 バイト列として保持する。
  // String の == 比較は Unicode 正規化テーブルを要求するため、
  // 名前の照合は nameBytes どうしのバイト比較で行う。
  let nameBytes: [UInt8]
  let kind: ExportKind
  let index: UInt32

  init(nameBytes: [UInt8], kind: ExportKind, index: UInt32) {
    self.nameBytes = nameBytes
    self.kind = kind
    self.index = index
  }

  // デバッグ・表示用。比較には使わず nameBytes を用いること。
  var name: String { String(decoding: nameBytes, as: UTF8.self) }
}

// MARK: - Module

/// パース済みの Wasm モジュール。セクション単位でデータを保持する。
struct WasmModule: Sendable {
  let types: [FunctionType]    // Type section
  let imports: [Import]        // Import section
  let functions: [UInt32]      // Function section: 各ローカル関数が参照する type index
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

  /// Import section 中の関数インポート数。
  /// 関数インデックス空間は「インポート関数（0..N-1）」「ローカル関数（N..）」の順になる。
  var importedFunctionCount: Int {
    imports.reduce(0) { n, imp in
      if case .function = imp { return n + 1 }
      return n
    }
  }

  /// 関数インデックス（インポート含む統合インデックス）から FunctionType を返す
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

/// 実行時にスタックや locals が保持する値
enum Value: Sendable, Equatable {
  case i32(Int32)
}
