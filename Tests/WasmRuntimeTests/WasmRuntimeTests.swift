import Testing
import WasmRuntime

@Test func wasmMagicBytes() {
    #expect(wasmMagic == [0x00, 0x61, 0x73, 0x6D])
}

@Test func wasmVersionBytes() {
    #expect(wasmVersion == [0x01, 0x00, 0x00, 0x00])
}
