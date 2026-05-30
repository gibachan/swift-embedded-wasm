# Phase 3 — Wasm バイナリパーサー実装

## 目的

Wasm バイナリフォーマット（`.wasm`）を仕様に基づいて解析するパーサーを、
最初から Embedded Swift 環境をターゲットとして実装する。

---

## Wasm 仕様について

バイナリフォーマット・セクション構造・LEB128・対象バージョンの詳細は `Documentations/WASM_SPEC.md` を参照。

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

### 3. Code Section の扱い

Section ごとにデータの扱いを分ける。

| Section | データ量 | Embedded 目標方針 | 現在の macOS フェーズ実装 |
|---------|---------|------|------|
| Type | 小（シグネチャ定義） | 即パースして構造体に格納 | 同左 |
| Function | 小（インデックス列） | 即パースして格納 | 同左 |
| Export | 小 | 即パースして格納 | 同左 |
| **Code** | **大（関数本体のバイトコード）** | **ゼロコピー：範囲だけ記録** | **全命令をパース時に展開して `FunctionBody` として格納** |

Embedded フェーズへの移行時には、Code Section を `FunctionHandle`（オフセット＋サイズ）として
ゼロコピーで保持し、インタプリタが実行時に逐次デコードする形に変更することが目標。
現在の macOS フェーズでは、パース時に全命令を `Instruction` enum の配列へ展開している。

```swift
// Embedded フェーズの目標設計（未実装）
struct FunctionHandle {
    let codeOffset: UInt32  // バイナリ内のバイトコード開始位置
    let codeSize: UInt32    // バイトコードのバイト数
}

// 現在の macOS フェーズ実装（WasmModule.swift: FunctionBody）
struct FunctionBody {
    let locals: [ValueType]
    let instructions: [Instruction]  // パース時に全命令を展開
}
```

### 4. 固定サイズ上限の設計（Embedded フェーズで必要）

Embedded フェーズでは動的配列が使えないため、モジュールが持てる要素数に上限を設ける。
macOS フェーズでは `Array<T>` を使用しているため、現時点では上限は設けていない。

```swift
// Embedded フェーズで必要になる設計（未実装）
enum WasmLimits {
    static let maxFunctionTypes = 64
    static let maxFunctions     = 64
    static let maxExports       = 32
}
```

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

## バイナリ検証（Wasm 仕様 §6.5 準拠）

macOS フェーズでは、パーサーに仕様準拠のバイナリ整合性チェックを追加している。
これらはパース時に検出されたフォーマット違反として `WasmError` を throw する。

### 実装済み検証チェック

| チェック | エラー | 条件 |
|---------|------|------|
| Section ID 上限 | `malformedSectionId` | section id > 12 |
| Section サイズ整合性 | `sectionSizeMismatch` | 宣言サイズと実際の消費バイト数が不一致 |
| セクション重複 | `duplicateSection` | 同一 ID（1–11）のセクションが 2 回以上出現 |
| セクション出現順序 | `sectionOutOfOrder` | ID が昇順でない（カスタムセクション id=0 を除く）|
| Data Count 整合性 | `dataCountMismatch` | Data Count section の値と Data セクションのセグメント数が不一致 |
| Data Count 必須 | `dataCountRequired` | `memory.init` / `data.drop` が使われているのに Data Count section がない |

### その他のパーサー検証（実装済み）

- **カスタムセクション名の UTF-8 検証**: オーバーロング・サロゲート・範囲外バイトを検出 → `malformedUTF8`
- **バイナリ末尾の余分なバイト検出**: 最終セクション後に残バイトがある場合 → `unexpectedContent`
- **LEB128 標準形式チェック**: 終端バイトが冗長にゼロパディングされている場合 → `integerRepresentationTooLong`
- **Element segment reftype 検証**: flags=5/6/7 の reftype バイトが funcref(0x70) / externref(0x6F) 以外の場合はエラー

### spectest `[binary]` テスト結果

| 時点 | pass | skip | fail |
|------|------|------|------|
| externref 実装後 | 96 | 31 | 0 |
| バイナリ検証追加後 | 127 | 0 | 0 |

---

## 成功基準（macOS フェーズ）

- [x] `\0asm` マジックナンバーを検証できる
- [x] LEB128 のデコードが正しく動作する
- [x] Type / Function / Export / Import / Table / Memory / Global / Element / Data Section をパースして構造体に格納できる
- [x] Code Section を `FunctionBody`（`[Instruction]` の展開済み配列）として保持できる
- [x] 簡単な Wasm バイナリ（add 関数など）を解析して内容を出力できる
- [x] Section ID / サイズ / 重複 / 順序 / Data Count の整合性チェックが仕様準拠で動作する（spectest `[binary]` 127 pass / 0 skip / 0 fail）

## 今後の課題（Embedded フェーズ）

- [ ] Code Section を `FunctionHandle`（オフセット＋サイズ）としてゼロコピーで保持する
- [ ] 固定上限 (`WasmLimits`) を設けて動的配列を排除する
