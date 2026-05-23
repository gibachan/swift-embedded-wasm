// WebAssembly バイナリパーサー・インタプリタで使うコアデータ型

// MARK: - Value Types

public enum ValueType: UInt8, Sendable {
    case i32 = 0x7F
    case i64 = 0x7E
    case f32 = 0x7D
    case f64 = 0x7C
}

// MARK: - Function Type (シグネチャ)

public struct FunctionType: Sendable {
    public let params: [ValueType]
    public let results: [ValueType]

    public init(params: [ValueType], results: [ValueType]) {
        self.params = params
        self.results = results
    }
}

// MARK: - Instructions

/// このインタプリタが対応する命令セット（最小サブセット）
public enum Instruction: Sendable {
    case localGet(UInt32)  // 0x20: ローカル変数をスタックに積む
    case i32Add            // 0x6A: スタックトップ2値を加算
    case end               // 0x0B: ブロック・関数の終端
}

// MARK: - Function Body

public struct FunctionBody: Sendable {
    /// 関数内で宣言されたローカル変数の型（引数とは別）
    public let locals: [ValueType]
    public let instructions: [Instruction]

    public init(locals: [ValueType], instructions: [Instruction]) {
        self.locals = locals
        self.instructions = instructions
    }
}

// MARK: - Exports

public enum ExportKind: UInt8, Sendable {
    case function = 0x00
    case table    = 0x01
    case memory   = 0x02
    case global   = 0x03
}

public struct Export: Sendable {
    // エクスポート名を UTF-8 バイト列として保持する。
    // String の == 比較は Unicode 正規化テーブルを要求するため、
    // 名前の照合は nameBytes どうしのバイト比較で行う。
    public let nameBytes: [UInt8]
    public let kind: ExportKind
    public let index: UInt32

    public init(nameBytes: [UInt8], kind: ExportKind, index: UInt32) {
        self.nameBytes = nameBytes
        self.kind = kind
        self.index = index
    }

    // デバッグ・表示用。比較には使わず nameBytes を用いること。
    public var name: String { String(decoding: nameBytes, as: UTF8.self) }
}

// MARK: - Module

/// パース済みの Wasm モジュール。セクション単位でデータを保持する。
public struct WasmModule: Sendable {
    public let types: [FunctionType]    // Type section
    public let functions: [UInt32]      // Function section: 各関数が参照する type index
    public let exports: [Export]        // Export section
    public let code: [FunctionBody]     // Code section

    public init(
        types: [FunctionType],
        functions: [UInt32],
        exports: [Export],
        code: [FunctionBody]
    ) {
        self.types = types
        self.functions = functions
        self.exports = exports
        self.code = code
    }
}

// MARK: - Runtime Value

/// 実行時にスタックや locals が保持する値
public enum Value: Sendable, Equatable {
    case i32(Int32)
}
