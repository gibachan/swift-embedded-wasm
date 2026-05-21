# プロジェクト最終成果物

## ターゲットハードウェア

| 区分 | ハードウェア |
|------|-------------|
| メイン | Raspberry Pi Pico 2 (RP2350) |
| サブ | Raspberry Pi Pico W |

---

## 背景・動機

通常の組み込み開発では、機能追加のたびにファームウェアを書き換えてフラッシュする必要がある。

```text
Swift Source → Firmware Build → Flash（毎回必要）
```

Wasm Runtime を導入することで、ファームウェアを変えずに機能を動的に追加できる。

```text
Embedded Swift Runtime（一度書き込むだけ）
   ↓
Upload Wasm Script（以降はスクリプト差し替えのみ）
   ↓
Dynamic Execution
```

これにより以下が実現できる。

- 後から機能追加
- OTA スクリプト更新
- サンドボックス化による安全な実行
- プラグイン的拡張
- Scriptable Device 化

---

## 最終的に実現するシステム

iPhone アプリから Wasm バイナリを Raspberry Pi Pico へ無線転送し、
Pico 上の Embedded Swift Runtime がそれを動的に実行して GPIO / OLED / センサーを制御する。

```text
iPhone App
   │
   │ BLE / Wi-Fi（Wasm バイナリ転送）
   ▼
Raspberry Pi Pico 2 (RP2350)
   │
   │ Embedded Swift Runtime
   │   ├── Wasm Binary Parser
   │   ├── Wasm Interpreter
   │   │     ├── Stack Machine
   │   │     ├── Linear Memory
   │   │     └── Validation
   │   └── Host Function Layer
   │         ├── GPIO
   │         ├── OLED
   │         └── Sensor
   ▼
ハードウェア制御
```

---

## 成果物一覧

### 1. Wasm バイナリパーサー

Wasm バイナリフォーマット（`.wasm`）を解析するライブラリ。

- LEB128 デコード
- Section パース（Type / Function / Code / Export）
- Opcode デコード
- Embedded Swift 制約（動的アロケーション最小化）に対応

### 2. Wasm インタプリタ

解析した Wasm モジュールを実行する Stack Machine ベースのインタプリタ。

- Operand Stack / Call Stack / Frame 管理
- 対応命令セット: i32 系演算・制御フロー・関数呼び出し（MVP サブセット）
- Type Validation（実行前の静的検証）
- Linear Memory（境界チェック付き）

### 3. Host Function Layer

Wasm から Pico のハードウェアを操作するための API ブリッジ。

| Host API | 機能 |
|----------|------|
| `digitalWrite(pin, value)` | GPIO 出力制御 |
| `digitalRead(pin)` | GPIO 入力読み取り |
| `sleep(ms)` | 待機 |
| `oledDrawText(x, y, text)` | OLED 表示 |

### 4. Embedded Swift Runtime（Pico 上で動作）

上記コンポーネントを統合し、Raspberry Pi Pico 2 (RP2350) 上で動作するファームウェア。

- Wasm モジュールのロード・実行・アンロード
- 複数 Wasm アプリの動的切り替え
- メモリ制約対応（Fixed-size / Arena Allocator）

### 5. iOS コントローラーアプリ

iPhone から Pico を操作するための Swift 製 iOS アプリ。

- BLE または Wi-Fi 経由での Wasm バイナリ転送
- Runtime ログのリアルタイム表示
- Wasm スクリプト管理
- OLED プレビュー・デバイスモニター

---

## 成功ライン

| レベル | 達成条件 |
|--------|----------|
| **最低成功ライン** | Pico 上で Wasm を実行し、Wasm から GPIO を制御できる |
| **中間成功ライン** | iPhone から BLE 経由で Wasm をアップロードして実行できる |
| **最終成功ライン** | 複数 Wasm アプリを動的に切り替えられる Scriptable Device として動作する |

---

## 将来的な拡張（スコープ外）

本プロジェクトでは対象外だが、発展的な方向性として以下を想定している。

- **WASI サブセット**: 標準的な Wasm システムインターフェースへの対応
- **Bytecode 最適化**: Predecode / Threaded Interpreter による高速化
- **Component Model**: Wasm Component Model の研究・実験
- **Mini Scheduler**: 複数 Wasm タスクの簡易スケジューリング
