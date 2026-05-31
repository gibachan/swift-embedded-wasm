# TODO — 未実装項目一覧

---

## Phase 1 — Embedded Swift 開発環境

ビルドツールチェーンのセットアップ・Embedded Swift コンパイル・BLE ファームウェアリンクはすでに確認済み（`make compile` / `make build` が通る）。
残っているのは実機での動作確認のみ。

- [ ] **UART 経由でログが出力されることを確認する**

  Pico SDK の `stdio_init_all()` + `printf()` を使い、`"Hello from Embedded Swift\n"` 程度の文字列を UART（USB CDC）経由でホスト PC に出力する。
  シリアルモニター（`screen` / `minicom` など）で受信できれば確認完了。
  これが動けば「Embedded Swift コードが Pico 上で実際に実行されている」ことの最初の実証になる。

---

## Phase 2 — Wasm バイナリパーサー（Embedded フェーズ向け）

macOS フェーズのパーサーは完了済み。以下は Embedded Swift 環境（Pico）へ移植する際に必要な作業。
動的アロケーション（`Array<T>`）を排除し、固定サイズのデータ構造に置き換えることが目的。

- [ ] **Code Section をゼロコピー化する**

  現在の実装ではパース時にすべての命令を `Instruction` enum の配列に展開し `FunctionBody` として保持している。
  Embedded フェーズではこの配列アロケーションが問題になるため、バイト範囲だけを記録する `FunctionHandle` に変更する。

  ```swift
  // 現在（macOS フェーズ）
  struct FunctionBody {
      let locals: [ValueType]
      let instructions: [Instruction]  // パース時に全命令を展開・アロケート
  }

  // 目標（Embedded フェーズ）
  struct FunctionHandle {
      let codeOffset: UInt32  // Wasm バイナリ内のバイトコード開始位置
      let codeSize: UInt32    // バイトコードのバイト数
      let localCount: UInt32  // ローカル変数の個数
  }
  ```

  インタプリタ側の実行ループも変更が必要で、`[Instruction]` を事前ロードするのではなく、
  `BinaryReader` を使って実行しながら逐次デコードする方式（wasm3 と同じ lazy decode 方式）に移行する。
  これにより、モジュールロード時のメモリ消費を大幅に削減できる。

- [ ] **動的配列を排除するため固定上限 `WasmLimits` を設ける**

  現在は `WasmModule` の各フィールドが `[FunctionType]` / `[UInt32]` / `[Export]` などの動的配列になっている。
  Embedded フェーズでは `malloc` が使えないため、すべてを固定サイズのバッファに置き換える必要がある。

  ```swift
  // 上限定数の例
  enum WasmLimits {
      static let maxTypes     = 64   // 関数シグネチャの最大数
      static let maxFunctions = 64   // 関数の最大数
      static let maxImports   = 32   // インポートの最大数
      static let maxExports   = 32   // エクスポートの最大数
      static let maxGlobals   = 32   // グローバル変数の最大数
      static let maxTables    = 4    // テーブルの最大数
      static let maxMemories  = 1    // メモリの最大数（Wasm MVP は 1 のみ）
      static let maxElements  = 16   // element segment の最大数
      static let maxData      = 16   // data segment の最大数
  }
  ```

  `[FunctionType]` → `(FunctionType, FunctionType, ...)` のような固定長タプル、
  または `UnsafeBufferPointer` を使ったスタティックバッファに変更する。
  上限値は Pico 上での典型的なユースケース（数 KB 程度の Wasm バイナリ）に合わせて調整する。

---

## Phase 3 — Wasm インタプリタ（Embedded フェーズ向け）

macOS フェーズのインタプリタは完了済み（spectest 23,547 pass）。
以下は Embedded フェーズへの移行時に修正・置き換えが必要な箇所。

- [ ] **32 ビットターゲットでの実効アドレス計算を修正する**

  現在のメモリ命令（load/store）では、実効アドレスを以下のように計算している。

  ```swift
  // 現在（macOS では動作するが、32 ビット環境で unsafe）
  let ea = Int(UInt32(bitPattern: addr)) &+ Int(offset)
  ```

  macOS（64 ビット）では `Int` が 64 ビット幅のためオーバーフローしないが、
  Pico（32 ビット、`Int` が 32 ビット幅）では `addr + offset` が `UInt32.max` を超えた場合に
  オーバーフローが発生し、不正なアドレスへのアクセスになる可能性がある。

  ```swift
  // 修正後（Embedded フェーズ向け）
  let ea = UInt64(UInt32(bitPattern: addr)) + UInt64(offset)
  guard ea + UInt64(accessSize) <= UInt64(memory.count) else {
      throw WasmError.memoryAccessOutOfBounds
  }
  ```

  `UInt64` で中間計算することで 32 ビット環境でも正しく境界チェックができる。
  影響範囲は `WasmInterpreter.swift` 内のすべての load/store 命令（約 25 箇所）。

- [ ] **`Array<T>` を固定サイズバッファに置き換える**

  インタプリタが実行時に使用する動的配列を固定長バッファに変更する。
  対象と置き換え方針は以下の通り。

  | 対象フィールド | 現在 | Embedded 向け置き換え |
  |---|---|---|
  | `valueStack` | `[Value]` | 固定長配列 + top インデックス（例: 最大深さ 256） |
  | `callStack` | `[CallFrame]` | 固定長配列 + depth カウンタ（例: 最大深さ 64） |
  | `CallFrame.locals` | `[Value]` | スタック上の固定スロット（最大ローカル数 128 等） |
  | `tables` | `[[Value]]` | 固定長バッファ（テーブル最大サイズ 256 等） |
  | `droppedDataSegments` | `[Bool]` | 固定長ビットマップ |
  | `droppedElementSegments` | `[Bool]` | 固定長ビットマップ |

  macOS フェーズでは `Array` のまま動作確認を続け、
  Embedded フェーズへの移行時に段階的に置き換える。

---

## Phase 4 — Raspberry Pi Pico への移植・動作確認

Embedded Swift でのコンパイル（`armv7em-none-none-eabi`）およびリンク（BLE ファームウェア生成）は確認済み。
以下の作業を経て、実機上で Wasm を実行できる状態にする。

### 動的アロケーション排除

Phase 2〜3 の作業（`FunctionHandle` 化・`WasmLimits` 導入・固定バッファ化）を実機向けに適用する。
Pico では `malloc` が原則使えないため（Pico SDK は `malloc` を提供するが Embedded Swift の制約として排除する方針）、
すべての動的確保をコンパイル時固定サイズのバッファに置き換える必要がある。

- [ ] **`ValueStack` を固定サイズバッファ + インデックス管理に置き換える**

  最大スタック深さを定数で決め（例: 256 要素）、`top` インデックスで管理する。
  スタックオーバーフロー時は `WasmError.stackOverflow` を throw する。

  ```swift
  struct ValueStack {
      var storage: (Value, Value, ...) // 固定長タプルまたは UnsafeBufferPointer
      var top: Int = 0
  }
  ```

- [ ] **`CallStack` / `CallFrame.locals` をスタック上の固定配列に置き換える**

  コールスタックの最大深さを定数で決め（例: 64 フレーム）、固定長バッファで管理する。
  各フレームのローカル変数も固定スロット数（例: 128 変数）に制限する。
  関数呼び出しが上限を超えた場合は `WasmError.stackOverflow` を throw する。

- [ ] **`WasmModule` の動的フィールドを固定長バッファに置き換える**

  `Phase 2` で定義する `WasmLimits` を使い、`types` / `functions` / `exports` / `imports` /
  `globals` / `tables` / `memories` / `elements` / `data` の各フィールドを固定長に変更する。

- [ ] **Arena Allocator を導入してモジュールロード時のアロケーションを削減する**

  Pico の SRAM から大きなバッファを一括確保し、モジュールロード中のデータをそこに積み上げる。
  個別の `malloc`/`free` を繰り返すより断片化が起きず、組み込みに適したパターン。

  ```
  [     Arena バッファ（例: SRAM の 64KB 分）     ]
   ↑使用済み↑ ↑ここから次のデータを確保
  ```

### Host Function 実装

Wasm から Pico のペリフェラルを制御するためのホスト関数を実装する。
Embedded Swift ではクロージャのヒープアロケーションが使えないため、
`@convention(c)` 関数ポインタ + 静的テーブルで登録する。

- [ ] **`digitalWrite(pin: i32, val: i32) -> void` — GPIO 出力**

  Pico SDK の `gpio_init()` + `gpio_set_dir()` + `gpio_put()` を呼び出す。
  `pin` は GPIO ピン番号（0〜29）、`val` は 0（LOW）/ 1（HIGH）。
  Wasm 側からは `(import "env" "digitalWrite" (func (param i32 i32)))` でインポートする。

- [ ] **`digitalRead(pin: i32) -> i32` — GPIO 入力**

  Pico SDK の `gpio_get()` を呼び出し、ピンの状態を i32 で返す。
  Wasm 側からは `(import "env" "digitalRead" (func (param i32) (result i32)))` でインポートする。

- [ ] **`sleep(ms: i32) -> void` — 待機**

  Pico SDK の `sleep_ms()` を呼び出す。
  Wasm から `sleep(1000)` を呼べば 1 秒待機できる。

- [ ] **（拡張）`oledDrawText(x: i32, y: i32, ptr: i32) -> void` — OLED 表示**

  Wasm の Linear Memory 上の文字列ポインタを受け取り、
  SSD1306 等の OLED ディスプレイに I2C 経由で描画する。
  `ptr` は Linear Memory 上のオフセット（null 終端の ASCII 文字列を想定）。

### 実機動作確認

- [ ] **Wasm から `i32.add` を実行し UART に結果を出力する**

  以下のような最小の Wasm 関数をターゲットにする。

  ```wat
  (module
    (func (export "add") (param i32 i32) (result i32)
      local.get 0
      local.get 1
      i32.add))
  ```

  `WasmInterpreter.callExport("add", args: [.i32(3), .i32(4)])` を呼び出し、
  戻り値 `7` が返ること・UART に `"result: 7\n"` が出力されることを確認する。

### サイズ・RAM 最適化

- [ ] **LTO（Link-Time Optimization）を有効化してバイナリサイズを削減する**

  現状の BLE ファームウェアは `pico-ble.uf2` で 968 KB（実バイナリ約 484 KB）。
  wasm3（C）が約 64 KB、WAMR が 100〜300 KB であることを考えると差がある。
  `CMakeLists.txt` に `set_property(TARGET ... PROPERTY INTERPROCEDURAL_OPTIMIZATION TRUE)` を追加し、
  削減量を測定する。命令セットの削除（`#if EMBEDDED` で SIMD 等を除外）も併用する。

- [ ] **実機での RAM 使用量を測定し、SRAM に収まることを確認する**

  RP2350 の SRAM は 520 KB、RP2040 は 264 KB。
  Wasm 実行時の RAM 使用量の内訳は以下を想定。

  | 用途 | 想定サイズ |
  |---|---|
  | Wasm Linear Memory（1 ページ） | 64 KB |
  | インタプリタ ValueStack | 〜4 KB（256 要素 × 16 バイト） |
  | インタプリタ CallStack | 〜8 KB（64 フレーム × 128 バイト） |
  | WasmModule（固定バッファ） | 〜8 KB |
  | BLE スタック（CYW43） | 〜50 KB |
  | Pico SDK / システム | 〜20 KB |
  | **合計（概算）** | **〜154 KB** |

  `pico-ble.elf.map` でシンボルごとのサイズを確認し、予算内に収まっているか検証する。
  RP2040 でも動作させたい場合はより厳しい削減が必要。

---

## Phase 5 — iOS 連携

未着手。Phase 4 の実機動作確認（少なくとも LED 点滅まで）が完了してから着手する。

BLE 通信には Pico W 内蔵の CYW43439（Wi-Fi / BLE コンボチップ）を使用する。
iOS アプリは SwiftUI + CoreBluetooth で実装する。

### BLE プロトコル設計

- [ ] **Wasm バイナリ転送用の BLE GATT サービス・キャラクタリスティックを設計する**

  Wasm バイナリは数 KB 程度を想定しており、BLE の MTU（最大 512 バイト）に合わせて
  チャンク転送する仕組みが必要になる。
  設計案:

  ```
  Service UUID: (プロジェクト固有の UUID)
    Characteristic: WasmBinary (Write Without Response)
      → バイナリデータをチャンク転送（先頭パケットに総サイズを含める）
    Characteristic: Control (Write)
      → コマンド送信（"RUN" / "RESET" など）
    Characteristic: Log (Notify)
      → Pico からの UART ログをリアルタイム通知
    Characteristic: Status (Read / Notify)
      → 転送進捗・実行状態（IDLE / RECEIVING / RUNNING / ERROR）
  ```

- [ ] **ログ出力用の Notification キャラクタリスティックを設計する**

  Pico 側で UART に書き出すログを BLE Notification として iOS に転送する。
  UART → リングバッファ → BLE Notification という流れで実装する。
  MTU サイズ（20〜512 バイト）に合わせてログ行を分割・結合する。

- [ ] **転送完了・実行開始のハンドシェイクプロトコルを設計する**

  バイナリ転送中の破損・中断を検出するため、CRC チェックサムを最終パケットに含める。
  Pico 側が転送完了を確認後、Control キャラクタリスティックへの "RUN" コマンドで実行開始する。

### 必須機能（iOS アプリ）

- [ ] **iOS アプリから `.wasm` ファイルを選択して Pico へ BLE 送信できる**

  iOS のファイルアプリ連携（`UIDocumentPickerViewController`）で `.wasm` ファイルを選択し、
  CoreBluetooth を使って Pico へ分割転送する。転送中はプログレスバーを表示する。

- [ ] **転送した Wasm が Pico 上で即時実行される**

  転送完了後に "RUN" コマンドを送り、Pico 側が `WasmInterpreter` でモジュールをロード・実行する。
  実行開始の通知（Status Notification）を iOS アプリで受け取り、UI に反映する。

- [ ] **Pico の実行ログを iOS アプリでリアルタイム表示できる**

  Log Notification を受信するたびに SwiftUI の `ScrollView` にテキストを追加する。
  CoreBluetooth の `centralManager(_:didUpdateValueFor:)` デリゲートで受け取り、
  `@MainActor` でバインドされた ViewModel に渡す。

- [ ] **異なる Wasm を再転送して Pico の動作が切り替わる**

  "RESET" コマンドで実行中のインタプリタを停止し、新しい Wasm バイナリを受け付ける状態に戻す。
  Pico 側で `WasmInterpreter` を再初期化し、新しいモジュールをロードして実行する。

### 拡張機能（任意）

- [ ] **複数の Wasm バイナリを iOS アプリ内で保存・管理・切り替えできる**

  SwiftData または FileManager を使い、転送済みバイナリをアプリのドキュメントフォルダに保存する。
  リスト表示・削除・再送信ができる管理画面を実装する。

- [ ] **OLED 表示内容を iOS アプリでミラーリングできる**

  Pico 側が OLED のフレームバッファ（128×64 ビット = 1 KB）を BLE Notification で定期送信し、
  iOS アプリが `Canvas` または `UIImage` でリアルタイム描画する。

- [ ] **Pico の CPU 負荷・メモリ使用量をモニタリングできる**

  Wasm 実行中のインタプリタから命令カウンタ・スタック使用量・メモリ使用量を定期的に取得し、
  BLE Notification で iOS に送信する。iOS アプリでグラフ表示（Swift Charts）する。
