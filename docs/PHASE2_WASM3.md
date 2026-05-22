# Phase 2 — Wasm3 調査・参考点洗い出し

## 目的

組み込み向け Wasm Runtime である Wasm3 のソースコードを読解し、
本プロジェクトの設計に活かせる参考点を整理する。

---

## Wasm3 を参考にする理由

Wasm3 は組み込み向け Wasm Runtime として以下の特徴を持つ。

- **小型**: MCU に収まるコードサイズ
- **Interpreter 方式**: JIT 不要で移植性が高い
- **MCU 実績が豊富**: ESP32 / STM32 など多数の実績あり
- **実装が比較的読みやすい**: C で書かれており構造が明快
- **Portable**: プラットフォーム依存が少ない

本プロジェクトでは Wasm3 の設計思想を学びながら、Swift 的に再設計することを目的とする。

---

## 調査結果

### 1. Runtime 構造（階層・ライフサイクル）

ソース: `m3_env.h`, `m3_function.h`

```text
M3Environment
  └ M3Runtime
      ├ M3Memory        (Linear Memory: Wasm の線形メモリ空間)
      ├ M3CodePage[]    (コンパイル済みオペレーション列)
      └ M3Module[]      (リンクリストで複数モジュールを保持)
          ├ M3FuncType[]    (関数シグネチャの重複排除済みリスト)
          ├ M3Function[]    (関数定義)
          ├ M3Global[]      (グローバル変数)
          └ M3DataSegment[] (データセグメント)
```

各層の役割:

| 構造体 | 役割 |
|---|---|
| `M3Environment` | グローバル設定・FuncType の重複排除・解放済み CodePage のキャッシュ |
| `M3Runtime` | 実行コンテキスト全体。スタック・メモリ・コードページを所有 |
| `M3Module` | Wasm バイナリ 1 ファイルに対応。Runtime にリンクリストで接続 |
| `M3Function` | 関数定義。バイトコード範囲・コンパイル済み PC・スタックスロット数を保持 |
| `M3FuncType` | 関数シグネチャ（引数・戻り値の型列）。Environment レベルで重複排除 |
| `M3Memory` | Wasm の Linear Memory。`M3MemoryHeader` を先頭に持つ連続領域 |

**重要な設計ポイント:**

- `M3Memory` の実体は `M3MemoryHeader` + データ領域の連続メモリブロック。`m3MemData(mem)` マクロで
  ヘッダの直後のポインタを得る。
- Module は Runtime に `next` ポインタで連結されたリンクリスト。
- `M3FuncType` も Environment でリンクリスト管理し、同一シグネチャはポインタ比較で等価判定できる。

---

### 2. Interpreter Loop（Threaded Code ディスパッチ）

ソース: `m3_exec_defs.h`, `m3_exec.h`

wasm3 は `switch` ではなく **Threaded Code**（関数ポインタ直接呼び出し）で Opcode をディスパッチする。

```c
// 各 Op は同じシグネチャを持つ関数
typedef m3ret_t (vectorcall * IM3Operation) (pc_t _pc, m3stack_t _sp, M3MemoryHeader* _mem, m3reg_t _r0, f64 _fp0);

// 次の Op へジャンプ（tail call 最適化前提）
#define nextOpDirect()   M3_MUSTTAIL return nextOpImpl()
// nextOpImpl() = ((IM3Operation)(*_pc))(_pc + 1, ...)
```

**仕組みの流れ:**

1. コンパイル時に「関数ポインタの配列」として命令列を生成（CodePage に書き込む）
2. 実行時は `(*_pc)` で関数ポインタを取得し、`_pc+1` を次の PC として tail call
3. `M3_MUSTTAIL` により各 Op はスタックフレームを消費しない（スタックオーバーフロー回避）

**スタックの構造: Register + Slot のハイブリッド**

```text
_r0  : i64 レジスタ（整数演算の最上位値）
_fp0 : f64 レジスタ（浮動小数点の最上位値）
_sp  : m3stack_t（スロット配列へのポインタ）
```

- 演算の最上位オペランドは `_r0` / `_fp0` レジスタに置かれる
- それ以外は `_sp` が指すスロット配列に格納
- Op の命名規則: `_rs`（slot ← reg）, `_sr`（reg ← slot）, `_ss`（slot ← slot）

**Op の例:**

```c
d_m3Op(i32_Add_rs) {
    i32 operand = slot(i32);      // _sp から読む
    _r0 = (i32)((u32)operand + (u32)_r0);  // _r0 レジスタへ
    nextOp();
}
```

---

### 3. Host Function Binding（シグネチャ文字列方式）

ソース: `m3_bind.h`, `m3_bind.c`, `wasm3.h`

```c
m3_LinkRawFunction(module, "env", "digitalWrite", "v(ii)", &fn_digitalWrite);
```

シグネチャ文字列の意味:

| 文字 | 型 |
|---|---|
| `v` | void |
| `i` | i32 |
| `I` | i64 |
| `f` | f32 |
| `F` | f64 |
| `*` | ポインタ（Linear Memory アドレス） |

`SignatureToFuncType()` でこの文字列を `M3FuncType` に変換し、モジュールの型テーブルと照合してリンクする。

Host Function の呼び出し規約:

```c
// Host Function のシグネチャ
m3ret_t fn_digitalWrite(IM3Runtime runtime, IM3ImportContext ctx, uint64_t* sp, void* mem) {
    i32 pin = *(i32*)(sp + 1);  // 第1引数
    i32 val = *(i32*)(sp + 2);  // 第2引数
    // ...
    return m3Err_none;
}
```

---

### 4. Linear Memory 管理

ソース: `m3_env.h`, `m3_exec.h`

```text
mallocated ポインタ
  ↓
[ M3MemoryHeader | runtime* | maxStack* | length ] [ ...データ領域... ]
                                                    ↑
                                               m3MemData(mem)
```

- メモリ全体を 1 つの `malloc` で確保。先頭に `M3MemoryHeader` を置きその直後にデータ。
- ページ単位（デフォルト 64KB）で `ResizeMemory()` により拡張可能（`memory.grow` 命令）。
- 境界チェック: すべての Load/Store Op で `operand + sizeof(T) <= _mem->length` を確認。

```c
if (m3MemCheck(operand + sizeof(SRC_TYPE) <= _mem->length)) {
    memcpy(&value, src8, sizeof(value));
    ...
} else d_outOfBounds;
```

- `d_m3SkipMemoryBoundsCheck` を定義すると境界チェックをスキップできる（速度優先の組み込み向け）。
- `_mem` ポインタは `memory.grow` 後に再取得が必要（realloc でアドレスが変わりうるため）。

---

### 5. Call Stack・Frame 管理

ソース: `m3_exec.h`（`op_Entry`, `op_Call`）

wasm3 には独立した「コールスタックフレーム構造体」は存在しない。  
代わりにスタックスロット配列 `_sp` をオフセットで分割して使う。

```text
_sp + 0                    : 戻り値スロット
_sp + numRetSlots          : 引数スロット
_sp + numRetAndArgSlots    : ローカル変数スロット（Entry で memset ゼロクリア）
_sp + numRetAndArgSlots + numLocalBytes : 定数スロット（Entry で memcpy）
```

`op_Entry` が行うこと:
1. スタックオーバーフローチェック（`maxStackSlots` と `maxStack` を比較）
2. ローカル変数領域を `memset(0)` でゼロクリア
3. 定数を `memcpy` でスタックに展開

`op_Call` が行うこと:
1. `stackOffset` 分 `_sp` をずらして呼び出し先のフレームを設定
2. tail call で `op_Entry` へジャンプ

---

### 6. CodePage とコンパイルフロー

ソース: `m3_env.h`, `m3_code.h`

wasm3 は純粋 Interpreter ではなく、実行前に Wasm バイトコードを「Op 関数ポインタ列」に変換する。  
この変換結果を `M3CodePage`（固定サイズのメモリブロック）に書き込む。

```text
Wasm binary → [Parse] → M3Function(wasm bytes) → [Compile] → M3CodePage(op ptr列)
```

- `M3CodePage` は Runtime がリンクリストで管理（`pagesOpen` / `pagesFull`）。
- 関数は初回呼び出し時に Lazy Compile される（`op_Compile` → `op_Call` に書き換え）。
- 一度コンパイルされた Op 列は「その場で rewrite」されキャッシュされる（`rewrite_op` マクロ）。

---

## Swift への設計転用ポイント

### A. 階層構造 → Swift の型システムで自然に表現できる

wasm3 では構造体ポインタ (`IM3Runtime`, `IM3Module` など) で疑似的に所有権を表現しているが、  
Swift では値型・参照型・`Sendable` で明確に表現できる。

```swift
// wasm3: IM3Runtime = M3Runtime* (手動管理)
// Swift: class + deinit で安全に

final class Runtime {
    var memory: Memory
    var modules: [Module] = []
    // deinit で自動解放
}
```

### B. エラー処理 → `Result<T, WasmError>` / `throws`

wasm3 では `M3Result = const char*` でエラーを文字列ポインタとして返す。  
`NULL` が成功、非 NULL がエラーメッセージという設計。

```c
// wasm3
M3Result r = m3_Call(function, 0, NULL);
if (r) { printf("error: %s", r); }

// Swift に転用
enum WasmTrap: Error {
    case stackOverflow
    case outOfBoundsMemoryAccess
    case unreachable
    case divisionByZero
    case indirectCallTypeMismatch
}
// → throws / Result<T, WasmTrap> で型安全に
```

### C. Wasm 値型 → Swift enum で型安全に

wasm3 では `u8 type` フラグ + `union` で値を保持し、型の不一致はランタイムエラー。  
Swift では associated value 付き enum で型安全に表現できる。

```swift
// wasm3: union { i32Value; i64Value; f32Value; f64Value } + u8 type
// Swift:
enum WasmValue {
    case i32(Int32)
    case i64(Int64)
    case f32(Float)
    case f64(Double)
}
```

### D. Host Function Binding → クロージャ + 型パラメータ

wasm3 の文字列シグネチャ方式（`"v(ii)"`）はランタイムまで型エラーを検出できない。  
Swift ではジェネリクスやクロージャを活用してコンパイル時に型チェック可能。

```swift
// wasm3 (ランタイム型チェック)
m3_LinkRawFunction(module, "env", "digitalWrite", "v(ii)", &fn)

// Swift (コンパイル時型チェック)
runtime.link("env", "digitalWrite") { (pin: Int32, val: Int32) in
    gpio.write(pin: pin, value: val)
}
```

### E. Linear Memory → Swift の `UnsafeBufferPointer` + 境界チェック

```swift
struct LinearMemory {
    private var buffer: [UInt8]  // or UnsafeMutableRawBufferPointer (組み込みでは後者)

    subscript(offset: Int, as type: UInt32.Type) -> UInt32 {
        get throws {
            guard offset + 4 <= buffer.count else { throw WasmTrap.outOfBoundsMemoryAccess }
            return buffer.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        }
    }
}
```

### F. Interpreter Loop → Swift の関数ディスパッチ

wasm3 の Threaded Code（関数ポインタ配列 + tail call）は Embedded Swift では直接使えない可能性がある。  
`switch` ベースのシンプルな実装から始め、ボトルネックが判明してから最適化する方針が堅実。

```swift
// シンプルな switch ベース（学習フェーズに適切）
mutating func execute(_ opcode: Opcode) throws {
    switch opcode {
    case .i32Const(let v): stack.push(.i32(v))
    case .i32Add:          let b = stack.pop(); let a = stack.pop(); stack.push(a + b)
    case .call(let idx):   try callFunction(at: idx)
    // ...
    }
}
```

### G. Actor を使ったスレッドセーフな Runtime

wasm3 はシングルスレッド前提でスレッド安全性を保証しない。  
Swift では `actor` で分離することで複数 Wasm インスタンスを安全に並列実行できる。

```swift
actor WasmRuntime {
    private var memory: LinearMemory
    private var stack: OperandStack
    // actor 分離により同時アクセスをコンパイラが防ぐ
}
```

---

## 成果物

- [x] Runtime 構造メモ（階層・ライフサイクル） → 「調査結果 1」参照
- [x] Opcode 実行フローメモ → 「調査結果 2」参照
- [x] Memory 管理メモ → 「調査結果 4」参照
- [x] Swift への設計転用ポイントまとめ → 「Swift への設計転用ポイント」参照

---

## 成功基準

- [x] Environment → Runtime → Module → Function の階層を説明できる
- [x] Opcode ディスパッチループの仕組みを説明できる
- [x] Host Function の登録・呼び出しフローを追える
- [x] Linear Memory の境界チェック実装を読み解ける
