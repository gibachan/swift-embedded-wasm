# Phase 1 — Embedded Swift 開発環境構築

## 目的

Embedded Swift の開発環境を整え、Raspberry Pi Pico への書き込みと基本動作を確認する。
クロスコンパイルや組み込み特有の制約に慣れることが主な目的。

---

## 実装内容

- Embedded Swift toolchain のセットアップ
- Raspberry Pi Pico 2 (RP2350) へのファームウェア書き込み
- UART 経由のログ出力確認
- GPIO 制御（LED 点滅）

---

## 学習ポイント

### クロスコンパイルとは

通常の Swift コンパイルは、コンパイルするマシン（macOS）上で動く実行ファイルを生成する。
クロスコンパイルでは、**別のアーキテクチャ・OS 向け**のバイナリを生成する。

```text
macOS (arm64) でコンパイル
   ↓
RP2350 (Cortex-M33, thumbv8m) 向けバイナリを生成
```

ターゲットトリプルを指定することでコンパイラに対象アーキテクチャを伝える。

### Embedded Swift の制約

通常の Swift ランタイムは以下に依存する。

- Foundation
- Swift 標準ライブラリ（全体）
- Objective-C ランタイム
- OS のメモリアロケーター

Embedded Swift ではこれらが使えない（または制限される）。使えるのは：

- 基本的な値型（Int, Bool, struct, enum）
- 演算子・制御フロー
- 一部のプロトコル（Comparable など）

`Array` や `String` のような動的アロケーションを伴う型は原則使用不可。

### メモリ制約

RP2350 のリソース：

| リソース | 容量 |
|----------|------|
| Flash | 2MB（外部） |
| SRAM | 520KB |

スタックサイズも厳しく管理する必要がある。

### Pico SDK

Raspberry Pi 公式の C/C++ SDK。GPIO / UART / I2C / SPI などのペリフェラルを抽象化する。
Embedded Swift から Pico SDK の C 関数を呼び出すことでハードウェアを制御する。

---

## 成功基準

- [ ] Embedded Swift toolchain でビルドが通る
- [ ] Pico に書き込んで LED が点滅する
- [ ] UART でログが出力される
