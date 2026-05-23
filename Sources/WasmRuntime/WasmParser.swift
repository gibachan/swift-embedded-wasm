// Wasm バイナリパーサー
//
// Wasm バイナリは「セクション」の列で構成される。
// 各セクションは [id: u8][size: u32(leb128)][content] の形式。
// パーサーは必要なセクションだけ読み取り、残りはスキップする。
//
// 参照: https://webassembly.github.io/spec/core/binary/modules.html

public struct WasmParser {
    private var stream: BufferStream

    public init(_ buffer: UnsafeBufferPointer<UInt8>) {
        self.stream = BufferStream(buffer)
    }

    // MARK: - Public

    public mutating func parse() throws(WasmError) -> WasmModule {
        try validateHeader()

        var types: [FunctionType] = []
        var functions: [UInt32] = []
        var exports: [Export] = []
        var code: [FunctionBody] = []

        while !stream.isExhausted {
            let id = try readByte()
            let size = try readU32()

            switch id {
            case 1:  types     = try parseTypeSection()
            case 3:  functions = try parseFunctionSection()
            case 7:  exports   = try parseExportSection()
            case 10: code      = try parseCodeSection()
            default:
                // 未知のセクションはサイズ分スキップ（Wasm 仕様: 拡張性のため必須）
                for _ in 0..<Int(size) { _ = try readByte() }
            }
        }

        return WasmModule(types: types, functions: functions, exports: exports, code: code)
    }

    // MARK: - Header

    private mutating func validateHeader() throws(WasmError) {
        let magic: [UInt8] = [try readByte(), try readByte(), try readByte(), try readByte()]
        guard magic == wasmMagic else { throw .invalidMagic }

        let version: [UInt8] = [try readByte(), try readByte(), try readByte(), try readByte()]
        guard version == wasmVersion else { throw .invalidVersion }
    }

    // MARK: - Section Parsers

    /// Type section (id=1): 関数シグネチャの配列
    ///
    /// 形式: [count] ([0x60][params][results])*
    private mutating func parseTypeSection() throws(WasmError) -> [FunctionType] {
        let count = try readU32()
        var types: [FunctionType] = []
        for _ in 0..<count {
            // 0x60 は functype を示すマーカーバイト
            let marker = try readByte()
            guard marker == 0x60 else { throw .invalidValueType(marker) }

            let paramCount = try readU32()
            var params: [ValueType] = []
            for _ in 0..<paramCount { params.append(try readValueType()) }

            let resultCount = try readU32()
            var results: [ValueType] = []
            for _ in 0..<resultCount { results.append(try readValueType()) }

            types.append(FunctionType(params: params, results: results))
        }
        return types
    }

    /// Function section (id=3): 各関数が参照する type index の配列
    private mutating func parseFunctionSection() throws(WasmError) -> [UInt32] {
        let count = try readU32()
        var indices: [UInt32] = []
        for _ in 0..<count { indices.append(try readU32()) }
        return indices
    }

    /// Export section (id=7): 外部公開するシンボルの配列
    ///
    /// 形式: [count] ([name_len][name_bytes][kind][index])*
    private mutating func parseExportSection() throws(WasmError) -> [Export] {
        let count = try readU32()
        var exports: [Export] = []
        for _ in 0..<count {
            let nameLen = try readU32()
            var nameBytes: [UInt8] = []
            for _ in 0..<Int(nameLen) { nameBytes.append(try readByte()) }
            let name = String(decoding: nameBytes, as: UTF8.self)

            let kindByte = try readByte()
            guard let kind = ExportKind(rawValue: kindByte) else {
                throw .invalidExportKind(kindByte)
            }

            let index = try readU32()
            exports.append(Export(name: name, kind: kind, index: index))
        }
        return exports
    }

    /// Code section (id=10): 関数本体の配列
    ///
    /// 形式: [count] ([body_size][local_decls][instructions... end])*
    ///
    /// local_decls は (count, type) のペアで圧縮されている。
    /// 例: "3 個の i32 と 1 個の i64" → [(3, i32), (1, i64)]
    private mutating func parseCodeSection() throws(WasmError) -> [FunctionBody] {
        let count = try readU32()
        var bodies: [FunctionBody] = []
        for _ in 0..<count {
            _ = try readU32()  // body_size: このインタプリタでは使わない

            let localDeclCount = try readU32()
            var locals: [ValueType] = []
            for _ in 0..<localDeclCount {
                let n = try readU32()
                let vt = try readValueType()
                for _ in 0..<n { locals.append(vt) }
            }

            var instructions: [Instruction] = []
            loop: while true {
                let opcode = try readByte()
                switch opcode {
                case 0x20:  // local.get
                    instructions.append(.localGet(try readU32()))
                case 0x6A:  // i32.add
                    instructions.append(.i32Add)
                case 0x0B:  // end
                    instructions.append(.end)
                    break loop
                default:
                    throw .invalidInstruction(opcode)
                }
            }

            bodies.append(FunctionBody(locals: locals, instructions: instructions))
        }
        return bodies
    }

    // MARK: - Primitives

    @inline(__always)
    private mutating func readByte() throws(WasmError) -> UInt8 {
        do {
            return try stream.consume()
        } catch {
            throw .unexpectedEnd
        }
    }

    @inline(__always)
    private mutating func readU32() throws(WasmError) -> UInt32 {
        do {
            return try decodeULEB128(from: &stream)
        } catch {
            throw .leb128Error(error)
        }
    }

    private mutating func readValueType() throws(WasmError) -> ValueType {
        let byte = try readByte()
        guard let vt = ValueType(rawValue: byte) else { throw .invalidValueType(byte) }
        return vt
    }
}
