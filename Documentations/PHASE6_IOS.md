# Phase 6 — iOS 連携

## 目的

iPhone から Wasm バイナリを Raspberry Pi Pico へ無線転送し、
ファームウェアを書き換えなくても Pico の動作を変更できる Scriptable Device を構築する。

---

## 通信方式の選択

| 方式 | メリット | デメリット |
|------|----------|-----------|
| **BLE** | 追加ハードウェア不要（Pico W に内蔵）、低消費電力 | 転送速度が遅い |
| **Wi-Fi** | 高速転送、HTTP でシンプルに実装可能 | Pico W が必要、消費電力大 |

初期実装は **BLE** を優先する。Wasm バイナリは数 KB 程度を想定しており、BLE でも現実的な速度で転送できる。

---

## iOS アプリ機能

### 必須機能

| 機能 | 説明 |
|------|------|
| Wasm バイナリ転送 | ファイルアプリ等から `.wasm` を選択して Pico へ送信 |
| 実行ログ表示 | Pico の UART ログを BLE 経由でリアルタイム表示 |

### 拡張機能

| 機能 | 説明 |
|------|------|
| スクリプト管理 | 複数の Wasm バイナリを保存・切り替え |
| OLED プレビュー | Pico の OLED 表示内容をミラーリング |
| デバイスモニター | CPU 負荷・メモリ使用量の表示 |

---

## Swift Ecosystem の活用

iOS アプリと Pico 側の Embedded Swift でモデルを共有できる。

```swift
// 共通プロトコル（iOS / Embedded Swift 両方で使用）
protocol WasmPacket: Codable {
    var binaryData: [UInt8] { get }
    var name: String { get }
}
```

同じ Swift エコシステムの強みを活かし、シリアライズ形式や通信プロトコルを共通化する。

---

## Scriptable Device 化

Phase 6 の最終形として、以下を実現する。

- iPhone から Wasm をアップロードするだけで Pico の動作が変わる
- 複数の Wasm アプリを動的に切り替えられる
- フラッシュへの永続保存（電源 OFF 後も保持）
- センサー・OLED・GPIO を Wasm から制御できる

---

## 将来的な拡張（スコープ外）

| 拡張 | 内容 |
|------|------|
| WASI サブセット | 標準 Wasm システムインターフェースへの対応 |
| Component Model | Wasm コンポーネント間の連携 |
| Bytecode 最適化 | Predecode / Threaded Interpreter による高速化 |
| Mini Scheduler | 複数 Wasm タスクの簡易スケジューリング |

---

## 成功基準

- [ ] iPhone から `.wasm` ファイルを選択して Pico へ BLE 送信できる
- [ ] 転送した Wasm が即時実行される
- [ ] 実行ログを iOS アプリでリアルタイム確認できる
- [ ] 異なる Wasm を再転送して動作が切り替わる
