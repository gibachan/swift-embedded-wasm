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
/// block/loop は子命令を持つため indirect case を使用する。
/// macOS フェーズでは indirect（ヒープ確保）を許容し、正確さを優先する。
enum Instruction: Sendable {
  case localGet(UInt32)                            // 0x20: ローカル変数をスタックに積む
  case localSet(UInt32)                            // 0x21: スタックトップをローカル変数に格納
  case i32Const(Int32)                             // 0x41: i32 定数をスタックに積む
  case i32Add                                      // 0x6A: スタックトップ2値を加算
  case i32Eq                                       // 0x46: 等値比較（等しければ 1、そうでなければ 0）
  indirect case block(BlockType, [Instruction])    // 0x02: 前向きジャンプ可能なブロック
  indirect case loop(BlockType, [Instruction])     // 0x03: 後ろ向きジャンプ可能なループ
  case br(UInt32)                                  // 0x0C: 無条件ブランチ（深さ n のラベルへ）
  case brIf(UInt32)                                // 0x0D: 条件付きブランチ
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
  let functions: [UInt32]      // Function section: 各関数が参照する type index
  let memories: [MemoryType]   // Memory section
  let exports: [Export]        // Export section
  let code: [FunctionBody]     // Code section
  let start: UInt32?           // Start section: インスタンス化時に自動実行する関数インデックス

  init(
    types: [FunctionType],
    functions: [UInt32],
    memories: [MemoryType],
    exports: [Export],
    code: [FunctionBody],
    start: UInt32? = nil
  ) {
    self.types = types
    self.functions = functions
    self.memories = memories
    self.exports = exports
    self.code = code
    self.start = start
  }
}

// MARK: - Runtime Value

/// 実行時にスタックや locals が保持する値
enum Value: Sendable, Equatable {
  case i32(Int32)
}
