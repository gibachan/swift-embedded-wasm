# Embedded Swift 学習ガイド — 通常の Swift との差異と本プロジェクトの実例

本プロジェクト(Raspberry Pi Pico 上で動く WASM Runtime)の実際のコードを教材として、
iOS アプリ開発で使う標準的な Swift と Embedded Swift の違いを学ぶためのドキュメント。

対象読者: Swift には習熟しているが、Embedded Swift・組込み環境は初学者。

関連ドキュメント: 設計判断の全体像は `SWIFT_VM_DESIGN.md`(特に Section 8–10)、
アリーナアロケータの詳細は `ARENA_ALLOCATOR.md` を参照。

---

## 1. Embedded Swift とは何か — なぜ制約があるのか

Embedded Swift は Swift 言語のサブセットで、**ランタイムライブラリと型メタデータを
持たない環境**向けにコンパイルするモードである。iOS アプリの Swift は裏側で

- ヒープアロケータ(malloc)
- Unicode テーブル(String の正規化・比較用)
- プロトコル witness table / 型メタデータ(existential・リフレクション用)
- Foundation / Swift Concurrency ランタイム

に依存しているが、RP2040(RAM 264 KB / Flash 2 MB)のようなマイコンにはこれらを
置く余裕がない。Embedded Swift は「これらに依存する機能を使ったらコンパイルまたは
リンクを失敗させる」ことで、依存ゼロのバイナリを生成する。

重要なのは **失われるのはランタイム機能だけ** という点。enum の網羅性検査、
ジェネリクス、typed throws、整数オーバーフローの検出といった
**コンパイル時の型安全はすべて残る**(`SWIFT_VM_DESIGN.md` Section 14)。

### 本プロジェクトでの有効化方法

`Makefile` の `make compile` ターゲットが Embedded Swift でのコンパイル検証を行う:

```makefile
TARGET := armv7em-none-none-eabi

SWIFTFLAGS := \
  -target $(TARGET) \
  -enable-experimental-feature Embedded \
  -enable-experimental-feature Extern \
  -wmo \
  -Osize
```

- `-target armv7em-none-none-eabi`: OS なし(`none`)の ARM Cortex-M 向け
- `-enable-experimental-feature Embedded`: Embedded Swift モード
- `-wmo`(Whole Module Optimization): ジェネリクスの単相化(monomorphization)に必須
- ソースコード内では `#if hasFeature(Embedded)` で分岐できる

### 「コンパイルは通るがリンクで落ちる」という特有の現象

Embedded Swift の制約違反は **2 段階で発覚する**。ここが初学者の最大のハマりどころ。

```
[コンパイル] .swift → .o   ← Array.append や String == はコンパイルが通る
                              (malloc やUnicodeテーブルへの参照が .o に埋まるだけ)
[リンク]     .o → .elf     ← "undefined reference to '_malloc'" で初めて失敗
```

だからこのプロジェクトはテストを 3 段階に分けている(CLAUDE.md のワークフロー):

1. `swift test` — macOS でロジックの正しさを検証
2. `make compile` — Embedded Swift でコンパイルが通るか検証
3. BLE example の `make build` — **リンクまで**通るか検証(ここで初めて malloc 依存が見つかる)

---

## 2. 使えない機能と代替パターン早見表

| 使えない/避けるもの | 代替 | 本プロジェクトの実例 |
|---|---|---|
| `class`(ヒープ確保) | `struct` + `mutating` | Runtime 全体が struct(`WasmInterpreter`, `WasmModule`) |
| `any Protocol`(existential) | ジェネリック制約 `<T: Protocol>` | `decode<S: ByteStream>` (`LEB128.swift`) |
| `String ==` | バイト列比較 `elementsEqual` | エクスポート名検索 (`WasmInterpreter.swift:1305`) |
| 動的 `String` | `StaticString` / `[UInt8]` | `HostImport` の名前 (`WasmInterpreter.swift:54`) |
| `func f() throws`(untyped) | `throws(ConcreteError)` | `throws(ParserError)`(`ParserError.swift`)/ `throws(InterpreterError)`(`InterpreterError.swift`)|
| 動的 `Array`(malloc 依存) | 固定長タプルバッファ / アリーナ | `LabelStack`, `Fixed4_HostImport`, `WasmArena` |
| クロージャのキャプチャ | `@convention(c)` 関数ポインタ + グローバル | `hostBlink` (`Main.swift:153`) |
| `Foundation`(`Data`, `Date` 等) | `[UInt8]`, `UnsafeBufferPointer`, 整数 | 全域 |
| `Mirror` / リフレクション | enum の関連値・ジェネリクス | `Value` enum |
| `indirect case`(ヒープ確保) | フラットなバイトコード + ジャンプオフセット | Phase 1.5 で撤廃済み |
| Swift Concurrency(actor 等) | シングルスレッド struct 設計 | Runtime 全体 |

以下、各パターンを実例で掘り下げる。

---

## 3. 参照型を使わない — struct + mutating 中心の設計

### 基本方針

`class` はインスタンス生成のたびにヒープ確保と ARC(参照カウント)が発生する。
Embedded ではヒープ自体がない(または極小)ため、**状態は struct に持たせ、
変更は `mutating` メソッド経由で行う**。

```swift
// iOS アプリでよくある形 — Embedded では NG
class WasmInterpreter {
    var valueStack: [Value] = []
    func push(_ v: Value) { valueStack.append(v) }
}

// 本プロジェクトの形
struct WasmInterpreter {
    // 固定長バッファに値を持つ
    mutating func push(_ v: Value) throws(InterpreterError) { ... }
}
```

副産物として **所有権が明確になる**。参照の共有による暗黙の状態変更が構造的に
起こり得ず、`inout` / `mutating` の連鎖がデータフローをそのまま表す。

### 例外: macOS ビルド限定で class を使う正当なケース

`WasmArena.swift:26-42` の `_ArenaStorage` は意図的な例外。

```swift
#if !hasFeature(Embedded)
  /// struct の WasmArena がヒープブロックをコピーせず共有所有するための参照型ラッパー
  private final class _ArenaStorage {
    let ptr: UnsafeMutablePointer<UInt8>
    init(capacity: Int) { ptr = .allocate(capacity: capacity) ... }
    deinit { ptr.deallocate() }  // ← deinit でリソース解放(RAII)
  }
#endif
```

macOS 側では「struct が代入コピーされてもバッファ本体はコピーしない」ために
参照セマンティクスが必要になる。Embedded 側は C の静的配列がバッファなので
class 自体が不要 — `#if !hasFeature(Embedded)` で丸ごと消える。
**「class 禁止」は教条ではなく、ヒープと ARC のコストの問題**だと分かる好例。

---

## 4. existential を使わない — ジェネリクスによる静的ディスパッチ

```swift
// NG: any は witness table を実行時に引く(Embedded にはそのテーブルがない)
func process(_ stream: any ByteStream) { ... }

// OK: コンパイル時に具体型が確定 → 静的ディスパッチ、witness table 不要
func process<S: ByteStream>(_ stream: inout S) { ... }
```

本プロジェクトの実例が `WasmInteger` プロトコル(`WasmModule.swift`)。
i32/i64 の算術は意味論が同一でビット幅だけ違うため、ジェネリクスで統一している:

```swift
protocol WasmInteger: FixedWidthInteger & UnsignedInteger {
    associatedtype Signed: FixedWidthInteger & SignedInteger
    static func fromValue(_ v: Value) throws(InterpreterError) -> Self
    func toValue() -> Value
}
extension UInt32: WasmInteger { typealias Signed = Int32 }
extension UInt64: WasmInteger { typealias Signed = Int64 }
```

`WasmInterpreterEmbedded.swift` の 14 個のヘルパー(`intBinaryOp`, `intDivS`,
`intShl` など)がこのプロトコルを使い、44 個のオペコード処理を共通化している。
`-wmo` により **単相化(monomorphization)されてゼロコスト** — C のマクロ展開と
同等の機械語になるが、型検査つき。

知っておくべき注意点:

- 単相化はコンパイル時に完結する必要がある → モジュール境界を越えるジェネリック
  関数には `@inlinable` が必要(同一モジュール内なら不要 — 本プロジェクトは
  単一モジュールなので付けていない。`SWIFT_VM_DESIGN.md` Section 12.6)
- ホットパスの小関数には `@inline(__always)`(`LabelStack` の全メソッドに付与)

---

## 5. String をほぼ使わない

### なぜ `String ==` がリンクエラーになるのか

Swift の `String` 比較は Unicode 正規化(é を e + ´ と同一視する等)を行い、
その正規化テーブルが Embedded Swift には存在しない。**コンパイルは通り、
リンクで落ちる**典型例。

```swift
// NG: リンクエラー
module.exports.first { $0.name == "increment" }

// OK: バイト列の比較
module.exports.first { $0.nameBytes.elementsEqual("increment".utf8) }
```

### StaticString — コンパイル時定数文字列

`StaticString` はバイナリの読み取り専用領域に置かれる文字列で、ヒープ確保ゼロ。
文字列リテラルをそのまま渡せるので呼び出し側の見た目は普通の Swift と変わらない。

`HostImport`(`WasmInterpreter.swift:52-62`)はインポート名を `StaticString` で持つ:

```swift
enum HostImport {
    case function(StaticString, StaticString, HostFunctionPtr)  // (module, name, body)
    case memory(StaticString, StaticString, UInt32)
}
// 呼び出し側: .function("env", "blink", hostBlink) — リテラルがそのまま入る
```

比較するときは `withUTF8Buffer` で UTF-8 バイト列を取り出す
(`WasmInterpreter.swift:1305`):

```swift
let matches = m.withUTF8Buffer { mBuf in
    n.withUTF8Buffer { fi.module.elementsEqual(mBuf) && fi.name.elementsEqual($0) }
}
```

`callExport` も `StaticString` オーバーロードを持ち、関数名検索がゼロコピーで行える
(`WasmInterpreter.swift:1586`)。

パーサが WASM バイナリから読む名前(実行時に決まる)は `[UInt8]` のまま保持する。
**「コンパイル時に決まる名前は StaticString、実行時に来る名前は [UInt8]」**
という使い分けがこのプロジェクトの一貫したルール。

---

## 6. typed throws — エラー型を関数シグネチャで固定する

通常の `throws` は内部的に `any Error`(existential)を使うため Embedded では避ける。
Swift 6 の typed throws で具体型を指定する:

```swift
// NG
func consume() throws -> UInt8

// OK
func consume() throws(LEB128Error) -> UInt8
```

本プロジェクトではパーサとインタプリタのエラーを別々の enum に分けている
—`ParserError`(`ParserError.swift`、バイナリ形式のデコードエラー)と
`InterpreterError`(`InterpreterError.swift`、実行時トラップ)。case は関連値も
含めすべて値型で、ヒープ確保なしで throw できる:

```swift
// ParserError.swift
enum ParserError: Error, Equatable, Sendable {
    case invalidMagic
    case leb128Error(LEB128Error)
    case typeMismatch            // WasmValidator(macOS 限定)の静的型検査
    ...
}

// InterpreterError.swift
enum InterpreterError: Error, Equatable, Sendable {
    case stackOverflow
    case divisionByZero
    case typeMismatch            // 実行時のスタック型トラップ
    ...
}
```

両者には `unexpectedEnd` / `invalidValueType(UInt8)` / `invalidInstruction(UInt8)` /
`typeMismatch` / `resourceLimitExceeded` の 5 つの case 名があえて重複している。
インタプリタはフラットバイトコード化以降、実行時に `rawBytes` からオペコードを
その場でデコードするため、パーサと同じ「デコード失敗」がパース時とは独立に
実行時にも起こりうる。`typeMismatch` も同様に、`WasmValidator` はパース後の
静的検査として、インタプリタは実行時のスタック型トラップとして、それぞれ別の
タイミングで同じ意味のエラーを投げる。

副次効果として、**どの関数がどのエラーを投げうるかがシグネチャに現れる**ため、
wasm3 の `const char*` によるエラー表現(文字列比較でエラー種別を判定)と比べて
はるかに安全(`SWIFT_VM_DESIGN.md` Section 11 の比較表を参照)。

---

## 7. ヒープを使わないデータ構造 — 固定長タプルバッファ

Embedded Swift で最も特徴的なパターン。`Array<T>` の `append` は malloc に依存する
ため、**上限を決めてタプルをバッキングストアにした固定長バッファ**を自作する。

### 実例 1: LabelStack(`WasmInterpreter.swift:329`)

Wasm の block/loop/if のネストを管理するスタック。Embedded では 8 要素タプル:

```swift
struct LabelStack {
  #if hasFeature(Embedded)
    private var storage: (Label, Label, Label, Label, Label, Label, Label, Label)
    private var _count: Int

    @inline(__always)
    mutating func append(_ label: Label) {
      precondition(_count < WasmLimits.maxLabelDepth, "LabelStack overflow")
      withUnsafeMutableBytes(of: &storage) { buf in
        let ptr = buf.baseAddress!.assumingMemoryBound(to: Label.self)
        ptr[_count] = label
      }
      _count &+= 1
    }
    // subscript も withUnsafeBytes でポインタ経由アクセス
  #else
    // macOS 側は [Label](ヒープ)— 差異は struct 内部に隠蔽され、
    // 呼び出し側に #if は現れない
  #endif
}
```

学べるポイント:

- **タプルは Swift で唯一の「言語組込みの固定長インラインバッファ」**。
  struct のプロパティとして持てばスタック(または包含する struct 内)に置かれる
- タプルに添字アクセスはできないので `withUnsafeMutableBytes` +
  `assumingMemoryBound` でポインタとして触る(要素型が trivial であることが前提)
- 容量超過は `precondition` でトラップ = 「動的に伸ばす」のではなく
  **上限を仕様として決める**のが組込み流
- サイズ選定はスタック消費と直結: 32 → 8 要素に縮めた理由は
  「`EmbeddedFrame` が 540 → 156 バイトになり RP2040 の 4 KB スタックに収まる」
  というコメント(`WasmInterpreter.swift:331-335`)に残っている
- **プラットフォーム差は struct 内部に閉じ込め、呼び出し側の `#if` をゼロにする**
  (`feedback_minimize_if_embedded` の方針)

### 実例 2: Sequence 準拠で使い勝手を保つ(`Fixed4_HostImport`)

`WasmInterpreter.swift:69` の `Fixed4_HostImport` は最大 4 要素の固定バッファだが、
`Sequence` に準拠させることで `[HostImport]` と同じように `for-in` やジェネリック
init に渡せる:

```swift
struct Fixed4_HostImport: Sequence {
    private var e0, e1, e2, e3: HostImport?   // Optional 4 本 = 固定4スロット
    private(set) var count: Int = 0
    mutating func append(_ hi: HostImport) { ... }
    func makeIterator() -> Iterator { ... }
}
// WasmInterpreter.init は <S: Sequence> で受けるので配列でもこれでも動く
```

**固定バッファ化しても API の抽象度は落とさなくてよい**、という好例。

### 実例 3: 生のタプルをそのまま使う(`Main.swift:18`)

BLE 通知用の 64 バイトログバッファは、型さえ要らないので UInt8 の 64 要素タプル:

```swift
var logBuf: (UInt8, UInt8, ..., UInt8) = (0, 0, ..., 0)  // 64 要素
var logBufLen: Int32 = 0

func logAppendByte(_ b: UInt8) {
    guard logBufLen < 64 else { return }  // 満杯なら黙って捨てる
    withUnsafeMutableBytes(of: &logBuf) { ptr in ptr[Int(logBufLen)] = b }
    logBufLen += 1
}
```

### 実例 4: WasmModule の Fixed*_X ファミリー(`WasmModule.swift:597` 以降)

`Fixed64_FunctionType`, `Fixed32_Import`, `Fixed64_UInt32` など、モジュールの各
セクションに上限付き固定バッファを用意している。上限値は `WasmLimits` に集約。
初期化には「絶対に使われない番兵値(sentinel)」で全スロットを埋める必要がある
(タプルは部分初期化できないため)。

⚠️ 注意: 要素型が ARC 管理対象([UInt8] などを含む struct)の場合、バイト
再解釈でコピーすると参照カウントが壊れる。`WasmModule.swift:1044` 付近のコメント
に経緯が記録されている。**タプル+ポインタのトリックは trivial な型に限る**こと。

---

## 8. アリーナアロケータ — 「大きい確保」はどうするか

固定長タプルは数百バイト規模まで。64 KB の Wasm 線形メモリのような大物は
`WasmArena`(`WasmArena.swift`)= bump-pointer アリーナで賄う:

```swift
// 使い方(Embedded 側、Main.swift:43)
var wasmArena = WasmArena()          // C の静的配列 96 KB がバッキングストア

func executeReceivedWasm(...) {
    wasmArena.reset()                // O(1) で全確保を破棄
    let module = try parser.parse()
    var interp = try WasmInterpreter(module: module, arena: &wasmArena, ...)
    try interp.callExport(...)
    // interp はスコープを抜けて破棄 → 次サイクルの reset() が安全になる
}
```

仕組み(`WasmArena.swift:141-156`):

```swift
mutating func allocate(count: Int, alignment: Int = 1)
    -> UnsafeMutableBufferPointer<UInt8>? {
    let aligned = (_used + alignment - 1) & ~(alignment - 1)  // アラインメント切り上げ
    guard aligned + count <= _capacity else { return nil }    // 失敗は nil(throw しない)
    let ptr = _base.advanced(by: aligned)
    _used = aligned + count
    return UnsafeMutableBufferPointer(start: ptr, count: count)
}
mutating func reset() { _used = 0 }   // 解放は「ポインタを巻き戻すだけ」
```

学べるポイント:

- 組込みの定番メモリ戦略: **起動時に静的領域を確保し、実行サイクル単位で
  まとめてリセット**。個別 free がないので断片化も二重解放もない
- ライフタイム規約はコメントで明文化されている(`WasmArena.swift:15-19`):
  アリーナ内ポインタを持つオブジェクトは次の `reset()` より前に破棄すること。
  Swift の借用検査はここまで守ってくれないので、**レキシカルスコープで保証する**
- macOS 側は同じ API のままヒープ 1 回確保にフォールバック(テスト容易性の確保)

詳細は `ARENA_ALLOCATOR.md` を参照。

---

## 9. クロージャが使えない場所 — @convention(c) 関数ポインタ

環境をキャプチャするクロージャはヒープにコンテキストを確保する。Embedded では
ホスト関数(Wasm から呼ばれるネイティブ関数)を **`@convention(c)` 関数ポインタ**
で表す(`WasmInterpreter.swift:32-39`):

```swift
#if hasFeature(Embedded)
  typealias HostFunctionPtr =
    @convention(c) (
      UnsafeRawPointer?,          // args(Value 配列の先頭。enum は C 表現不可なので Raw)
      Int32,                      // argsCount
      UnsafeMutablePointer<UInt8>?, // memory(線形メモリ)
      Int32,                      // memorySize
      UnsafeMutableRawPointer?    // results(結果書き込み先)
    ) -> Void
#else
  typealias HostFunction = ([Value], [UInt8]) -> [Value]  // macOS はクロージャで良い
#endif
```

実装側(`Main.swift:199` の `hostDigitalRead`)はこう書く:

```swift
@_cdecl("hostDigitalRead")
func hostDigitalRead(
  _ args: UnsafeRawPointer?, _ argsCount: Int32,
  _ memory: UnsafeMutablePointer<UInt8>?, _ memorySize: Int32,
  _ results: UnsafeMutableRawPointer?
) {
  guard argsCount >= 1 else { return }
  let args32 = args?.assumingMemoryBound(to: Value.self)  // Raw → Value に読み替え
  guard case .i32(let pin) = args32?[0] else { return }
  gpio_init(UInt32(pin))
  gpio_set_dir(UInt32(pin), false)
  let level = gpio_get(UInt32(pin))
  let results32 = results?.assumingMemoryBound(to: Value.self)
  results32?[0] = .i32(level ? 1 : 0)                     // 結果はポインタ経由で書き戻す
}
```

学べるポイント:

- `@convention(c)` 関数は **何もキャプチャできない**。必要な状態(LED ピン番号など)
  はファイルスコープのグローバル変数に置く(`Main.swift:5` の `ledPin`)。
  「グローバル変数は悪」という iOS の常識は、シングルスレッドの組込みファームでは
  トレードオフが逆転する
- Swift の enum(`Value`)は C の型表現を持たないため、シグネチャは
  `UnsafeRawPointer` にして関数内で `assumingMemoryBound(to:)` で読み替える
- 戻り値も「結果バッファへの書き込み」という C 流の out-parameter になる

---

## 10. C との連携 — ブリッジング属性 3 種

Pico SDK(C ライブラリ)と直接やり取りするための道具。iOS 開発の
「モジュールインポート + 自動ブリッジ」より一段低レベル。

| 属性 | 方向 | 実例 |
|---|---|---|
| `@_cdecl("name")` | Swift → C に公開(C から呼ばせる) | `attWriteCallback`(BTstack のコールバック、`Main.swift:81`) |
| `@_extern(c, "name")` | C → Swift に取り込む(宣言だけ書く) | `wasm_arena_ptr_c`(`WasmArena.swift:81`) |
| BridgingHeader.h | C ヘッダ一括取り込み | Pico SDK の `gpio_put` など(example ターゲットのみ) |

`@_extern(c)` の実例(`WasmArena.swift:81-84`)。ブリッジングヘッダが見えない
`Sources/` 配下から C シンボルを参照する正攻法:

```swift
@_extern(c, "wasm_arena_ptr")
private static func wasm_arena_ptr_c() -> UnsafeMutablePointer<UInt8>?
@_extern(c, "wasm_arena_size")
private static func wasm_arena_size_c() -> UInt32
```

C 構造体をバイト列として渡すときは `withUnsafeMutableBytes`(`Main.swift:53-61`):

```swift
var advData: (UInt8, UInt8, ...) = (2, 0x01, 0x06, 8, 0x09, ...)  // BLE 広告パケット

withUnsafeMutableBytes(of: &advData) { bytes in
    gap_advertisements_set_data(
        UInt8(MemoryLayout.size(ofValue: advData)),
        bytes.baseAddress?.assumingMemoryBound(to: UInt8.self))
}
```

---

## 11. スタックは有限で見える資源 — メモリレイアウトの意識

iOS ではスタックサイズ(メインスレッド 1 MB)を意識することはまずない。
RP2040 の **デフォルトのメインスタックは 4 KB** で、超えると HardFault(即死)する。

本プロジェクトで実際に起きたこと(`SWIFT_VM_DESIGN.md` Section 10):

- インタプリタのネイティブ呼び出し連鎖
  `_runIterativeEmbeddedCore → dispatchEmbedded → pushEmbeddedFrame → ...`
  のピークスタック使用量は約 28 KB — デフォルトの 7 倍
- 対策は 2 本立て:
  1. **各フレームを小さくする** — `WasmModule`(約 18 KB)を値で渡さず
     `UnsafePointer<WasmModule>` で渡す(Phase 5)。struct の値渡しは
     「コピーがスタックに積まれる」ことを意味する、という当たり前だが
     iOS 開発では意識しない事実がここで効いてくる
  2. **総量を増やす** — カスタムリンカスクリプト `memmap_wasm.ld` で
     スタックを RAM 末尾 64 KB に移動(`PICO_STACK_SIZE=65536`)

`LabelStack` を 32 → 8 要素に縮めた話(Section 7)もこの文脈。
**「struct のサイズ」=「スタック消費」=「有限のハード資源」** という等式が
Embedded Swift プログラミングの基底にある。

また `print` は存在しない(または UART 行き)。デバッグ出力は UART 書き込み関数を
自作する(`Main.swift` の `writeByte`)。

---

## 12. ホットパスのイディオム — 割り当てゼロを保つ

インタプリタループのような毎命令実行されるコードでは、一時 Array の生成が
そのままヒープ圧(macOS)や リンク不能(bare-metal)につながる。

```swift
// NG: br/return のたびにヒープ確保
let results = Array(valueStack.suffix(arity))
valueStack.removeSubrange(base...)
valueStack.append(contentsOf: results)

// OK: in-place スライド、確保ゼロ
let src = valueStack.count - arity
for i in 0..<arity { valueStack[base + i] = valueStack[src + i] }
valueStack.removeSubrange((base + arity)...)
```

その他の定番:

- **computed property をホットパスで参照しない** — `importedFunctionCount` は
  init で 1 回計算して `let` に格納(`WasmModule`)
- **`&<<` / `&+` オーバーフロー演算子** — 通常の `<<` は符号付きオーバーフローで
  トラップする。LEB128 デコードのようなビット操作は `&<<` で「ビットパターンを
  そのまま扱う」意図を表明する(`LEB128.swift`)
- `@inline(__always)` をループ内の小関数に付ける(`LabelStack`、`intBinaryOp` 群)

---

## 13. 検証コードの分離 — #if !hasFeature(Embedded)

バリデーション(WASM モジュールの事前検証)は開発時にだけ価値が高く、
Flash 容量を食う。本プロジェクトは **macOS ビルドでのみフル検証、Embedded では
スキップ**という割り切りをしている:

```swift
#if !hasFeature(Embedded)
    try WasmValidator.validate(module)
#endif
```

これが成立するのは「macOS で `swift test` に通った Wasm しか Pico に送らない」
という開発フローが前提。**同一ソースを 2 つのターゲットでビルドする構成**
(macOS = 開発・検証環境、Embedded = 本番)自体が Embedded Swift の実践的な
開発パターンであり、`#if hasFeature(Embedded)` はその接合点となる。

ただし本プロジェクトでは **`#if` の数を最小化する方針**を取っている:

- 差異は型の内部に封じ、呼び出し側には露出させない(`LabelStack` 方式)
- 1 KB 未満の固定バッファは両プラットフォームでタプル実装に統一し `#if` 自体を消す
- `#if` が正当化されるのは「片側にしか存在しない型」を扱うときだけ
  (例: `WasmArena` の C 関数ポインタ vs class ストレージ)

---

## 14. まとめ — 学習チェックリスト

Embedded Swift のコードを書く・読むときの自問リスト:

1. **この式はヒープ確保するか?** — class 生成、`Array.append`、`indirect case`、
   キャプチャするクロージャ、文字列補間はすべてヒープ行き
2. **この struct は何バイトで、どこに置かれるか?** — 値渡し = スタックへのコピー。
   大きい struct は `UnsafePointer` で渡す
3. **この String 操作はリンクできるか?** — `==`、辞書のキー、補間は Unicode
   テーブル依存。`StaticString` / `[UInt8]` / `elementsEqual` で代替
4. **エラー型は具体か?** — `throws` ではなく `throws(ParserError)` / `throws(InterpreterError)`
5. **プロトコルは値として持っていないか?** — `any P` はジェネリクスに書き換える
6. **上限は決めたか?** — 動的に伸びる構造は使えない。上限 + `precondition` +
   番兵値が固定バッファの三点セット
7. **`make compile` だけでなくリンクまで通したか?** — malloc 依存はリンクまで
   分からない
8. **`#if hasFeature(Embedded)` は型の内部に閉じているか?** — 呼び出し側に
   分岐を漏らさない

このプロジェクトのコードを読む順番としては、
`ParserError.swift` / `InterpreterError.swift`(typed throws)→ `LEB128.swift`(ジェネリック ByteStream と `&<<`)→
`WasmArena.swift`(アリーナと `#if` の正当な使い方)→ `WasmInterpreter.swift` の
`LabelStack` / `Fixed4_HostImport`(固定バッファ)→ `Examples/.../Main.swift`
(C 連携とホスト関数)の順が、小さい題材から段階的に学べる。
