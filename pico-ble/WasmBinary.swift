// i32-add.wasm のバイナリ（45 バイト）をタプルとして Flash に配置する。
//
// Embedded Swift では動的な [UInt8] は使えないため、固定長タプルを使う。
// タプルはメモリ上で要素が連続するため、withUnsafeBytes(of:) で
// UnsafeRawBufferPointer を取り出してパーサーに渡せる。
//
// バイト列の更新方法:
//   $ xxd -i Tests/wasm/i32-add.wasm
// の出力を参考に手動で書き換える。

// (module
//   (func (export "i32-add") (param i32 i32) (result i32)
//     local.get 0  ;; 0x20 0x00
//     local.get 1  ;; 0x20 0x01
//     i32.add      ;; 0x6a
//   )
// )
var i32AddWasm: (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // magic + version
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // type section
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // func + export section (1)
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // export section (2): "i32-add"
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // code section (1)
    UInt8, UInt8, UInt8, UInt8, UInt8                        // code section (2)
) = (
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x0b, 0x01,
    0x07, 0x69, 0x33, 0x32, 0x2d, 0x61, 0x64, 0x64,
    0x00, 0x00, 0x0a, 0x09, 0x01, 0x07, 0x00, 0x20,
    0x00, 0x20, 0x01, 0x6a, 0x0b
)
let i32AddWasmLen: Int = 45
