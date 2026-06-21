# Arena Allocator 設計

WebAssembly Runtime のメモリ管理戦略。macOS・Embedded 両プラットフォームで使用する。

---

## 1. 背景と目的

### 現状の課題

BLE デモは「受信 → ロード → 実行 → 破棄」を繰り返す。この過程で現在も残っている
動的確保（`malloc`）を以下に示す。

| 確保箇所 | 型 | サイズ（典型値） |
|---------|-----|----------------|
| `WasmInterpreter.memory` | `[UInt8]` | **64 KB**（1 page） |
| `DataSegment.bytes` | `[UInt8]` | 数十〜数百 B × n |
| `FunctionImport.module / .name` | `[UInt8]` | 数 B × n |
| `Export.nameBytes` | `[UInt8]` | 数 B × n |

**線形メモリ（64 KB）の繰り返し確保・解放がヒープ断片化の主因である。**

### 解決方針

起動時（または Arena 初期化時）に大きなバッファを **1 回だけ** 確保し、モジュールの
ロード〜実行〜破棄のサイクル全体をそこから賄う。これを **WasmArena** と呼ぶ。

実行終了後は `reset()` を呼ぶだけで全確保を O(1) で解放できる（個別 `free` 不要）。

---

## 2. 方針決定

### 両プラットフォームで使用する

Arena は macOS / Embedded 両方に設ける。これにより：

- `WasmParser.parse(arena:)` / `WasmInterpreter.init(module:arena:...)` の
  シグネチャに `#if hasFeature(Embedded)` 分岐が不要になる
- macOS のテストでも Arena コードパスを検証できる
- `WasmInterpreter.memory` の型変更（後述）が両プラットフォームで統一される

### パラメータ渡し

Arena は `inout` パラメータとして `WasmParser` / `WasmInterpreter` に渡す。
グローバル変数にしないことで `WasmRuntime` ライブラリが外部状態に依存しなくなり、
テスト時に任意サイズの Arena を渡せる。

```swift
// Main.swift（Embedded）
var wasmArena = WasmArena()               // 起動時に 1 度だけ初期化

func executeReceivedWasm(conHandle: UInt16) {
    wasmArena.reset()                     // O(1) — 前回の全確保を解放
    var parser = WasmParser(wasmBuf)
    let module  = try parser.parse(arena: &wasmArena)
    var interp  = try WasmInterpreter(module: module, arena: &wasmArena, hostImports: ...)
    // ...
}

// Tests（macOS）
var arena = WasmArena(capacity: 128 * 1024)
var interp = try WasmInterpreter(module: module, arena: &arena, hostImports: [...])
```

### バッキングストレージ（プラットフォーム別）

```
Embedded : wasm_arena.c の static uint8_t buf[] を参照（malloc ゼロ）
macOS    : init 時に 1 回だけ malloc（_ArenaStorage クラス経由）
```

`#if hasFeature(Embedded)` は `WasmArena` の stored properties と `init` のみに限定する。
`allocate` / `reset` など API メソッドは両プラットフォームで共通。

---

## 3. WasmArena 構造体

```swift
// ── macOS バッキング（Embedded では不使用）──────────────────────────────────
#if !hasFeature(Embedded)
/// Single-allocation backing for WasmArena on macOS.
/// Holds a heap-allocated buffer for the lifetime of the Arena instance.
private final class _ArenaStorage {
    let ptr: UnsafeMutablePointer<UInt8>
    let capacity: Int
    init(capacity: Int) {
        ptr = .allocate(capacity: capacity)
        ptr.initialize(repeating: 0, count: capacity)
        self.capacity = capacity
    }
    deinit { ptr.deallocate() }
}
#endif

// ── WasmArena ─────────────────────────────────────────────────────────────
struct WasmArena {
    // --- Backing storage (platform-specific) ---
    #if hasFeature(Embedded)
        private let _base: UnsafeMutablePointer<UInt8>
        private let _capacity: Int
        init() {
            _base     = wasm_arena_ptr()!
            _capacity = Int(wasm_arena_size())
        }
    #else
        private let _storage: _ArenaStorage
        private var _base: UnsafeMutablePointer<UInt8> { _storage.ptr }
        private var _capacity: Int { _storage.capacity }
        init(capacity: Int = 96 * 1024) {
            _storage = _ArenaStorage(capacity: capacity)
        }
    #endif

    // --- Common state ---
    private var _used: Int = 0

    var usedBytes: Int      { _used }
    var availableBytes: Int { _capacity - _used }

    // --- Allocation ---
    /// Bump-allocate `count` bytes with the given alignment.
    /// Returns nil if capacity would be exceeded.
    mutating func allocate(
        count: Int,
        alignment: Int = 1
    ) -> UnsafeMutableBufferPointer<UInt8>? {
        let aligned = (_used + alignment - 1) & ~(alignment - 1)
        guard aligned + count <= _capacity else { return nil }
        let ptr = _base.advanced(by: aligned)
        _used = aligned + count
        return UnsafeMutableBufferPointer(start: ptr, count: count)
    }

    // --- Reset ---
    /// Release all allocations (O(1)).
    /// The backing memory is NOT zeroed; callers must initialize each allocation.
    mutating func reset() { _used = 0 }
}
```

---

## 4. C バッキングバッファ（Embedded）

`wasm_recv_buf.c` と同じパターンで `wasm_arena.c` を追加する。

```c
// wasm_arena.c
#include <stdint.h>

#define WASM_ARENA_SIZE (96 * 1024)   // 実機計測後に調整
static uint8_t arena_buf[WASM_ARENA_SIZE] __attribute__((aligned(8)));

uint8_t  *wasm_arena_ptr(void)  { return arena_buf; }
uint32_t  wasm_arena_size(void) { return WASM_ARENA_SIZE; }
```

```c
// BridgingHeader.h に追記
uint8_t  *wasm_arena_ptr(void);
uint32_t  wasm_arena_size(void);
```

静的配列なのでリンカが SRAM に配置し、ヒープと完全に独立する。

---

## 5. WasmInterpreter.memory の型変更（完了）

`var memory: [UInt8]` は `UnsafeMutableBufferPointer<UInt8>` へ変更済み。
Arena-backed な生ポインタを持つので `#if` 不要で両プラットフォーム統一されている。

| | 変更前 | 変更後（現在） |
|--|--------|--------|
| 型 | `[UInt8]` | `UnsafeMutableBufferPointer<UInt8>` |
| 確保 | `[UInt8](repeating: 0, count: n)` | `arena.allocate(count: n, alignment: 4)!` |
| API | `memory[i]`、`memory.count` | 同じ（変更なし） |
| `dispatchEmbedded` 引数 | `memory: inout [UInt8]` | `memory: inout UnsafeMutableBufferPointer<UInt8>` |

`subscript` と `count` は `[UInt8]` / `UnsafeMutableBufferPointer<UInt8>` で共通なので、
`dispatchEmbedded` 内部の数百行のメモリアクセスコードは書き換えが不要だった。

また、`memory.grow` で使用する容量上限を管理するため `var memoryCapacity: Int` プロパティが
追加された。Arena は `init` 時に線形メモリの最大ページ数分（または最大 `WasmLimits` 上限分）を
先行確保し、`memory.grow` はポインタの `count` を拡張するだけでよい。

---

## 6. 統合ポイント（実装済み）

### 6-1. WasmInterpreter.init — 線形メモリ

```swift
// 変更前（旧実装）
var mem = [UInt8](repeating: 0, count: Int(memPageCount) * 65536)
self.memory = mem

// 変更後（現在の実装）
guard let slice = arena.allocate(count: Int(memPageCount) * 65536, alignment: 4) else {
    throw .resourceLimitExceeded
}
slice.initialize(repeating: 0)    // malloc 相当のゼロ初期化を手動で行う
self.memory = UnsafeMutableBufferPointer(slice)
```

### 6-2. DataSegment.bytes / 名前バイト列（ゼロコピースライス）

`rawBytes` はすでに BLE 受信バッファへの `UnsafeBufferPointer<UInt8>`（零コピー）。
import/export 名とデータセグメントのバイト列はすべて rawBytes の範囲スライスなので、
Arena へのコピーなしに `UnsafeBufferPointer<UInt8>` の subrange として保持できる。

```swift
// WasmParser 内（変更後）
// DataSegment.bytes の型を [UInt8] から UnsafeBufferPointer<UInt8> へ変更
let bytes = UnsafeBufferPointer(rebasing: rawBytes[start..<end])
```

rawBytes（BLE 受信バッファ）はモジュール実行中ずっと有効なので安全。

> **注**: これは Arena 確保ではなく「ゼロコピースライス」パターン。
> Arena が必要になるのは rawBytes の寿命を超えてデータを保持したい場合のみ。

---

## 7. SRAM レイアウト（実行時イメージ）

```
RP2350 SRAM: 520 KB / RP2040 SRAM: 264 KB

┌────────────────────────────────────────────┐  ← SRAM 先頭
│  Pico SDK / system        (~20 KB)         │
├────────────────────────────────────────────┤
│  BLE スタック / CYW43     (~50 KB)         │
├────────────────────────────────────────────┤
│  WasmArena 静的バッファ   (96 KB, 要検討)  │  ← wasm_arena.c
│  ┌────────────────────────────────────┐    │
│  │ 線形メモリ      (64 KB)            │    │
│  │ その他確保分    (< 32 KB)          │    │
│  │ 未使用領域                         │    │
│  └────────────────────────────────────┘    │
├────────────────────────────────────────────┤
│  WasmModule 固定バッファ   (~8 KB)         │  ← スタック上
├────────────────────────────────────────────┤
│  BLE 受信バッファ          (8 KB)          │  ← wasm_recv_buf.c
├────────────────────────────────────────────┤
│  スタック・その他                          │
└────────────────────────────────────────────┘  ← SRAM 末尾
```

---

## 8. 生存期間の制約

`WasmInterpreter.memory` は Arena が所有するメモリを指す生ポインタである。
**`WasmInterpreter` は Arena よりも先に破棄されなければならない。**

```
wasmArena.reset()         ← Arena リセット（次のサイクル開始）
  parser.parse(...)       ← Arena から名前/データ bytes を参照
  WasmInterpreter.init()  ← Arena からリニアメモリを確保
  interp.callExport(...)  ← Arena メモリを使って実行
  ← interp / module がここで破棄（スコープを抜ける）
  ← この時点で Arena への参照がなくなり、次の reset() が安全
```

`executeReceivedWasm` 関数の `do { }` スコープを正しく閉じることで保証される。

---

## 9. 実装フェーズ

| Step | 内容 | 検証 | 状態 |
|------|------|------|------|
| **1** | `wasm_arena.c` 追加、`WasmArena` 構造体実装（allocate / reset）、単体テスト | `swift test` | ✅ 完了 |
| **2** | `WasmInterpreter.memory` を `UnsafeMutableBufferPointer<UInt8>` へ変更。`init(module:arena:)` で Arena から確保。`memoryCapacity` プロパティ追加 | `swift test` + `make compile` | ✅ 完了 |
| **3** | `DataSegment.bytes` / 名前バイト列をゼロコピースライスへ変更（`WasmParser` 変更） | `swift test` + `make compile` | ✅ 完了 |
| **4** | `Main.swift` を更新（`wasmArena` グローバル、`reset()`、`init(arena:)`）。`memory.grow`（0x40）と `table.grow`（FC 0x15）を UInt64 ドメインで処理し 32-bit Int オーバーフロートラップを修正 | `make build` | ✅ 完了 |
| **5** | 実機で `wasmArena.usedBytes` を BLE 通知に含め、Arena サイズを実測ベースで調整 | 実機計測 | ⏳ 未実施 |

### Step 1 実装ノート

`WasmArena.swift` で Embedded ビルドが C シンボルを参照する際は、Bridging Header ではなく
`@_extern(c, "wasm_arena_ptr")` / `@_extern(c, "wasm_arena_size")` を使用する（`-enable-experimental-feature Extern` が `Makefile` と `CMakeLists.txt` に追加済み）。
これにより `Sources/WasmRuntime/` 単体でも `make compile` が通る（`BridgingHeader.h` は `Examples/` にのみ存在する）。

### Step 4 実装ノート（32-bit オーバーフロー修正）

`memory.grow`（opcode 0x40）と `table.grow`（opcode FC 0x15）では、delta を
`UInt32(bitPattern:)` でビットパターン再解釈した後、比較・演算を終始 `UInt64` ドメインで
行うよう修正した。RP2350 では `Int` が 32-bit であるため、unsigned delta が `Int32.max` を
超える場合に `Int(UInt32(bitPattern: delta))` がオーバーフロートラップを引き起こす。
`UInt64` で比較ガードを行ってから最終的に `Int` へ変換することでこのトラップを回避している。

---

## 10. 未解決事項

| 事項 | 内容 |
|------|------|
| **Arena サイズ** | 96 KB は推定。実機計測（Step 5）で確定。RP2040（264 KB SRAM）での成立を要確認 |
| **ゼロ初期化コスト** | `reset()` 後は前回データが残る。`allocate` 時に `initialize(repeating: 0)` を呼ぶが、64 KB ゼロ埋めのコストを実測する必要がある（memset 相当で高速なはずだが要確認） |
| **複数ページメモリ** | 2 pages（128 KB）が必要な Wasm が来た場合 Arena が不足する。上限チェックと `.resourceLimitExceeded` の発行で対処 |

> **解決済み**: `dispatchEmbedded` 内の `memory.withUnsafeMutableBytes` の置き換えは
> `UnsafeMutableBufferPointer<UInt8>` への型変更（Step 2）と同時に完了した。
