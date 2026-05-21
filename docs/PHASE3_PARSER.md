# Phase 3 — Wasm バイナリパーサー実装

## 目的

Wasm バイナリフォーマット（`.wasm`）を仕様に基づいて解析するパーサーを、
最初から Embedded Swift 環境をターゲットとして実装する。

---

## Wasm 仕様について

バイナリフォーマット・セクション構造・LEB128・対象バージョンの詳細は `docs/WASM_SPEC.md` を参照。

実装上の要点のみ以下に抜粋する。

- 対象: **WebAssembly 1.0 MVP**
- セクション出現順は仕様で保証されている（Type → Function → ... → Code）→ 一パス解析で完結できる
- 初期対応セクション: Type（ID=1）/ Function（ID=3）/ Export（ID=7）/ Code（ID=10）
- 整数は **LEB128** 可変長エンコード（符号なし: ULEB128 / 符号付き: SLEB128）

---

## Embedded Swift における設計上の注意点

### 1. 入力型：`[UInt8]` は使えない

Embedded Swift では動的アロケーションが原則禁止のため、`[UInt8]` や `Data` は使用不可。
Wasm バイナリは Pico のフラッシュや SRAM に置かれるため、ポインタで直接参照する。

```swift
// NG: Embedded Swift では使えない
struct BinaryReader {
    let bytes: [UInt8]
}

// OK: 生ポインタで参照（コピーなし）
struct BinaryReader {
    let base: UnsafeRawBufferPointer
    var offset: Int = 0
}
```

### 2. エラー処理：Typed throws を使う

通常の `throws` はエラーを `any Error`（existential）としてボックス化するため、
ヒープアロケーションが発生する可能性がある。Embedded Swift では**型付き throws**を使う。

```swift
enum WasmParseError {
    case invalidMagic
    case unexpectedEof
    case unsupportedVersion(UInt32)
    case unsupportedSection(id: UInt8)
    case leb128Overflow
    case tooManyFunctions
}

// 型付き throws — エラー型が静的に確定し、アロケーションが不要
mutating func readByte() throws(WasmParseError) -> UInt8
mutating func readULEB128() throws(WasmParseError) -> UInt32
```

### 3. Code Section はゼロコピーで持つ

Section ごとにデータの扱いを分ける。

| Section | データ量 | 方針 |
|---------|---------|------|
| Type | 小（シグネチャ定義） | 即パースして構造体に格納 |
| Function | 小（インデックス列） | 即パースして格納 |
| Export | 小 | 即パースして格納 |
| **Code** | **大（関数本体のバイトコード）** | **ゼロコピー：範囲だけ記録** |

Code Section の各関数は、バイナリ内でのオフセットとサイズだけを保持する。
実際のデコードはインタプリタが実行時に行う（全関数のバイトコードを一度に展開しない）。

```swift
struct FunctionHandle {
    let codeOffset: UInt32  // バイナリ内のバイトコード開始位置
    let codeSize: UInt32    // バイトコードのバイト数
}
```

### 4. 固定サイズ上限の設計

動的配列が使えないため、モジュールが持てる要素数に上限を設ける。
上限値はターゲット Wasm の規模に合わせて調整する。

```swift
enum WasmLimits {
    static let maxFunctionTypes = 64
    static let maxFunctions     = 64
    static let maxExports       = 32
}
```

固定上限を超えた場合は `WasmParseError` としてトラップする。

---

## 実装構造

### BinaryReader

```swift
struct BinaryReader {
    let base: UnsafeRawBufferPointer
    var offset: Int = 0

    mutating func readByte() throws(WasmParseError) -> UInt8
    mutating func readULEB128() throws(WasmParseError) -> UInt32
    mutating func readSLEB128() throws(WasmParseError) -> Int32
    mutating func skip(_ n: Int) throws(WasmParseError)
}
```

### 型安全な Section 表現

```swift
enum WasmSection {
    case type(TypeSection)
    case function(FunctionSection)
    case export(ExportSection)
    case code(CodeSection)
    case unknown(id: UInt8)  // 未知セクションはサイズ分スキップ
}
```

### パース済みモジュール

```swift
struct WasmModule {
    var typeCount: UInt32 = 0
    var types: (FunctionType, ...)          // 固定長バッファ

    var functionCount: UInt32 = 0
    var functionTypeIndices: (UInt32, ...)  // 固定長バッファ

    var exportCount: UInt32 = 0
    var exports: (WasmExport, ...)          // 固定長バッファ

    var functionHandles: (FunctionHandle, ...) // コードへのゼロコピー参照
}
```

### Opcode デコード（インタプリタ側で使用）

Code Section はパーサーではなくインタプリタ側でデコードする。
パーサーは `FunctionHandle` を渡すだけ。

```swift
enum Instruction {
    case i32Const(Int32)
    case i32Add
    case localGet(UInt32)
    case localSet(UInt32)
    case call(UInt32)
    case end
    case `return`
}
```

---

## 学習ポイント

- **LEB128**: 可変長整数エンコードの仕組みと実装
- **ゼロコピーパース**: ポインタ参照でコピーを避ける設計
- **Typed throws**: Embedded Swift での安全なエラー伝搬
- **固定長バッファ**: 動的配列なしでコレクションを扱う組み込み的手法
- **一パス解析**: Wasm セクション順の保証を活かした効率的な設計

---

## 成功基準

- [ ] `\0asm` マジックナンバーを検証できる
- [ ] LEB128 のデコードが正しく動作する
- [ ] Type / Function / Export Section をパースして構造体に格納できる
- [ ] Code Section を `FunctionHandle`（オフセット＋サイズ）としてゼロコピーで保持できる
- [ ] 固定上限を超えた場合に `WasmParseError` を返せる
- [ ] 簡単な Wasm バイナリ（add 関数など）を解析して内容を出力できる
