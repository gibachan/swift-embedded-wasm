# Phase 4 — Wasm インタプリタ実装

## 目的

Phase 3 で実装したパーサーと組み合わせ、Wasm モジュールを実際に実行できるインタプリタを構築する。
Stack Machine・Validation・Linear Memory・Host Function を段階的に実装する。

---

## Wasm 仕様について

スタックマシンの仕組み・値型・トラップ・対象バージョン・命令セットの詳細は `Documentations/WASM_SPEC.md` を参照。

実装上の要点のみ以下に抜粋する。

- 対象: **WebAssembly 1.0 MVP**、初期は `i32` 命令サブセットのみ
- Wasm はレジスタを持たないスタックマシン。命令はスタックを介して値をやり取りする
- 実行時コンポーネント: Value Stack / Call Stack / Call Frame（詳細は `Documentations/WASM_SPEC.md`）

---

## Step 1: Minimal Interpreter（Stack Machine）

### 初期対応命令

| 命令 | 動作 |
|------|------|
| `i32.const n` | 定数 n をスタックに積む |
| `local.get i` | ローカル変数 i をスタックに積む |
| `local.set i` | スタックトップをローカル変数 i に格納 |
| `i32.add` | スタックから 2 値を取り出し加算して積む |
| `i32.sub` | スタックから 2 値を取り出し減算して積む |
| `call n` | 関数 n を呼び出す |
| `return` | 現在の関数から戻る |
| `end` | ブロック・関数の終端 |

### 実装構造

```swift
struct ValueStack {
    // 実行時のオペランドスタック
}

struct CallFrame {
    var functionIndex: UInt32
    var locals: [WasmValue]
    var returnAddress: Int  // バイトコード上の戻り先
}

enum WasmValue {
    case i32(Int32)
    case i64(Int64)
    case f32(Float)
    case f64(Double)
}
```

---

## Step 2: Validation（型検証）

### Wasm Validation とは

Wasm は実行前に**静的な型検証**を行う仕様になっている。
検証に通ったモジュールは、実行時に型エラーが起きないことが保証される。

検証内容：
- 関数シグネチャの整合性チェック
- スタックの型が命令の期待する型と一致するか
- ジャンプ先が有効な範囲か

```swift
enum ValueType {
    case i32
    case i64
    case f32
    case f64
}
```

組み込み向けでは、Validation を省略して実行速度を優先する選択肢もある。
本プロジェクトでは「学習」を目的とするため、まず実装して理解する。

---

## Step 3: Linear Memory

### Linear Memory とは

Wasm は **線形メモリ**（Linear Memory）と呼ばれる連続したバイト配列を持つ。
ホスト（Swift 側）から見れば単なるバッファだが、Wasm から見れば唯一アクセスできるメモリ空間。

```text
offset: 0    100   200   ...   65536 (64KB = 1 Page)
        [データ][スタック][ヒープ...]
```

**境界チェック**: メモリアクセスは必ず範囲内かを検証し、範囲外ならトラップ（実行中断）する。

```swift
struct LinearMemory {
    private var buffer: [UInt8]
    let pageSize = 65536  // 64KB

    func load32(offset: UInt32) throws -> Int32
    func store32(offset: UInt32, value: Int32) throws
}
```

組み込みでは動的拡張を避け、固定サイズで確保する。

---

## Step 4: Host Function

### Host Function とは

Wasm 単体ではファイルやハードウェアにアクセスできない。
**Host Function** は、ホスト（Swift 側）の関数を Wasm に公開する仕組みで、
これを通じて GPIO や OLED を操作する。

```text
Wasm コード
   │ call "env" "digitalWrite"
   ▼
Host Function Layer（Swift）
   │
   ▼
Pico GPIO
```

### Swift 的設計

```swift
protocol HostFunction {
    var moduleName: String { get }
    var functionName: String { get }
    func call(args: [WasmValue]) throws -> WasmValue?
}
```

型安全のため、GPIO ピン番号は `Int32` の生値ではなく専用型で扱う。

```swift
struct GPIOPin {
    let number: UInt8
}
```

### 初期 Host API

| 関数名 | シグネチャ | 機能 |
|--------|-----------|------|
| `digitalWrite` | `(i32, i32) -> void` | GPIO 出力 |
| `digitalRead` | `(i32) -> i32` | GPIO 入力 |
| `sleep` | `(i32) -> void` | 待機（ms） |
| `oledDrawText` | `(i32, i32, i32) -> void` | OLED 表示 |

---

## 成功基準

- [x] `i32.add` を含む簡単な Wasm 関数を実行できる
- [x] ローカル変数の get/set が正しく動作する
- [x] 関数呼び出し（call / return）が動作する
- [x] Type Validation が不正な Wasm を弾ける（macOS ビルドのみ）
- [x] Linear Memory への load/store が動作する
- [x] Host Function 経由で Swift のコードを呼び出せる

## 追加実装済み（Step 1〜4 以降）

- [x] `i64` 全算術・比較・ビット演算命令（`i64.add` / `i64.sub` / `i64.mul` / `i64.div_s` / ... など）
- [x] `f32` 算術・比較・単項演算命令（`f32.add` / `f32.sqrt` / `f32.le` など）
- [x] `f64` 算術・比較・単項演算命令の全セット
  - 比較 6 種（0x61–0x66）: `f64.eq` / `f64.ne` / `f64.lt` / `f64.gt` / `f64.le` / `f64.ge` → `i32`
  - 単項 7 種（0x99–0x9F）: `f64.abs` / `f64.neg` / `f64.ceil` / `f64.floor` / `f64.trunc` / `f64.nearest` / `f64.sqrt` → `f64`
  - 二項算術 7 種（0xA0–0xA6）: `f64.add` / `f64.sub` / `f64.mul` / `f64.div` / `f64.min` / `f64.max` / `f64.copysign` → `f64`
- [x] `call_indirect`（複数テーブルサポート、result 型チェック含む）
- [x] Global 変数（`global.get` / `global.set`）
  - グローバルセクションの init 式で `ref.null`（0xD0）と `ref.func`（0xD2）をサポート済み
    - `ref.null reftype`: null funcref として `.funcref(nil)` を設定
    - `ref.func funcidx`: 非 null funcref として `.funcref(funcidx)` を設定
- [x] フラット bytecode への移行（`block` / `loop` / `if` が `indirect case` を使わずジャンプオフセットで管理）
- [x] メモリ命令（全 load/store 命令）
  - `i32.load`（0x28）、`i64.load`（0x29）、`f32.load`（0x2A）、`f64.load`（0x2B）
  - `i32.load8_s`（0x2C）、`i32.load8_u`（0x2D）、`i32.load16_s`（0x2E）、`i32.load16_u`（0x2F）
  - `i64.load8_s`（0x30）、`i64.load8_u`（0x31）、`i64.load16_s`（0x32）、`i64.load16_u`（0x33）
  - `i64.load32_s`（0x34）、`i64.load32_u`（0x35）
  - `i32.store`（0x36）、`i64.store`（0x37）、`f32.store`（0x38）、`f64.store`（0x39）
  - `i32.store8`（0x3A）、`i32.store16`（0x3B）
  - `i64.store8`（0x3C）、`i64.store16`（0x3D）、`i64.store32`（0x3E）
  - `memory.size`（0x3F）、`memory.grow`（0x40）
- [x] `i64.extend_i32_s`（型変換命令の一部）
- [x] テーブル参照命令: `table.get`（0x25）/ `table.set`（0x26）
  - `funcref` 型テーブルに対する要素の読み書きをサポート
  - `Value` enum に `.funcref(UInt32?)` ケースを追加（`nil` = null reference、`UInt32` = 関数インデックス）
  - `funcref` ローカル変数のデフォルト初期値は `nil`（Wasm 仕様準拠）
  - バリデータ (`WasmValidator`) での境界チェック・型チェックを実装済み
- [x] Bulk Memory 命令（0xFC プレフィックス）— メモリ操作
  - `memory.init`（0xFC 0x08）: passive data segment の内容を線形メモリにコピー
    - n=0 の場合も境界チェックを適用（Wasm 仕様準拠）
    - dropped segment は長さ 0 として扱う（境界チェックは通す）
  - `data.drop`（0xFC 0x09）: data segment を解放済みとしてマーク（冪等）
  - `memory.copy`（0xFC 0x0A）: 線形メモリ内コピー（オーバーラップ対応、memmove 相当）
    - n=0 の場合も境界チェックを適用（Wasm 仕様準拠）
  - `memory.fill`（0xFC 0x0B）: n バイトをバイト値 val で埋める（dst + n でも境界チェック適用）
  - `DataSegment.offset` を `Int32?` に変更（`nil` = passive、非 `nil` = active のメモリ書き込みオフセット）
  - インタプリタ init 時: active segments のみメモリに書き込み、passive はスキップ
  - `WasmInterpreter` に `droppedDataSegments: [Bool]` を追加して `data.drop` 状態を追跡
  - パーサー: Data セクションで flags=0（active）/ flags=1（passive）/ flags=2（active + explicit mem index）に対応
  - バリデータ: `memoryInit` / `dataDrop` / `memoryCopy` / `memoryFill` のセグメント境界チェック・型チェックを実装
  - spectest: `memory_init` 240 pass / 0 skip / 0 fail（完全合格）
- [x] Bulk Table 命令（0xFC プレフィックス）— テーブル操作
  - `table.init`（0xFC 0x0C）: passive element segment の内容をテーブルにコピー
    - n=0 の場合も境界チェックを適用（Wasm 仕様準拠）
    - dropped segment は長さ 0 として扱う（境界チェックは通す）
  - `elem.drop`（0xFC 0x0D）: element segment を解放済みとしてマーク（冪等）
  - `table.copy`（0xFC 0x0E）: テーブル内コピー（オーバーラップ対応）
    - n=0 の場合も境界チェックを適用（Wasm 仕様準拠）
    - spectest: `table_copy` 1728 pass / 0 skip / 0 fail（element segment flags 3–7 対応後に完全合格）
  - `ElementSegment` の 3 分類と対応フィールド（Wasm 仕様 §4.5.4 準拠）:
    - `isPassive: Bool`（`true` = passive または declarative、`false` = active）
    - `isDeclarative: Bool`（`true` = declarative segment（flags=3/5/7））を追加
    - `functionIndices: [UInt32?]`（`nil` エントリは null 参照を表す。表現式ベースセグメントで `ref.null` から生成）
  - Element segment の 3 種類の扱い:
    - **Active**: インスタンス化時にテーブルへ書き込み、完了後に dropped として扱う
    - **Passive**（`isDeclarative=false`）: インスタンス化時はスキップ。`table.init` / `elem.drop` でランタイムに使用可能
    - **Declarative**（`isDeclarative=true`）: インスタンス化時に即 dropped として扱う。`ref.func` 命令の正当性付与のみを目的とし、`table.init` からアクセス不可
  - パーサー: Element セクション flags 0–7（Wasm 2.0 エンコーディング）を全対応:
    - flags=0: active, table 0, i32.const offset, function index list（MVP）
    - flags=1: passive, elemkind(0x00), function index list
    - flags=2: active, explicit table index, i32.const offset, elemkind(0x00), function index list
    - flags=3: declarative, elemkind(0x00), init_expr* list（`ref.func` / `ref.null` per element）
    - flags=4: active, table 0, i32.const offset, init_expr* list
    - flags=5: declarative, reftype byte, init_expr* list
    - flags=6: active, explicit table index, offset expr, reftype byte, init_expr* list
    - flags=7: declarative, reftype byte, init_expr* list
  - `readFuncrefInitExpr()` ヘルパーを追加: `ref.null reftype 0x0B` → `nil`（null 参照）、`ref.func funcidx 0x0B` → `UInt32`
  - `WasmInterpreter` に `droppedElementSegments: [Bool]` を追加して `elem.drop` 状態を追跡
  - バリデータ: `tableInit` / `elemDrop` / `tableCopy` のセグメント境界チェック・型チェックを実装
- [x] 型変換命令（通常変換 0xA7–0xBF、Saturating truncation 0xFC 0x00–0x07）
  - 通常変換命令（opcode 0xA7–0xBF）:
    - `i32.wrap_i64`（0xA7）
    - `i32.trunc_f32_s`（0xA8）、`i32.trunc_f32_u`（0xA9）
    - `i32.trunc_f64_s`（0xAA）、`i32.trunc_f64_u`（0xAB）
    - `i64.extend_i32_u`（0xAD）
    - `i64.trunc_f32_s`（0xAE）、`i64.trunc_f32_u`（0xAF）
    - `i64.trunc_f64_s`（0xB0）、`i64.trunc_f64_u`（0xB1）
    - `f32.convert_i32_s`（0xB2）、`f32.convert_i32_u`（0xB3）
    - `f32.convert_i64_s`（0xB4）、`f32.convert_i64_u`（0xB5）
    - `f32.demote_f64`（0xB6）
    - `f64.convert_i32_s`（0xB7）、`f64.convert_i32_u`（0xB8）
    - `f64.convert_i64_s`（0xB9）、`f64.convert_i64_u`（0xBA）
    - `f64.promote_f32`（0xBB）
    - `i32.reinterpret_f32`（0xBC）、`i64.reinterpret_f64`（0xBD）
    - `f32.reinterpret_i32`（0xBE）、`f64.reinterpret_i64`（0xBF）
  - Saturating truncation 命令（0xFC プレフィックス 0x00–0x07）:
    - `i32.trunc_sat_f32_s`（0xFC 0x00）、`i32.trunc_sat_f32_u`（0xFC 0x01）
    - `i32.trunc_sat_f64_s`（0xFC 0x02）、`i32.trunc_sat_f64_u`（0xFC 0x03）
    - `i64.trunc_sat_f32_s`（0xFC 0x04）、`i64.trunc_sat_f32_u`（0xFC 0x05）
    - `i64.trunc_sat_f64_s`（0xFC 0x06）、`i64.trunc_sat_f64_u`（0xFC 0x07）
  - spectest: `conversions` 619 pass / 0 skip / 0 fail（完全合格）
  - 全 spectest: 3587 件すべてパス
- [x] メモリ管理命令
  - `memory.size`（0x3F）: 現在のメモリページ数を i32 でプッシュ（1 ページ = 65536 バイト）
    - spectest: `memory_size` 42 pass（完全合格）
  - `memory.grow`（0x40）: delta を u32 として解釈するよう修正（負の i32 ビットパターンを大きな u32 と見なす）。
    宣言された最大ページ数（`MemoryType.max`）を考慮したオーバーフローチェックも追加
- [x] テーブル管理命令（0xFC プレフィックス、追加分）
  - `table.size`（0xFC 0x10）: テーブルの現在の要素数を i32 でプッシュ
    - spectest: `table_size` 39 pass（完全合格）
  - `table.grow`（0xFC 0x0F）: テーブルを n 要素拡張し、旧サイズを返す。失敗時は -1
    - delta を u32 として解釈。テーブルの宣言最大値（`TableType.max`）を考慮したオーバーフローチェックを実装
    - spectest: `table_grow` 24 pass
  - `table.fill`（0xFC 0x11）: テーブルの dst から n 要素を ref 値で埋める
    - dst・n を u32 として解釈。n=0 かつ dst = table size の境界ケースを含む
    - spectest: `table_fill` 9 pass
  - バリデータ: `tableGrow` / `tableSize` / `tableFill` の型チェック・境界チェックを実装
- [x] 参照型命令
  - `ref.null`（0xD0）: null funcref をプッシュ（funcref / externref バイトを受け入れるがどちらも `.funcref(nil)` として扱う）
  - `ref.is_null`（0xD1）: スタックの funcref が null なら 1、そうでなければ 0 を i32 でプッシュ
  - `ref.func x`（0xD2）: 関数インデックス x の funcref をプッシュ（範囲外なら `functionNotFound` トラップ）
  - バリデータ: `refNull` / `refIsNull` / `refFunc` の型チェック・境界チェックを実装

### 既知の未対応・TODO（Embedded フェーズ向け）

- 32 ビットターゲットでの実効アドレス計算: 現在 `let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)` と記述しているが、32 ビット環境では `Int` が 32 ビット幅のため、加算がオーバーフローする可能性がある。Embedded フェーズでは `UInt64` 中間計算に変更が必要（詳細は `Documentations/EMBEDDED_SWIFT.md` の「メモリアクセスの実効アドレス計算」を参照）

### 設計上の対象外事項

**クロスモジュール・リンキング**（テーブル/メモリインポートによるモジュール間共有）は実装を見送っている。
詳細な理由は `Documentations/WASM_SPEC.md` の「クロスモジュール・リンキングを対象外とする理由」を参照。

ただし、spectest における **`register` コマンド**（モジュールを名前付きで登録し、後続モジュールのホスト関数インポートとして使用する仕組み）は `SpectestTests.swift` に実装済みである。

- `ConformanceRunner` に `registeredModules: [String: WasmInterpreter]` を追加
- `handleRegister` により `currentInterp`（または named module）を指定の名前で登録
- 新規モジュールロード時に `crossModuleImports(for:)` が登録済みモジュールからホスト関数インポートを生成
- これにより `table_copy` spectest が 1728 pass / 0 skip を達成した（以前は skip=1117）

この実装は値コピー（`var capturedInterp = regInterp`）で済む純粋関数のインポートに限定されており、テーブル/メモリの参照共有（真のクロスモジュール・リンキング）は実装していない。
