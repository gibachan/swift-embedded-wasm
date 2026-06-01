# Swift Wasm VM 設計方針

Swift で Wasm VM を実装するにあたっての設計方針と、Embedded Swift 環境での制約・対応パターンをまとめる。
wasm3 の調査結果（`Documentations/PHASE2_WASM3.md`）を踏まえ、Swift の言語機能を活かしながら
組み込み制約にも対応できる設計を定義する。

---

## 1. 設計の基本原則

### 原則 1: 理解のための設計
最初から高速・完全を目指さない。各コンポーネントの役割と責任が明確に読み取れる
コードを優先する。最適化は、仕組みを理解したあとに行う。

### 原則 2: Swift の型安全性を最大限活かす
wasm3 が C の制約上やむなく型なし（`union` / `void*` / `const char*`）で扱っている
部分を、Swift の enum・generics・protocol で型安全に再設計する。

### 原則 3: 最初から Embedded Swift 制約に合わせる
macOS ビルド（開発・デバッグ用）と Pico ビルド（組み込み用）で共通のソースを維持し、
最初から Embedded Swift の制約に合わせて実装する。

- ホットパスの中間配列コピー（`Array(xxx.suffix(n))`）は作らない
- `String ==` 比較は使わない（`[UInt8]` バイト列比較で代替）
- `throws(ErrorType)` の typed throws を常に使う
- 構造上避けられない動的確保は `// TODO: Embedded Phase 5` で明示する

バリデーター（`WasmValidator`）のみ `#if !hasFeature(Embedded)` で分岐する。
Embedded ビルドでは信頼された入力（開発者が制御するバイナリ）を前提として型チェックを省略する。

### 原則 4: Incremental に動くものを作る
1 命令ずつ確認できる粒度で実装を進める（`Documentations/OVERVIEW.md` の方針に従う）。

---

## 2. コンポーネント構成

```text
┌─────────────────────────────────────────────────┐
│                  WasmRuntime                    │
│  ┌──────────┐  ┌───────────┐  ┌─────────────┐  │
│  │  Parser  │  │ Validator │  │ Interpreter │  │
│  └──────────┘  └───────────┘  └─────────────┘  │
│  ┌──────────────────────────────────────────┐   │
│  │              WasmModule                  │   │
│  │  FunctionType[] / Function[] / Global[]  │   │
│  │  [UInt8] memory / DataSegment[]          │   │
│  └──────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────┐   │
│  │           HostFunctionTable              │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

| コンポーネント | 役割 |
|---|---|
| `WasmParser` | Wasm バイナリを `WasmModule` に変換する |
| `WasmValidator` | Module の型整合性を検証する（`#if !hasFeature(Embedded)` でのみ有効） |
| `WasmInterpreter` | Module を実行する（Stack Machine）。`droppedDataSegments: [Bool]` で `data.drop` 状態を追跡 |
| `WasmModule` | パース済みの Wasm モジュール（関数・メモリ・グローバル変数）。`DataSegment.offset: Int32?`（nil = passive、非 nil = active のメモリ書き込みオフセット） |
| Linear Memory | `var memory: [UInt8]`（インタプリタが保持）。境界チェックを担う |
| Host Function Table | `[HostFunction]` 配列（import 宣言順でインデックス管理） |

---

## 3. 型設計

### 3.1 Wasm 値型

wasm3 は `union { i32; i64; f32; f64 } + u8 type` で値を保持し、型の不一致はランタイムエラー。
Swift では associated value 付き enum で型安全に表現する。

実装では `Value`（ランタイム値）と `ValueType`（型コード）に分けている。

```swift
// ランタイム上の値 (WasmModule.swift: enum Value)
enum Value: Sendable, Equatable {
    case i32(Int32)
    case i64(Int64)
    case f32(Float)
    case f64(Double)
    case funcref(UInt32?)   // nil = null reference; UInt32 = function index
    case externref(UInt32?) // nil = null reference; UInt32 = opaque host index
}
```

### 3.2 Wasm 型コード

```swift
// 型コード (WasmModule.swift: enum ValueType)
enum ValueType: UInt8 {
    case i32      = 0x7F
    case i64      = 0x7E
    case f32      = 0x7D
    case f64      = 0x7C
    case funcref  = 0x70  // reference to a function
    case externref = 0x6F // opaque host reference
}
```

### 3.3 関数シグネチャ

```swift
// WasmModule.swift: struct FunctionType
struct FunctionType: Sendable {
    let params: [ValueType]
    let results: [ValueType]
}
```

### 3.4 エラー型

wasm3 は `M3Result = const char*`（NULL が成功、非 NULL がエラーメッセージ）という設計。
Swift では型安全な `Error` enum に分類し、パース時エラーと実行時トラップを統合している。

```swift
// WasmError.swift: enum WasmError
enum WasmError: Error, Equatable, Sendable {
    // --- Parser ---
    case invalidMagic
    case unexpectedEnd
    case invalidInstruction(UInt8)
    case leb128Error(LEB128Error)
    // ... その他パースエラー

    // --- Interpreter（トラップ相当）---
    case stackUnderflow
    case typeMismatch
    case memoryAccessOutOfBounds
    case divisionByZero
    case unreachableReached
    case indirectCallTypeMismatch
    // ... その他実行時エラー
}
```

typed throws（`throws(WasmError)`）を常に使い、`any Error` existential を回避する。
これは Embedded Swift 制約（existential 禁止）への適合でもある。

---

## 4. バリデーション方針

wasm3 はバリデーションフェーズを持たず、型チェックは未実装。
本プロジェクトでは `#if !hasFeature(Embedded)` で切り替える。

### 非 Embedded ビルド（macOS 開発・デバッグ用）

**フルバリデーションあり。**

- 関数シグネチャの型整合性チェック
- 命令ごとのスタック型チェック（型スタックを追跡）
- 不正な Wasm は実行前に `WasmError` として検出

```swift
// WasmParser.swift
#if !hasFeature(Embedded)
try WasmValidator(module: module).validate()
#endif
```

```swift
// WasmValidator.swift
#if !hasFeature(Embedded)
struct WasmValidator {
    func validate() throws(WasmError) { ... }
}
#endif
```

目的: 開発中に誤った Wasm バイナリや実装バグを早期に発見する。

### Embedded ビルド（Pico 組み込み用）

**バリデーション省略。**

- マジックナンバー・バージョン確認（パーサー内で常に実施）
- 型スタックの追跡はしない（RAM 節約・ロード時間短縮）
- 信頼された入力（開発者が制御するバイナリ）を前提とする

---

## 5. インタプリタループ方針

wasm3 は **Threaded Code**（関数ポインタ配列 + tail call）でディスパッチするが、
Embedded Swift では tail call 最適化が保証されない。

本プロジェクトでは `switch` ベースで実装する。

### フェーズ 1: switch ベース（実装済み）

```swift
switch instruction {
case .i32Const(let value):
    valueStack.append(.i32(value))
case .i32Add:
    let b = valueStack.removeLast()
    let a = valueStack.removeLast()
    // ...
case .call(let funcIdx):
    try pushFrame(funcIdx: Int(funcIdx), argCount: argCount)
}
```

可読性が高く、デバッグしやすく、Embedded Swift との互換性が確実。
`switch` の網羅性チェックにより、命令追加時の漏れをコンパイラが検出する。

### フェーズ 1.5: Flat Bytecode への移行（完了）

以前の実装では `block` / `loop` / `if` 命令が子命令を入れ子の配列として保持していた。

```swift
// 旧実装（indirect case = malloc が必要）
indirect case block(BlockType, [Instruction])
indirect case ifElse(BlockType, thenBody: [Instruction], elseBody: [Instruction])
```

`indirect case` は Embedded Swift でもコンパイルは通るが、リンク時に `malloc` が要求される。

**採用した解決策: Flat Bytecode + ジャンプオフセット（実装済み）**

```swift
// 現在の実装（malloc 不要）
case block(BlockType, Int)       // endPc: block 出口の命令インデックス
case loop(BlockType, Int)        // startPc: br 0 で戻る先（loop の先頭）
case ifElse(BlockType, Int, Int) // elsePc, endPc
case blockEnd                    // block/loop/if 本体の終端マーカー
case jump(Int)                   // else 本体をスキップする無条件ジャンプ
```

全命令をフラットな配列に並べ、block/loop/if にはジャンプ先 PC を直接持たせる。
パーサーがオフセットを計算して埋め込む。
CPython bytecode や JavaScriptCore が実際に採用している方式で、学習価値も高い。

### フェーズ 2: さらなる最適化（必要になった時点で）

Pico 上での実測でボトルネックが判明した場合にのみ検討する。現時点では設計に含めない。

---

## 6. Linear Memory 方針

### 現在の実装

```swift
// WasmInterpreter.swift
var memory: [UInt8]
```

`[UInt8]` で動的確保する。`pico_stdlib` が `posix_memalign`/`free` を提供するため、
`pico-ble` ターゲットではリンクが通る。境界チェックは明示的に実施する。

```swift
// 境界チェックの例
let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
guard ea >= 0 && ea + 4 <= memory.count else { throw .memoryAccessOutOfBounds }
```

### Phase 5 以降の課題

- `memory.grow` の動的 realloc は RAM が限られる Pico では慎重に扱う
- 純粋ベアメタル環境（`pico_stdlib` なし）では固定サイズバッファへの置き換えが必要
- 32 ビットターゲット（Pico / RP2350）では `Int` が 32 ビット幅になるため、実効アドレス計算で `UInt64` 中間演算が必要

```swift
// TODO: Embedded Phase 5 — 32ビットターゲット向けオーバーフロー対策
let ea64 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset)
guard ea64 + UInt64(accessWidth) <= UInt64(memory.count) else { throw .memoryAccessOutOfBounds }
let ea = Int(ea64)
```

---

## 7. Host Function 設計

wasm3 はシグネチャ文字列 `"v(ii)"` でランタイム型チェック。
本プロジェクトではクロージャで登録し、import 宣言順の配列で管理する。

```swift
// WasmInterpreter.swift
typealias HostFunction = ([Value], [UInt8]) -> [Value]

enum HostImport {
    case function(String, String, HostFunction) // (module, name, body)
    case memory(String, String, UInt32)          // (module, name, pages)
}
```

`WasmInterpreter.init()` で `hostImports` を import 宣言順にマッチングし、
`[HostFunction]` 配列として保持する。インデックスで O(1) アクセス。

この設計の利点:
- `class` を使わないため Embedded Swift 準拠
- `Dictionary`（`[String: ...]`）の代わりに配列を使うことで動的ハッシュ計算を回避
- モジュール名・関数名の比較は `elementsEqual` によるバイト列比較（`String ==` を回避）

```swift
// 使用例
let hostImports: [HostImport] = [
    .function("env", "gpio_put") { args, _ in
        // GPIO 操作
        return []
    }
]
let interpreter = try WasmInterpreter(module: module, hostImports: hostImports)
```

---

## 8. Embedded Swift 制約と対応パターン

Embedded Swift は通常の Swift（macOS/iOS 向け）と比べて利用できる機能が大幅に制限される。

### 8.1 使用できない機能

#### Existential 型（`any Protocol`）

プロトコル型を値として扱う existential は使用できない。

```swift
// NG: Embedded Swift では使用不可
func process(_ stream: any ByteStream) { ... }

// OK: ジェネリック制約で代替する
func process<S: ByteStream>(_ stream: inout S) { ... }
```

**理由**: Existential はランタイムにプロトコルウィットネステーブルを保持するが、
Embedded Swift ではそのランタイム機構が存在しない。

#### リフレクション

`Mirror` や `type(of:)` によるランタイム型情報の取得は使用できない。型の判別は enum の associated value やジェネリックで静的に行う。

#### Foundation フレームワーク

`import Foundation` は使用できない。

| 使用不可 | 代替 |
|---|---|
| `Data` | `[UInt8]` / `UnsafeBufferPointer<UInt8>` |
| `String`（動的生成） | `StaticString` / バイト列 |
| `URL` | 文字列リテラル / 静的定数 |
| `Date` | `UInt64`（tick カウント等） |

#### 動的メモリ割り当て

`Array<T>` の `append` などの動的操作はコンパイルは通るが、リンク時に `malloc` が要求される。
`pico_stdlib` リンクあり環境では動作するが、純粋ベアメタル（stdlib なし）ではリンクエラーになる。

```
[コンパイル] .swift → .o  ← Array.append があってもエラーにならない
[リンク]     .o → .elf   ← malloc が未定義なら "undefined reference to '_malloc'" でエラー
```

同様に `indirect case` もコンパイルは通るがリンク時に `malloc` を要求する。

#### `String ==` による比較

`String` の等値比較は Unicode 正規化を伴い、Embedded Swift にはその正規化テーブルが含まれない。
コンパイルは通るがリンクエラーになる。

```swift
// NG: リンクエラーになる
module.exports.first { $0.name == "increment" }

// OK: バイト列どうしで比較する
module.exports.first { $0.nameBytes.elementsEqual("increment".utf8) }
```

#### Untyped Error（`any Error`）

`func f() throws` のような型なし throws は existential `any Error` を使うため使用禁止。

### 8.2 使用すべきパターン

#### ジェネリックによる抽象化

```swift
protocol ByteStream {
    mutating func consume() throws(LEB128Error) -> UInt8
}

// コンパイル時に S の実体が決定 → 静的ディスパッチ
func decode<S: ByteStream>(from stream: inout S) throws(LEB128Error) -> UInt32 { ... }
```

#### 型付き `throws`（Swift 6）

```swift
// OK: 具体的なエラー型を指定
func consume() throws(LEB128Error) -> UInt8

// NG: any Error を内部で使用する
func consume() throws -> UInt8
```

#### `UnsafeBufferPointer` によるゼロコピー読み出し

```swift
struct BufferStream: ByteStream {
    let buffer: UnsafeBufferPointer<UInt8>
    var offset: Int

    mutating func consume() throws(LEB128Error) -> UInt8 {
        guard offset < buffer.count else { throw .insufficientBytes }
        defer { offset += 1 }
        return buffer[offset]
    }
}
```

#### 値型（struct / enum）の優先

クラス（参照型）はヒープ割り当てが発生する。スタックに収まる値型を基本とする。

```swift
// NG: ヒープ割り当て発生
class WasmModule { ... }

// OK: スタック割り当て
struct WasmModule { ... }
```

---

## 9. パフォーマンス最適化

### `@inlinable`：ジェネリック関数への必須指定

Embedded Swift ではプロトコルウィットネステーブルの動的解決が利用できない。
ジェネリック関数はコンパイル時に特殊化されなければならず、モジュール境界を越える場合は `@inlinable` が必須。

```swift
@inlinable
public func decodeULEB128<T: FixedWidthInteger & UnsignedInteger, S: ByteStream>(
    from stream: inout S
) throws(LEB128Error) -> T { ... }
```

| | `@inlinable` | `@inline(__always)` |
|---|---|---|
| 目的 | モジュール外への実装公開・特殊化許可 | 呼び出し元での強制展開 |
| コンパイラの裁量 | コンパイラが判断して展開 | 無条件に展開 |
| 主な用途 | ジェネリック関数・モジュール境界 | ループ内の極小関数 |

### ホットパスでの一時配列確保を避ける

インタプリタループのように毎命令呼ばれるコードパスでは、中間配列の確保がヒープ圧力になる。

```swift
// NG: br/return のたびにヒープ確保が発生する
let results = Array(valueStack.suffix(arity))
valueStack.removeSubrange(base...)
valueStack.append(contentsOf: results)

// OK: in-place スライドで同じ意味を実現（確保ゼロ）
let src = valueStack.count - arity
for i in 0..<arity { valueStack[base + i] = valueStack[src + i] }
valueStack.removeSubrange((base + arity)...)
```

`pushFrame` でも `Array(valueStack.suffix(argCount))` の中間コピーを排除し、
`valueStack` から直接引数を読む設計に移行済み。

### ホットパスで参照する computed property はキャッシュする

```swift
// NG: 毎回 imports を全走査する
var importedFunctionCount: Int {
    imports.reduce(0) { n, imp in if case .function = imp { return n + 1 }; return n }
}

// OK: init 時に一度だけ計算し stored property に保持
let importedFunctionCount: Int
```

`WasmModule` では `importedFunctionCount` を `init` 時に計算して `let` として保持済み。

### `&<<`（オーバーフローシフト）の使用

符号付き整数の通常の左シフト（`<<`）はオーバーフロー時にランタイムトラップが発生する。
意図的なビット操作には `&<<` を使う。

```swift
// NG: オーバーフロートラップが発生する可能性
result |= T(byte & 0x7F) << shift

// OK: ビットパターンをそのまま扱う
result |= T(byte & 0x7F) &<< shift
```

---

## 10. メモリレイアウトとデバッグ

### `@frozen` enum と struct

Embedded Swift では型のメモリレイアウトが固定されていることが前提になる場合がある。
公開する型には `@frozen` を検討する。

### スタックサイズ

Pico のデフォルトスタックサイズは数 KB 程度。再帰呼び出しや大きなスタック変数は避ける。

### デバッグ

Embedded 環境では `print` が使えない（または UART 等に繋がっている）。

- デバッグ出力が必要な場合は、ターゲット固有の出力関数（UART 書き込み等）を使う
- インライン化された関数はスタックトレースに現れないことを念頭に置く
- `assert` / `precondition` の挙動はターゲットのトラップ実装に依存する

---

## 11. wasm3 との対比まとめ

| 項目 | wasm3 (C) | 本プロジェクト (Swift) |
|---|---|---|
| エラー型 | `const char*`（NULL = 成功） | `enum WasmError: Error`（パーサー・インタプリタ統合） |
| 値の保持 | `union + u8 type` | `enum Value` with associated value |
| バリデーション | なし（スタブ） | `#if !hasFeature(Embedded)`: フル（`WasmValidator`） / Embedded: 省略 |
| Host Function 登録 | 文字列シグネチャ `"v(ii)"` | `HostFunction` クロージャ配列（import 順で管理） |
| Opcode ディスパッチ | Threaded Code（関数ポインタ + tail call） | `switch` on `Instruction` enum |
| 制御フロー表現 | ネストした関数呼び出し | フラット bytecode + ジャンプオフセット（フェーズ 1.5 完了） |
| メモリ管理 | 手動（`malloc` / `realloc`） | `[UInt8]`（動的。Phase 5 で固定バッファへ移行予定） |
| スレッド安全性 | なし | シングルスレッド前提の `struct`（`actor` は Embedded 非対応） |
| 所有権 | `IM3Runtime*` などポインタで疑似管理 | `struct` + value semantics |

---

## 12. Swift の強みを活かした設計ポイント

### 12.1 enum の網羅性チェックによる仕様との 1:1 対応

Swift の `enum` は Wasm の値型・命令セット・エラー種別を仕様と 1:1 で表現できる。
`switch` の網羅性チェックにより、命令セットを追加した際の未処理ケースをコンパイラが検出する。

```swift
// 命令追加時の漏れをコンパイラが検出 — C では実行時に壊れるまで気づかない
switch instruction {
case .i32Add: ...
case .i32Sub: ...
// ← 新命令を足し忘れるとコンパイルエラー
}
```

### 12.2 Typed Throws によるトラップの構造化

`throws(WasmError)` はエラー種別をシグネチャに記述することで、
どのエラーが起きうるかが関数のシグネチャ自体から読み取れる。
Wasm3 の `M3Result = const char*` では文字列比較が必要だった部分を型安全に代替する。

### 12.3 Value Semantics による実行状態の明確化

`struct` + `mutating` で設計することで、状態の変更は明示的な `mutating` 呼び出しを通じてのみ起きる。
実行コンテキストのスナップショットが自然に書けるため、ステップ実行・テストに有用。

### 12.4 Embedded Swift の制約がアーキテクチャを改善させる

`class` 禁止・動的確保制限という制約は、意図せず良い設計を促す副作用を持つ。

- ヒープ確保を避けるため固定サイズバッファを選ぶ → メモリ使用量の予測可能性が上がる
- 参照の共有がないため所有関係が明確になる
- クロージャのヒープキャプチャが制限される → Host Function が自然に静的テーブル設計へ向かう

### 12.5 デバッグビルドの安全性

Swift はデバッグビルドで整数オーバーフロー・配列境界外アクセスをランタイムトラップする。
C ではこれらは未定義動作として silently 壊れる可能性がある。
Pico の UART ログのみのデバッグ環境では、問題発生箇所が明確なトラップは大きな価値を持つ。

### 12.6 Protocol + Generics による算術演算の一元化（設計案）

Wasm の整数演算（`i32`/`i64`）は同一の意味論を持ちながら bit-width だけが異なる。
WasmKit の `RawUnsignedInteger` プロトコル設計を参考に、`WasmInteger` プロトコルで一元化できる。

```swift
// 設計案（未実装）
protocol WasmInteger: FixedWidthInteger & UnsignedInteger {
    associatedtype Signed: FixedWidthInteger & SignedInteger
    init(bitPattern: Signed)
}
extension UInt32: WasmInteger { typealias Signed = Int32 }
extension UInt64: WasmInteger { typealias Signed = Int64 }
```

現在は `switch` の各 `case` で `i32`/`i64` を個別に実装している。
Pico 上での実測でコードサイズがボトルネックになった場合に検討する。

---

## 13. WasmKit 実装との比較分析

本プロジェクトでは `ThirdParty/WasmKit/` に Swift 製 Wasm Runtime のソースを参照できる。

### WasmKit が Swift のメリットを活かしている点

**Protocol + Generics による算術演算の一元化**

```swift
// Sources/WasmKit/Execution/Value.swift
protocol RawUnsignedInteger: FixedWidthInteger & UnsignedInteger { ... }
extension RawUnsignedInteger {
    func divS(_ other: Self) throws -> Self { ... }
}
```

**struct + Value Semantics の徹底**

`UntypedValue`・全 Instruction Operand が struct で統一されており、本プロジェクトの方針と一致する。

### WasmKit がパフォーマンスのために意図的に活かしていない点

**enum の網羅性チェックをホットパスで放棄**

```swift
// Instruction.swift の冒頭コメント
/// NOTE: This enum representation is just for modeling purposes.
/// The actual runtime representation can be different.
```

実行ループはパフォーマンスのために型安全性を意識的に捨て、整数 opcode の `switch` を使う。

**型付き WasmValue をホットパスで使わない**

```swift
// UntypedValue.swift — i32/i64/f32/f64 を全て UInt64 で保持
struct UntypedValue { let storage: UInt64 }
```

オペコードが型を知っているため、ランタイムに型タグを持たせない最適化。

### 本プロジェクトとの選択比較

| 観点 | WasmKit | 本プロジェクト | 理由 |
|---|---|---|---|
| 命令ディスパッチ | 整数 switch（パフォーマンス優先） | `switch` on enum（学習・安全優先） | 網羅性チェックを活用 |
| 値の表現 | `UntypedValue`（UInt64） | `Value` enum（型安全） | 仕様と 1:1 の表現で理解しやすさを優先 |
| エラー | 通常の `throws` | `throws(WasmError)` | Embedded Swift 推奨パターン |

本プロジェクトが WasmKit より型安全性を優先する理由は、パフォーマンスより「仕組みの理解と誤りの早期発見」が目的だからである。

---

## 14. 組み込み環境における Swift 採用の評価

### Embedded Swift でも有効な利点

Embedded Swift で失われるのはランタイム機能（String・Array 動的確保・Swift Concurrency）のみで、
**コンパイル時の安全機能はすべて維持される**。

- enum 網羅性チェック → デバッグ困難な環境で命令追加漏れをコンパイラが検出
- 整数オーバーフローが未定義動作にならない（`&+` で意図を明示）
- Generics がゼロコスト抽象（モノモーフィズム化）
- `@_silgen_name` による Pico SDK との型安全な連携

### 率直なデメリット

| 観点 | C | Embedded Swift |
|---|---|---|
| フラッシュ使用量 | 最小 | 型メタデータが残りやすく大きくなる傾向 |
| コンパイル速度 | 速い | 遅い |
| デバッグツール | GDB・OpenOCD が成熟 | LLDB 対応は途上 |
| ライブラリ資産 | 膨大 | ほぼゼロ |
| ツールチェーン安定性 | 非常に安定 | 比較的新しい |

Rust `no_std` エコシステムは Embedded Swift より成熟しており（`heapless`・`defmt`・`probe-rs` 等）、
純粋な組み込み効率では `C > Rust no_std > Embedded Swift` の順。

### このプロジェクトで Embedded Swift を選ぶ理由

- **コード共有**: パーサー・バリデーター・インタプリタのコアは macOS でも Pico でも同一ソース
- **Phase 6（iOS 連携）**: BLE 経由で Wasm バイナリを送信する iOS アプリも Swift で実装する。iOS ↔ Pico の両端が Swift になることで、エラー型・プロトコル定義を共有できる可能性がある
- **学習目的**: 「Embedded Swift の理解を深める」はプロジェクト目標の一つ

---

## 15. 関連ドキュメント

| ドキュメント | 内容 |
|---|---|
| `Documentations/PHASE2_WASM3.md` | wasm3 ソースコード調査結果・Swift 転用ポイント |
| `Documentations/PHASE3_PARSER.md` | バイナリパーサーの実装計画 |
| `Documentations/PHASE4_INTERPRETER.md` | インタプリタの実装計画 |
| `Documentations/WASM_SPEC.md` | Wasm 仕様の参照まとめ |
| `Documentations/OVERVIEW.md` | プロジェクト全体方針・インクリメンタル開発方針 |
