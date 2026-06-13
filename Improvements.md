# Improvements for Embedded Swift Migration

このドキュメントは、現在の macOS フェーズ実装を Embedded Swift（Raspberry Pi Pico）へ
移行する際に対処すべき改善点をまとめたものです。
優先度順（malloc 排除前提 → ランタイムヒープ → ホットパス → 設計）に並べています。

> **注意:** 現在の `make build`（`pico-ble` ターゲット）は `pico_stdlib` が `malloc` / `free` を提供するため
> 正常にリンクされます。優先度 A の項目は「`pico_stdlib` を除去した純粋な bare-metal 環境」、
> または「Phase 4 の方針（malloc 完全排除）を適用した場合」に初めてリンクエラーとなる
> **将来の移行ブロッカー**です。

---

## 優先度 A — malloc 排除時のリンクエラー（Phase 4 移行のブロッカー）

現状の `pico-ble` ビルドは `pico_stdlib` が `malloc` を提供するため成功する。
しかし TODO.md Phase 4 の方針では「`pico_stdlib` が提供していても malloc は使用しない」とされており、
その方針を適用した場合（または純 bare-metal ターゲットへ移行した場合）に
以下の項目がリンクエラーになる。

### A-1. `brTable` の `[UInt32]` associated value を除去する

**場所:** `WasmModule.swift` L119、`WasmParser.swift`、`WasmInterpreter.swift`

```swift
// 現状: enum の associated value に Array を持つ → malloc が必要（pico_stdlib があれば現状リンクは通る）
case brTable([UInt32], UInt32)  // 0x0E: target_labels[], default_label

// 改善案: フラットバイトコードに inline する（TODO.md Phase 2.5 に記載済み）
case brTable(count: UInt32, default_: UInt32)  // count 個の brTableEntry が後続
case brTableEntry(UInt32)                       // ターゲット深さ
```

`[UInt32]` を enum の associated value に持つと、Embedded Swift は `.o` 生成は通過するが
malloc なし環境ではリンク時に `_malloc` への未解決参照でエラーになる。
フラットバイトコードとして後続命令に埋め込むことで完全に回避できる。

---

## 優先度 B — ランタイムヒープ割り当て（純 Bare-Metal では動作しない）

### B-1. `Frame.locals: [Value]` を固定サイズバッファに変える

**場所:** `WasmInterpreter.swift` L87、L312（`// TODO: Embedded Phase 5` コメント付き）

```swift
// 現状: Wasm 関数呼び出しごとにヒープ割り当て
var locals: [Value] = Array(valueStack[argsStart...])

// 改善案: 固定長バッファ（例: 最大 128 locals）
// TODO: Embedded Phase 5 — UnsafeMutableBufferPointer への置換
```

Wasm 関数呼び出しのたびに `locals` 配列が `malloc` される。
呼び出し頻度が高い場合（ループ内での再帰など）はヒープ圧力の主要因になる。

---

### B-2. `valueStack: [Value]`、`frames: [Frame]` を固定サイズに変える

**場所:** `WasmInterpreter.swift` L279-281

```swift
// 現状: 上限なし動的配列
var valueStack: [Value] = []
var frames: [Frame] = []

// 改善案: スタック固定化（例: valueStack 最大 256 要素、フレーム最大 64 段）
// WasmError.stackOverflow を追加してオーバーフロー時にトラップ
```

TODO.md の Phase 3・4 に詳細が記載されている。
RP2350 では SRAM が 520 KB であり、各 `Value` が 16 バイト前後と仮定すると
valueStack 256 要素で約 4 KB、frames 64 段でおよそ 8 KB 程度に収まる見込み。

---

### B-3. `Frame.labels: [Label]` を固定サイズバッファに変える

**場所:** `WasmInterpreter.swift` L87

```swift
// 現状: ネストしたブロックごとに動的追加
var labels: [Label]

// 改善案: 固定長（例: 最大ネスト深さ 32）
// var labels: (Label?, Label?, ...) または UnsafeBufferPointer ベース
```

フラットバイトコードへの移行後も `Label` はフレームあたりに残る。
Wasm の実際のネスト深さは典型的に 10 段未満なので、
固定長 32 程度で十分カバーできる。

---

### B-4. `tables: [[Value]]` をフラット固定バッファに変える

**場所:** `WasmInterpreter.swift` L125

```swift
// 現状: ネストした動的配列
private var tables: [[Value]]

// 改善案: テーブル最大数・エントリ数上限を WasmLimits で制約
// [[Value]] → flat [Value] + テーブルごとの offset / count 管理
```

`[[Value]]` はネストした `malloc` が必要。
テーブルは MVP では 1 つだけなので、フラット化が容易。

---

### B-5. `WasmModule` の全フィールドを固定長バッファに変える `WasmModule` の全フィールドを固定長バッファに変える

**場所:** `WasmModule.swift` L423-438 (旧 B-6)

```swift
// 現状: 全フィールドが動的配列
let types: [FunctionType]
let imports: [Import]
let functions: [UInt32]
// ...

// 改善案: WasmLimits 制約下の固定長バッファ（TODO.md Phase 2 に記載済み）
// WasmLimits.maxTypes = 64 ならタプルや固定長 UnsafeBufferPointer を使用
```

パーサーが `WasmModule` を構築する時点で大量の `malloc` が走る。
`WasmLimits` 定数を定義し、アリーナアロケータで一括確保する設計に変えることで
断片化を抑えつつ全フィールドを静的サイズに収められる。

---

## 優先度 C — ホットパスの改善（CPU サイクル節約）

### C-1. `block` / `loop` / `if` のアリティをパース時に事前計算する

**場所:** `WasmInterpreter.swift` L94-113、L447-480

```swift
// 現状: 命令実行のたびに blockArity() / loopBrArity() を呼び module.types を参照
case .block(let bt, let endPc):
    let brArity = blockArity(bt, types: module.types)    // 毎回計算
    let paramCount = loopBrArity(bt, types: module.types) // 毎回計算

// 改善案: パーサーが事前計算した値をそのまま埋め込む（TODO.md Phase 2.5 に記載済み）
case block(brArity: Int, paramCount: Int, endPc: Int)
case loop(brArity: Int, startPc: Int)
case ifElse(brArity: Int, paramCount: Int, elsePc: Int, endPc: Int)
```

`typeIndex` 参照を持つ `BlockType.typeIndex` の場合は `module.types` へのランダムアクセスが発生する。
事前計算でホットパスからの間接メモリアクセスを完全に排除でき、
`blockArity` / `loopBrArity` ヘルパー関数自体も不要になる。

---

## 優先度 D — 32-bit ターゲット安全性

### D-1. 有効アドレス計算のオーバーフローを `UInt64` 経由にする

**場所:** `WasmInterpreter.swift` L1595〜（全 load/store 命令、約 25 箇所）

```swift
// 現状: macOS (64-bit) では問題ないが、Pico (32-bit) では addr + offset が UInt32 を超える可能性
let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)

// 改善案（TODO.md Phase 3 に記載済み）
let ea64 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset)
guard ea64 + UInt64(accessSize) <= UInt64(memory.count) else {
    throw WasmError.memoryAccessOutOfBounds
}
let ea = Int(ea64)
```

Pico では `Int` が 32-bit。`addr + offset` が `0x1_0000_0000` 近傍になると
32-bit `Int` でオーバーフローしてしまい、誤ったアドレスに誤アクセスする可能性がある。

---

## 優先度 E — バイナリサイズ削減

### E-1. LTO（リンク時最適化）— Pico SDK と非互換のため保留

**場所:** `Examples/RaspberryPiPicoW-BLE/Embedded/CMakeLists.txt`

`set_property(TARGET pico-ble PROPERTY INTERPROCEDURAL_OPTIMIZATION TRUE)` を試みたが、
Pico SDK が使用する多数の `--wrap` フラグ（`__wrap_printf`, `__wrap_puts`, `__wrap_malloc` 等）と
GCC LTO (`-flto=auto`) が根本的に非互換であることが判明。
LTO の最適化パス中にリンカーが `__wrap_*` シンボルの ARM/Thumb 呼び出し規約を解決できず
"Unknown destination type" / "dangerous relocation" リンクエラーになる。

Swift レベルの dead code elimination は `CMAKE_Swift_COMPILATION_MODE wholemodule` で既にカバーされており、
C 境界をまたぐ LTO は現行の Pico SDK ビルド構成では使用不可。

**対応:** Phase 4 で bare-metal 環境（`pico_stdlib` 除去）に移行する際に、
`--wrap` の必要性と LTO の併用可否を改めて評価する。

---

### E-2. `Instruction` enum に `@frozen` を付与する

**場所:** `WasmModule.swift` L108

```swift
// 現状
enum Instruction: Sendable { ... }

// 改善案
@frozen
enum Instruction: Sendable { ... }
```

`@frozen` により、コンパイラが enum のケース数を確定できて
`switch` の最適化やインライン展開が促進される。
Embedded Swift では型メタデータの削減にも繋がる。

---

## 優先度 F — コード品質

### F-1. i32/i64 の算術・比較命令を `WasmInteger` プロトコルで統一する

**場所:** `WasmInterpreter.swift`（i32/i64 各命令の実装、約 80 ケース）

SWIFT_VM_DESIGN.md Section 9・12.6 および `TODO.md Phase 2.5` に記載済み。

```swift
// 設計提案（SWIFT_VM_DESIGN.md より）
protocol WasmInteger: FixedWidthInteger & UnsignedInteger {
    associatedtype Signed: FixedWidthInteger & SignedInteger
    init(bitPattern: Signed)
}
extension UInt32: WasmInteger { typealias Signed = Int32 }
extension UInt64: WasmInteger { typealias Signed = Int64 }
```

`@inlinable` を付与することで Embedded Swift のモノモーフィズムと両立する。
i32/i64 で対称な 40+ ケースが半分に減り、将来的な命令追加コストも下がる。

---

## 改善の優先ロードマップ

| フェーズ | 項目 | 理由 |
|--------|------|------|
| **Phase 2.5** (macOS フェーズ完了前) | A-1, C-1, F-1 | `make build` 前に対処、コード削減 |
| **Phase 3** (Embedded 移行) | D-1, B-1, B-2, B-3 | 32-bit 安全性とスタック固定化 |
| **Phase 4** (Pico 実動作) | B-4, B-5 | malloc 完全排除 |
| **最適化** | E-2 | switch 最適化・性能向上（E-1は--wrap非互換のため保留） |

---

## 参照

- `Documentations/SWIFT_VM_DESIGN.md` — Section 8–10: Embedded 制約とパターン
- `Documentations/TODO.md` — Phase 2.5, 3, 4 の詳細タスク
- `ThirdParty/wasm3/source/m3_exec.c` — wasm3 の lazy-decode 実行ループ（参考実装）
