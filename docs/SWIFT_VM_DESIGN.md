# Swift Wasm VM 設計方針

本ドキュメントは、Swift で Wasm VM を実装するにあたっての設計方針をまとめる。
wasm3 の調査結果（`docs/PHASE2_WASM3.md`）を踏まえ、Swift の言語機能を活かしながら
組み込み制約にも対応できる設計を定義する。

---

## 1. 設計の基本原則

### 原則 1: 理解のための設計
最初から高速・完全を目指さない。各コンポーネントの役割と責任が明確に読み取れる
コードを優先する。最適化は、仕組みを理解したあとに行う。

### 原則 2: Swift の型安全性を最大限活かす
wasm3 が C の制約上やむなく型なし（`union` / `void*` / `const char*`）で扱っている
部分を、Swift の enum・generics・protocol で型安全に再設計する。

### 原則 3: ビルドターゲットを意識した 2 段構え
macOS ビルド（開発・デバッグ用）と Pico ビルド（組み込み用）で
要件が異なる部分は、コンパイルフラグで切り替える。
両者で共通のコアを保ちながら、制約の厳しい部分だけを分岐させる。

### 原則 4: Incremental に動くものを作る
1 命令ずつ確認できる粒度で実装を進める（`docs/OVERVIEW.md` の方針に従う）。

---

## 2. コンポーネント構成

```text
┌─────────────────────────────────────────────────┐
│                  WasmRuntime                    │
│  ┌──────────┐  ┌───────────┐  ┌─────────────┐  │
│  │  Parser  │  │ Validator │  │ Interpreter │  │
│  └──────────┘  └───────────┘  └─────────────┘  │
│  ┌──────────────────────────────────────────┐   │
│  │              Module                      │   │
│  │  FuncType[] / Function[] / Global[]      │   │
│  │  LinearMemory / DataSegment[]            │   │
│  └──────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────┐   │
│  │           HostFunctionTable              │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

| コンポーネント | 役割 |
|---|---|
| `Parser` | Wasm バイナリを `Module` に変換する |
| `Validator` | Module の型整合性を検証する（ビルドターゲットにより深度が異なる） |
| `Interpreter` | Module を実行する（Stack Machine） |
| `Module` | パース済みの Wasm モジュール（関数・メモリ・グローバル変数） |
| `LinearMemory` | Wasm の線形メモリ空間。境界チェックを担う |
| `HostFunctionTable` | Swift の関数を Wasm に公開するテーブル |

---

## 3. 型設計

### 3.1 Wasm 値型

wasm3 は `union { i32; i64; f32; f64 } + u8 type` で値を保持し、型の不一致はランタイムエラー。
Swift では associated value 付き enum で型安全に表現する。

```swift
enum WasmValue {
    case i32(Int32)
    case i64(Int64)
    case f32(Float)
    case f64(Double)
}
```

### 3.2 Wasm 型

```swift
enum WasmType: UInt8 {
    case i32 = 0x7F
    case i64 = 0x7E
    case f32 = 0x7D
    case f64 = 0x7C
}
```

### 3.3 関数シグネチャ

```swift
struct FuncType: Equatable {
    let params: [WasmType]
    let results: [WasmType]
}
```

### 3.4 エラー型

wasm3 は `M3Result = const char*`（NULL が成功、非 NULL がエラーメッセージ）という設計。
Swift では型安全な `Error` enum に分類する。

```swift
// パース・バリデーション時のエラー
enum WasmFormatError: Error {
    case invalidMagicNumber
    case unsupportedVersion(UInt32)
    case malformedSection(id: UInt8)
    case misorderedSection
    case typeMismatch(expected: WasmType, got: WasmType)
    case indexOutOfRange(index: UInt32, count: UInt32)
    case unknownOpcode(UInt8)
}

// 実行時のトラップ（Wasm 仕様で定義された実行中断）
enum WasmTrap: Error {
    case unreachable
    case stackOverflow
    case outOfBoundsMemoryAccess(offset: UInt64, size: UInt32, limit: Int)
    case integerDivisionByZero
    case integerOverflow
    case indirectCallTypeMismatch
    case tableIndexOutOfRange
    case callStackExhausted
}
```

---

## 4. バリデーション方針（2 段構え）

wasm3 はバリデーションフェーズを持たず、型チェックは未実装（`ValidateBlockEnd` がスタブ）。
本プロジェクトではビルドターゲット別に深度を切り替える。

### macOS ビルド（開発・デバッグ用）

**フルバリデーションあり。**

- 関数シグネチャの型整合性チェック
- 命令ごとのスタック型チェック（型スタックを追跡）
- ジャンプ先インデックスの有効性チェック
- 不正な Wasm は実行前に `WasmFormatError` として検出

目的: 開発中に誤った Wasm バイナリや実装バグを早期に発見する。

```swift
// macOS ビルドでのみ有効
#if MACOS
struct Validator {
    func validate(_ module: Module) throws {
        try validateTypes(module)
        try validateFunctions(module)
        try validateInstructions(module)
    }
}
#endif
```

### Pico ビルド（組み込み用）

**構造チェックのみ。型チェックは省略。**

- マジックナンバー・バージョン確認
- セクション順序・インデックス範囲チェック
- 上限値チェック（RAM 枯渇防止）
- 型スタックの追跡はしない（RAM 節約・ロード時間短縮）

目的: RAM と実行時間を節約する。信頼された入力（開発者が制御するバイナリ）を前提とする。

```swift
// 共通の構造チェック（常に実行）
struct StructuralChecker {
    func check(_ module: Module) throws {
        guard module.magic == 0x6d736100 else { throw WasmFormatError.invalidMagicNumber }
        // インデックス範囲など最小限のチェック
    }
}
```

### 切り替え方法

`MACOS` フラグは `swift test` 実行時に `-Xswiftc -DMACOS` で渡される。
Pico 向け `make compile` / `make build` ではフラグを渡さないため、
デフォルト（フラグなし）= 組み込み向け構造チェックのみ、という関係になる。

```makefile
# Makefile
swift-test:
    swift test -Xswiftc -DMACOS   # macOS: MACOS フラグあり

SWIFTFLAGS := ...                 # Pico: MACOS フラグなし（デフォルト）
```

```swift
// Swift ソース側（共通コード）
#if MACOS
// macOS: フルバリデーション
typealias ModuleValidator = Validator
#else
// Pico（デフォルト）: 構造チェックのみ
typealias ModuleValidator = StructuralChecker
#endif
```

---

## 5. Interpreter Loop 方針

wasm3 は **Threaded Code**（関数ポインタ配列 + tail call）でディスパッチするが、
Embedded Swift では tail call 最適化が保証されない可能性がある。

本プロジェクトでは以下の方針を採る。

### フェーズ 1: switch ベース（学習フェーズ）

最初はシンプルな `switch` ベースで実装する。
可読性が高く、デバッグしやすく、Embedded Swift との互換性が確実。

```swift
mutating func step() throws {
    let opcode = try fetch()
    switch opcode {
    case 0x41: // i32.const
        let value = try fetchLEB128() as Int32
        stack.push(.i32(value))
    case 0x6A: // i32.add
        let b = try stack.popI32()
        let a = try stack.popI32()
        stack.push(.i32(a &+ b))
    case 0x0F: // return
        try doReturn()
    // ...
    default:
        throw WasmFormatError.unknownOpcode(opcode)
    }
}
```

### フェーズ 2: 最適化（必要になった時点で）

Pico 上での実測でボトルネックが判明した場合にのみ最適化を検討する。
現時点では設計に含めない。

---

## 6. Linear Memory 方針

### 共通設計

```swift
struct LinearMemory {
    private var bytes: UnsafeMutableRawBufferPointer
    private(set) var size: Int

    func load<T: FixedWidthInteger>(at offset: UInt32, as: T.Type) throws -> T {
        let end = Int(offset) + MemoryLayout<T>.size
        guard end <= size else {
            throw WasmTrap.outOfBoundsMemoryAccess(
                offset: UInt64(offset),
                size: UInt32(MemoryLayout<T>.size),
                limit: size
            )
        }
        return bytes.loadUnaligned(fromByteOffset: Int(offset), as: T.self)
    }
}
```

### macOS ビルド

- `[UInt8]` またはヒープ確保の `UnsafeMutableRawBufferPointer`
- `memory.grow` による動的拡張をサポート

### Pico ビルド

- **固定サイズで静的確保**（動的 realloc を避ける）
- `memory.grow` は無効化またはコンパイルエラー
- Pico の RAM（264 KB）に収まるサイズを事前に決定する

```swift
#if MACOS
// macOS: 動的拡張あり
let linearMemory = LinearMemory(initialPages: 1, maxPages: 16)
#else
// Pico（デフォルト）: 固定サイズ（例: 64KB）
let linearMemory = LinearMemory(staticSize: 65536)
#endif
```

---

## 7. Host Function 設計

wasm3 はシグネチャ文字列 `"v(ii)"` でランタイム型チェック。
Swift ではクロージャで登録し、コンパイル時に型を確認できる方向を目指す。

### 基本設計

```swift
struct HostFunction {
    let module: String
    let name: String
    let type: FuncType
    let body: ([WasmValue], inout LinearMemory) throws -> [WasmValue]
}

class HostFunctionTable {
    private var table: [String: HostFunction] = [:]

    func register(_ fn: HostFunction) {
        table["\(fn.module).\(fn.name)"] = fn
    }

    func call(module: String, name: String,
              args: [WasmValue], memory: inout LinearMemory) throws -> [WasmValue] {
        guard let fn = table["\(module).\(name)"] else {
            throw WasmFormatError.unknownOpcode(0) // TODO: 専用エラー
        }
        return try fn.body(args, &memory)
    }
}
```

### 初期 Host API（GPIO）

```swift
let table = HostFunctionTable()

table.register(HostFunction(
    module: "env", name: "digitalWrite",
    type: FuncType(params: [.i32, .i32], results: [])
) { args, _ in
    let pin = args[0].asI32!
    let value = args[1].asI32!
    GPIO.write(pin: UInt8(pin), value: value != 0)
    return []
})
```

---

## 8. wasm3 との対比まとめ

| 項目 | wasm3 (C) | 本プロジェクト (Swift) |
|---|---|---|
| エラー型 | `const char*`（NULL = 成功） | `enum WasmFormatError / WasmTrap: Error` |
| 値の保持 | `union + u8 type` | `enum WasmValue` with associated value |
| バリデーション | なし（スタブ） | macOS: フル / Pico: 構造チェックのみ |
| Host Function 登録 | 文字列シグネチャ `"v(ii)"` | クロージャ（型は Swift 型システムで確認） |
| Opcode ディスパッチ | Threaded Code（関数ポインタ + tail call） | switch ベース（フェーズ 1） |
| メモリ管理 | 手動（`malloc` / `realloc`） | `deinit` / 固定バッファ（Pico） |
| スレッド安全性 | なし | `actor` で分離（macOS のみ） |
| 所有権 | `IM3Runtime*` などポインタで疑似管理 | `class` + ARC / value semantics |

---

## 9. 関連ドキュメント

| ドキュメント | 内容 |
|---|---|
| `docs/PHASE2_WASM3.md` | wasm3 ソースコード調査結果・Swift 転用ポイント |
| `docs/PHASE3_PARSER.md` | バイナリパーサーの実装計画 |
| `docs/PHASE4_INTERPRETER.md` | インタプリタの実装計画 |
| `docs/WASM_SPEC.md` | Wasm 仕様の参照まとめ |
| `docs/OVERVIEW.md` | プロジェクト全体方針・インクリメンタル開発方針 |
