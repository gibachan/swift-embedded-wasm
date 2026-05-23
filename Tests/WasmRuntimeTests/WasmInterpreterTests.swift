import Testing
import WasmRuntime

// i32-add.wasm のバイナリをそのまま埋め込む
// xxd wasm/i32-add.wasm で確認した 45 バイト
private let i32AddWasm: [UInt8] = [
    // magic + version
    0x00, 0x61, 0x73, 0x6d,
    0x01, 0x00, 0x00, 0x00,
    // Type section (id=1, size=7): (i32, i32) -> i32
    0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f,
    // Function section (id=3, size=2): 関数0 → type 0
    0x03, 0x02, 0x01, 0x00,
    // Export section (id=7, size=11): "i32-add" → func 0
    0x07, 0x0b, 0x01, 0x07, 0x69, 0x33, 0x32, 0x2d, 0x61, 0x64, 0x64, 0x00, 0x00,
    // Code section (id=10, size=9): local.get 0, local.get 1, i32.add, end
    0x0a, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b,
]

private func parseModule(_ bytes: [UInt8]) throws -> WasmModule {
    try bytes.withUnsafeBufferPointer { buffer in
        var parser = WasmParser(buffer)
        return try parser.parse()
    }
}

// MARK: - Parser Tests

@Suite("WasmParser")
struct WasmParserTests {
    @Test func parsesTypeSection() throws {
        let module = try parseModule(i32AddWasm)
        #expect(module.types.count == 1)
        #expect(module.types[0].params == [.i32, .i32])
        #expect(module.types[0].results == [.i32])
    }

    @Test func parsesFunctionSection() throws {
        let module = try parseModule(i32AddWasm)
        #expect(module.functions == [0])
    }

    @Test func parsesExportSection() throws {
        let module = try parseModule(i32AddWasm)
        #expect(module.exports.count == 1)
        #expect(module.exports[0].nameBytes == Array("i32-add".utf8))
        #expect(module.exports[0].kind == .function)
        #expect(module.exports[0].index == 0)
    }

    @Test func parsesCodeSection() throws {
        let module = try parseModule(i32AddWasm)
        #expect(module.code.count == 1)
        #expect(module.code[0].locals.isEmpty)
        #expect(module.code[0].instructions.count == 4)
    }

    @Test func rejectsInvalidMagic() throws {
        var bad = i32AddWasm
        bad[0] = 0xFF
        #expect(throws: WasmError.invalidMagic) {
            try parseModule(bad)
        }
    }
}

// MARK: - Interpreter Tests

@Suite("WasmInterpreter")
struct WasmInterpreterTests {
    // テストでは nameBytes を直接組み立てる。
    // "i32-add".utf8 のバイト変換は照合ではなくテストデータ準備のためなので問題ない。
    private let i32AddName = Array("i32-add".utf8)

    @Test func i32Add() throws {
        let module = try parseModule(i32AddWasm)
        let interp = WasmInterpreter(module: module)

        let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(3), .i32(4)])

        #expect(result == [.i32(7)])
    }

    @Test func i32AddWithNegatives() throws {
        let module = try parseModule(i32AddWasm)
        let interp = WasmInterpreter(module: module)

        let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(-10), .i32(3)])
        #expect(result == [.i32(-7)])
    }

    @Test func i32AddWrapsAround() throws {
        let module = try parseModule(i32AddWasm)
        let interp = WasmInterpreter(module: module)

        // Wasm の i32.add はオーバーフロー時にラップアラウンドする
        let result = try interp.callExport(nameBytes: i32AddName, args: [.i32(Int32.max), .i32(1)])
        #expect(result == [.i32(Int32.min)])
    }

    @Test func throwsOnUnknownExport() throws {
        let module = try parseModule(i32AddWasm)
        let interp = WasmInterpreter(module: module)

        #expect(throws: WasmError.functionNotFound) {
            try interp.callExport(nameBytes: Array("nonexistent".utf8), args: [])
        }
    }

    @Test func throwsOnArgumentCountMismatch() throws {
        let module = try parseModule(i32AddWasm)
        let interp = WasmInterpreter(module: module)

        #expect(throws: WasmError.argumentCountMismatch) {
            try interp.callExport(nameBytes: i32AddName, args: [.i32(1)])
        }
    }
}
