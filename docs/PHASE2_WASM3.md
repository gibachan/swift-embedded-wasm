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

## 調査内容

### Runtime 構造

Wasm3 の階層構造を把握する。

```text
Environment
  └ Runtime
      └ Module
          └ Function
```

- `Environment`: グローバル設定・アロケーター
- `Runtime`: 実行コンテキスト・スタック・メモリ
- `Module`: Wasm バイナリ 1 ファイルに対応
- `Function`: 各関数の定義・バイトコード

### Interpreter Loop

Opcode ディスパッチの仕組みを調査する。

```c
switch(opcode) {
  case i32_const: ...
  case i32_add:   ...
}
```

Wasm3 は `switch` ではなく **computed goto**（GCC 拡張）を使って高速化している点も注目。

### Host Function Binding

C 関数を Wasm の Host Function として登録する仕組みを調査する。

```c
m3_LinkRawFunction(module, "env", "digitalWrite", "v(ii)", &fn_digitalWrite);
```

シグネチャ文字列（`"v(ii)"` = void(int, int)）の設計が参考になる。

### Linear Memory 管理

- メモリの確保・解放方法
- 境界チェックの実装
- Sandbox 境界の保証方法

### Stack Machine

- Operand Stack の構造
- Call Stack・Frame の管理方法
- ローカル変数の扱い

---

## 成果物

調査結果は以下にまとめる。

- Runtime 構造メモ（階層・ライフサイクル）
- Opcode 実行フローメモ
- Memory 管理メモ
- Swift への設計転用ポイントまとめ

---

## 成功基準

- [ ] Environment → Runtime → Module → Function の階層を説明できる
- [ ] Opcode ディスパッチループの仕組みを説明できる
- [ ] Host Function の登録・呼び出しフローを追える
- [ ] Linear Memory の境界チェック実装を読み解ける
