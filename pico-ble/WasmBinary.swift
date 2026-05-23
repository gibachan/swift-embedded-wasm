// blink-loop.wasm binary (89 bytes) stored as a fixed-size tuple.
//
// Embedded Swift cannot use dynamic [UInt8], so a fixed-size tuple is used.
// Tuples are contiguous in memory, so withUnsafeBytes(of:) gives a
// UnsafeRawBufferPointer that can be passed directly to the parser.
//
// To regenerate after editing blink-loop.wat:
//   $ wat2wasm Tests/WasmRuntimeTests/wasm/blink-loop.wat \
//              -o Tests/WasmRuntimeTests/wasm/blink-loop.wasm
//   $ xxd -i Tests/WasmRuntimeTests/wasm/blink-loop.wasm

// (module
//   (import "env" "blink" (func $blink))
//   (func (export "blink_loop") (param $count i32)
//     ;; loops $count times, calling $blink on each iteration
//   )
// )
var blinkLoopWasm: (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  //  [0- 7] magic + version
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  //  [8-15] type section
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // [16-23] type section (cont) + import section
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // [24-31] import section: "env"."blink"
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // [32-39] func + export section
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // [40-47] export: "blink_loop"
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // [48-55] code section
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // [56-63] code section (cont)
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // [64-71] code section (cont)
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // [72-79] code section (cont)
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,  // [80-87] code section (cont)
    UInt8                                                     // [88]
) = (
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x08, 0x02, 0x60, 0x00, 0x00, 0x60, 0x01,
    0x7f, 0x00, 0x02, 0x0d, 0x01, 0x03, 0x65, 0x6e,
    0x76, 0x05, 0x62, 0x6c, 0x69, 0x6e, 0x6b, 0x00,
    0x00, 0x03, 0x02, 0x01, 0x01, 0x07, 0x0e, 0x01,
    0x0a, 0x62, 0x6c, 0x69, 0x6e, 0x6b, 0x5f, 0x6c,
    0x6f, 0x6f, 0x70, 0x00, 0x01, 0x0a, 0x22, 0x01,
    0x20, 0x01, 0x01, 0x7f, 0x41, 0x00, 0x21, 0x01,
    0x03, 0x40, 0x02, 0x40, 0x20, 0x01, 0x20, 0x00,
    0x4e, 0x0d, 0x00, 0x10, 0x00, 0x20, 0x01, 0x41,
    0x01, 0x6a, 0x21, 0x01, 0x0c, 0x01, 0x0b, 0x0b,
    0x0b
)
let blinkLoopWasmLen: Int = 89
