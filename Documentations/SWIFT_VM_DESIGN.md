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

### フェーズ 1.5: Flat Bytecode への移行（Phase 5 前に必須）

現在の実装では `block` / `loop` / `if` 命令が子命令を入れ子の配列として保持している。

```swift
indirect case block(BlockType, [Instruction])   // ← ヒープ確保（malloc 必要）
indirect case loop(BlockType, [Instruction])
indirect case ifElse(BlockType, thenBody: [Instruction], elseBody: [Instruction])
```

`indirect case` は Embedded Swift でも**コンパイルは通るがリンク時に `malloc` が要求される**。
`malloc` のない純粋ベアメタル環境では動作しないため、Phase 5 移行前に対処が必要。

**解決策: Flat Bytecode + ジャンプオフセット**

子命令の入れ子を廃止し、全命令をフラットな配列に並べ、
block/loop/if にはジャンプ先の PC を直接持たせる。
パース時（またはインスタンス化時）にオフセットを計算して埋め込む。

```swift
// Before: 入れ子ツリー（indirect case = ヒープ）
indirect case block(BlockType, [Instruction])

// After: フラット + オフセット（ヒープ不要）
case block(BlockType, endPc: Int)       // endPc: block 出口の命令インデックス
case loop(BlockType, startPc: Int)      // startPc: br 0 で戻る先（通常 loop 自身の次）
case ifElse(BlockType, elsePc: Int, endPc: Int)  // elsePc: else の先頭、endPc: end の先頭
```

この設計の利点:
- `indirect case` がなくなり、malloc 不要になる
- 命令フェッチが `instructions[ip]` の単純アクセスになる（現在の多段ネスト解消）
- `br` / `br_if` のジャンプがオフセットの代入一発で完了する
- CPython bytecode や JavaScriptCore が実際に採用している方式であり、学習価値も高い

変更範囲: Parser（`WasmParser.swift`）でオフセットを計算しながらパースする処理、
および Interpreter（`WasmInterpreter.swift`）のスコープスタック管理が不要になる。

### フェーズ 2: さらなる最適化（必要になった時点で）

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

## 9. Swift の強みを活かした設計ポイント

本ドキュメントの各設計は、C（Wasm3）や Rust（wasmi）との比較で際立つ Swift の強みを意識して構成されている。
以下に「どの強みが」「どの設計決定に」対応しているかを整理する。

### 9.1 enum の網羅性チェックによる仕様との 1:1 対応

Wasm の値型・命令セット・エラー種別は仕様で明確に定義されている。
Swift の `enum` はこれらを**仕様と 1:1 で対応するコード**として表現できる。

C の `union + u8 type` では型の取り違えがコンパイルを通ってしまうが、
Swift では `switch` の網羅性チェックが効くため、**命令セットを追加した際の未処理ケースをコンパイラが検出する**。

対応する設計:
- `WasmValue`（Section 3.1）— 値型の union を型安全な enum に
- `WasmType`（Section 3.2）— 型コードを raw value 付き enum に
- Opcode ディスパッチ（Section 5）— `default: throw unknownOpcode` で未実装命令を確実に捕捉

### 9.2 Typed Throws によるトラップの構造化

Wasm3 は `M3Result = const char*` でエラーを返す。
エラー種別の判定は文字列比較となり、呼び出し側がどのエラーを受け取りうるかはドキュメントを読まなければわからない。

Swift の `throws(WasmTrap)` はエラー種別をシグネチャに記述することで、
**どのエラーが起きうるかが関数のシグネチャ自体から読み取れる**。

対応する設計:
- `WasmFormatError / WasmTrap`（Section 3.4）— パース時エラーと実行時トラップを型で分離
- `step() throws` のシグネチャ（Section 5）— トラップが伝播する経路をコンパイラが追跡

### 9.3 Value Semantics による実行状態の明確化

インタプリタは本質的に状態機械（実行スタック・PC・ローカル変数）である。
`struct` + `mutating` で設計することで：

- 状態の変更は明示的な `mutating` 呼び出しを通じてのみ起きる
- 参照の共有による暗黙的な状態変化が**構造的に**起きない
- 実行コンテキストのスナップショットが自然に書ける（ステップ実行・テストに有用）

対応する設計:
- Interpreter Loop の `struct` 設計（Section 5）
- `LinearMemory` の `struct` 設計（Section 6）— `load` は純粋な読み取り、変更は `mutating` のみ

### 9.4 Embedded Swift の制約がアーキテクチャを改善させる

`class` 禁止・動的確保制限という制約は、**意図せず良い設計を促す**副作用を持つ。

- ヒープ確保を避けるため固定サイズバッファを選ぶ → メモリ使用量の予測可能性が上がる
- 参照の共有がないため所有関係が明確になる → 「誰がこのバッファを解放するか」問題が起きにくい
- クロージャのヒープキャプチャが制限される → Host Function は自然に静的テーブル設計へ向かう

対応する設計:
- `LinearMemory` の固定バッファ設計（Section 6）— Pico では `staticSize` で静的確保
- `HostFunctionTable` の静的テーブル設計（Section 7）— クロージャよりテーブルルックアップを優先

### 9.5 デバッグビルドの安全性がデバッグコストを下げる

Swift はデバッグビルドで整数オーバーフロー・配列境界外アクセスをランタイムトラップする。
C ではこれらは未定義動作として silently 壊れる可能性がある。

UART ログのみのデバッグ環境（Pico）では、**問題発生箇所が明確なトラップは大きな価値**を持つ。
macOS ビルドでフルバリデーションを有効にすることで、Pico 実機デバッグの前に問題を除去できる。

対応する設計:
- バリデーションの 2 段構え（Section 4）— macOS でフルチェック → Pico で構造チェックのみ
- `outOfBoundsMemoryAccess` トラップ（Section 3.4・6）— `UnsafeBufferPointer` の境界チェックを明示的に実装

### 9.6 Protocol + Generics による算術演算の一元化（WasmKit から採用）

Wasm の整数演算（`i32`/`i64`）は同一の意味論を持ちながら bit-width だけが異なる。
C ではマクロや型別関数のコピーで対応するところを、Swift の Protocol + Generics で一元化できる。
WasmKit の `RawUnsignedInteger` プロトコル設計（`Sources/WasmKit/Execution/Value.swift`）を参考に採用する。

```swift
protocol WasmInteger: FixedWidthInteger & UnsignedInteger {
    associatedtype Signed: FixedWidthInteger & SignedInteger
    init(bitPattern: Signed)
}

extension WasmInteger {
    func wasmAdd(_ other: Self) -> Self { self &+ other }
    func wasmSub(_ other: Self) -> Self { self &- other }
    func wasmMul(_ other: Self) -> Self { self &* other }
    func wasmDivS(_ other: Self) throws(WasmTrap) -> Self {
        guard other != 0 else { throw WasmTrap.integerDivisionByZero }
        let (result, overflow) = Signed(bitPattern: self).dividedReportingOverflow(by: Signed(bitPattern: other))
        guard !overflow else { throw WasmTrap.integerOverflow }
        return Self(bitPattern: result)
    }
    func wasmShl(_ other: Self) -> Self { self << (other % Self(Self.bitWidth)) }
    func wasmRotl(_ other: Self) -> Self {
        let shift = other % Self(Self.bitWidth)
        return self << shift | self >> (Self(Self.bitWidth) - shift)
    }
    func wasmEq(_ other: Self) -> UInt32  { self == other ? 1 : 0 }
    func wasmLtS(_ other: Self) -> UInt32 { Signed(bitPattern: self) < Signed(bitPattern: other) ? 1 : 0 }
    func wasmLtU(_ other: Self) -> UInt32 { self < other ? 1 : 0 }
    // ... shr_s, shr_u, rotr, ne, gt_s, gt_u, le_s, le_u, ge_s, ge_u, eqz も同様
}

extension UInt32: WasmInteger { typealias Signed = Int32 }
extension UInt64: WasmInteger { typealias Signed = Int64 }
```

採用する範囲:
- 整数演算: `add`, `sub`, `mul`, `div_s`, `div_u`, `rem_s`, `rem_u`
- ビット操作: `and`, `or`, `xor`, `shl`, `shr_s`, `shr_u`, `rotl`, `rotr`, `clz`, `ctz`, `popcnt`
- 比較演算: `eq`, `ne`, `lt_s`, `lt_u`, `gt_s`, `gt_u`, `le_s`, `le_u`, `ge_s`, `ge_u`, `eqz`

採用しない範囲（型の対称性がないため Generic 化が難しい）:
- 浮動小数点演算（`f32`/`f64`）は `Float32`/`Float64` の `extension` で個別実装
- 型変換命令（`i32.wrap_i64`, `i64.trunc_f32_s` など）は型の組み合わせが多様なため個別実装

対応する設計:
- `WasmValue`（Section 3.1）の演算実装を `WasmInteger` protocol の extension として整理する

---

## 10. WasmKit 実装との比較分析

本プロジェクトでは `ThirdParty/WasmKit/` に Swift 製 Wasm Runtime（WasmKit）のソースを参照できる。
WasmKit の設計から Swift メリットの活用状況を分析し、本プロジェクトへの示唆を整理した。

### 10.1 WasmKit が Swift のメリットを活かしている点

**Protocol + Generics による算術演算の一元化**

```swift
// Sources/WasmKit/Execution/Value.swift
protocol RawUnsignedInteger: FixedWidthInteger & UnsignedInteger {
    associatedtype Signed: RawSignedInteger
}
extension RawUnsignedInteger {
    func divS(_ other: Self) throws -> Self { ... }
    func rotl(_ other: Self) -> Self { ... }
}
```

`UInt32`/`UInt64` に同一の演算を一元定義。C では型別にコピーが必要なところを Generic で解決。
→ 本プロジェクトでも Section 9.6 の方針で採用する。

**struct + Value Semantics の徹底**

`UntypedValue`・`Trap`・全 Instruction Operand が struct で統一されており、本プロジェクトの方針（Section 9.3）と一致する。`Execution` も `mutating` 関数を持つ struct として設計されている。

**Typed Throws の部分活用**

パーサー層で `throws(WasmParserError)` が使われており、エラー種別をシグネチャで表現している。

### 10.2 パフォーマンスのために意図的に活かしていない点

**enum の網羅性チェックをホットパスで放棄**

```swift
// Instruction.swift の冒頭コメント
/// NOTE: This enum representation is just for modeling purposes.
/// The actual runtime representation can be different.
enum Instruction: Equatable { ... }

// DispatchInstruction.swift — 整数 opcode の switch（網羅性チェック不可）
switch opcode {
case 52: return self.execute_i32Add(...)
default: preconditionFailure("Unknown instruction!?")  // ← コンパイラは検出できない
}
```

`Instruction` enum はモデリング用途のみ。実行ループはパフォーマンスのために型安全性を意識的に捨てている。

**型付き WasmValue をホットパスで使わない**

```swift
// UntypedValue.swift — i32/i64/f32/f64 を全て UInt64 で保持
struct UntypedValue {
    let storage: UInt64
}
```

オペコードが型を知っているため、ランタイムに型タグを持たせない最適化。型安全な `Value enum` は公開 API のみに使用している。

**通常の throws を使用**

`Trap` は `throws(Trap)` ではなく通常の `throws` で伝播する。後方互換性・シンプルさ優先の判断と思われる。

### 10.3 本プロジェクトとの選択比較

| 観点 | WasmKit | 本プロジェクト | 理由 |
|---|---|---|---|
| 命令ディスパッチ | 整数 switch（パフォーマンス優先） | `switch` on enum（学習・安全優先） | 網羅性チェックを学習段階で活用 |
| 値の表現 | `UntypedValue`（UInt64） | `WasmValue` enum（型安全） | 仕様と 1:1 の表現で理解しやすさを優先 |
| エラー | 通常の `throws` | `throws(WasmTrap)` | Embedded Swift 推奨パターン |
| Generics | 積極的に活用 | 採用（Section 9.6） | WasmKit から参考に採用 |

本プロジェクトが WasmKit より型安全性を優先する理由は、**パフォーマンスより「仕組みの理解と誤りの早期発見」**が目的だからである。
Pico 上での実測でボトルネックが判明した段階で、`UntypedValue` 方式への最適化を検討する。

---

## 11. 組み込み環境における Swift 採用の評価

Embedded Swift で Wasm Runtime を実装することの利点・限界を正直に整理する。
純粋な組み込み効率の観点では C や Rust no_std に劣る面があるが、
このプロジェクトで Swift を選ぶ理由は別にある。

### 11.1 Embedded Swift でも有効な利点

Embedded Swift で失われるのはランタイム機能（String・Array 動的確保・Swift Concurrency）のみであり、
**コンパイル時の安全機能はすべて維持される**。

**enum 網羅性チェックがデバッグ困難な環境で特に光る**

組み込みは最もデバッグが難しい環境（UART ログのみ・GDB 接続も限定的）。
命令セットの追加漏れをコンパイラが検出することは、実機デバッグの前にバグを除去できることを意味する。

```swift
// 命令追加時の漏れをコンパイラが検出 — C では実行時に壊れるまで気づかない
switch opcode {
case .i32Add: ...
case .i32Sub: ...
// ← 新命令を足し忘れるとコンパイルエラー
}
```

**整数オーバーフローが未定義動作にならない**

C の符号付き整数オーバーフローは未定義動作であり、最適化によって予測不能な結果になる。
Swift ではデバッグビルドでトラップ、リリースビルドでは `&+` で意図を明示する。

```swift
let result = a &+ b  // Wasm の wrapping add であることがコードに現れる
let result = a + b   // デバッグビルドでオーバーフロー時にトラップ → バグが即座に発覚
```

**Generics がゼロコスト抽象**

`WasmInteger` プロトコルは実行時にモノモーフィズム化される。
C の `#define` マクロと同等の機械語が生成されるため、仮想関数テーブルのオーバーヘッドがない。

**`@convention(c)` による Pico SDK との型安全な連携**

```swift
@_silgen_name("gpio_put")
func gpioPut(_ gpio: UInt32, _ value: Bool)

gpioPut(25, true)  // 型チェック付きで C 関数を呼べる
```

C ヘッダーの手書きブリッジなしに、型安全なインターフェースが成立する。

### 11.2 率直なデメリット

**C との比較**

| 観点 | C | Embedded Swift |
|---|---|---|
| フラッシュ使用量 | 最小 | 型メタデータが残りやすく大きくなる傾向 |
| コンパイル速度 | 速い | 遅い |
| デバッグツール | GDB・OpenOCD が成熟 | LLDB 対応は途上 |
| ライブラリ資産 | 膨大 | ほぼゼロ |
| ツールチェーン安定性 | 非常に安定 | Embedded Swift は比較的新しい |

**Rust（no_std）との比較**

Rust の `no_std` エコシステムは Embedded Swift より成熟している:

- `heapless` — 固定サイズコレクション（`Vec` / `HashMap` 相当）が揃っている
- `defmt` — 組み込み向け高速ロギングフレームワーク
- `probe-rs` — フラッシュ書き込み・デバッグが成熟
- `Embassy` / `RTIC` — 組み込み向け非同期フレームワーク

Embedded Swift にはこれらに相当するものがほぼ存在しない。

**組み込み効率の正直な評価**

```
組み込み効率:    C > Rust no_std > Embedded Swift
型安全性:        Rust ≈ Embedded Swift >> C
エコシステム成熟度: C >> Rust no_std >> Embedded Swift（大差）
```

### 11.3 このプロジェクトで Embedded Swift を選ぶ本当の理由

純粋な組み込み効率を最大化するなら C または Rust no_std が現時点では適切な選択である。
それでも本プロジェクトで Embedded Swift を採用する理由は以下の通り。

**macOS フェーズとコードを共有できる**

パーサー・バリデーター・インタプリタのコアは macOS でも Pico でも同一ソースとなる。
macOS フェーズで豊富なデバッグ環境（テスト・型検査・バリデーション）を使い込んでから Pico に移行できる。
`#if MACOS` による 2 段構えはこの戦略の実装手段（Section 4 参照）。

**Phase 6（iOS 連携）で Swift が主役になる**

BLE 経由で Wasm バイナリを送信する iOS アプリは Swift で実装する。
iOS ↔ Pico の両端が Swift になることで、エラー型・プロトコル定義を共有できる可能性がある。
これは C/Rust では自然に得られない利点。

**Embedded Swift 自体の学習が目的の一つ**

CLAUDE.md にある通り「Embedded Swift の理解を深める」はプロジェクト目標の一つ。
最適なツールを選ぶことよりも、Swift が組み込み制約下でどう振る舞うかを理解することに価値がある。

---

## 12. 関連ドキュメント

| ドキュメント | 内容 |
|---|---|
| `docs/PHASE2_WASM3.md` | wasm3 ソースコード調査結果・Swift 転用ポイント |
| `docs/PHASE3_PARSER.md` | バイナリパーサーの実装計画 |
| `docs/PHASE4_INTERPRETER.md` | インタプリタの実装計画 |
| `docs/WASM_SPEC.md` | Wasm 仕様の参照まとめ |
| `docs/OVERVIEW.md` | プロジェクト全体方針・インクリメンタル開発方針 |
