# Phase 5 — Raspberry Pi Pico への移植・動作確認

## 目的

Phase 3〜4 で macOS 上に実装した Wasm パーサー・インタプリタを
Embedded Swift 向けにクロスコンパイルし、Raspberry Pi Pico 2 (RP2350) 上で動作させる。
Wasm から GPIO を制御することを最低成功ラインとする。

---

## 移植時の主な課題

### 動的アロケーションの排除

macOS 版では `Array` や動的なデータ構造を使えるが、
Embedded Swift では動的アロケーションを最小化する必要がある。

| macOS 版 | Embedded 版 |
|----------|------------|
| `var stack: [WasmValue]` | 固定長バッファ + インデックス管理 |
| `var locals: [WasmValue]` | スタック上の固定配列 |
| `String` によるログ | UART への直接書き込み |

### Arena Allocator

組み込みでよく使われる手法。
一度確保した大きなバッファから順番に切り出して使い、まとめて解放する。

```text
[          大きなバッファ（例: 64KB SRAM の一部）          ]
 ↑使用済み↑ ↑ここから次を確保
```

個別の `malloc` / `free` を繰り返すより高速で断片化しない。

---

## Actor ベース Runtime 設計

Phase 5 では、Swift Concurrency の `actor` を用いた安全な Runtime 設計も試みる。
ただし Embedded Swift での Concurrency サポートは限定的なため、
まず macOS / Swift Playground 上で設計を検証してから Pico に適用する。

### なぜ Actor を使うか

組み込みでも複数のタスク（Wasm 実行・GPIO 割り込み・UART 通信）が並行する場面がある。
`actor` により、共有状態へのアクセスを Swift コンパイラが安全に管理してくれる。

```swift
actor WasmRuntime {
    private var module: WasmModule?

    func load(_ binary: [UInt8]) throws
    func execute(function: String) async throws -> WasmValue?
}

actor GPIOController {
    func write(pin: GPIOPin, value: Bool)
    func read(pin: GPIOPin) -> Bool
}
```

### Embedded Swift での制約

Embedded Swift では `actor` / `async` / `await` のサポートが現時点で限定的。
利用できるかは toolchain バージョンに依存するため、実際の動作確認が必要。

---

## 動作確認項目

### 最低確認

```text
Pico 上で Wasm バイナリをロードし、
i32.add を含む関数を実行して UART に結果を出力する
```

### GPIO 制御確認

```text
Wasm から Host Function 経由で LED を点滅させる
（digitalWrite を Wasm から呼び出す）
```

---

## 成功基準

- [ ] Embedded Swift でパーサー・インタプリタがビルドできる
- [ ] Pico 上で Wasm モジュールをロードできる
- [ ] Wasm から `i32.add` を実行して UART に結果が出る
- [ ] Wasm の Host Function 経由で LED を制御できる
