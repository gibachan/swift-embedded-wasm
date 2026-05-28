import Testing

@testable import WasmRuntime

// MARK: - Helpers

private func makeStream(_ bytes: [UInt8]) -> BufferStream {
  // For tests: since UnsafeBufferPointer cannot be held outside withUnsafeBufferPointer,
  // we copy the bytes into an UnsafeMutableBufferPointer that we manage ourselves.
  // (In real Embedded environments, a static buffer or linker section would be passed directly.)
  let ptr = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
  _ = ptr.initialize(from: bytes)
  return BufferStream(UnsafeBufferPointer(ptr))
}

private func decodeU32(_ bytes: [UInt8]) throws -> UInt32 {
  var stream = makeStream(bytes)
  return try decodeULEB128(from: &stream)
}

private func decodeU64(_ bytes: [UInt8]) throws -> UInt64 {
  var stream = makeStream(bytes)
  return try decodeULEB128(from: &stream)
}

private func decodeI32(_ bytes: [UInt8]) throws -> Int32 {
  var stream = makeStream(bytes)
  return try decodeSLEB128(from: &stream)
}

private func decodeI64(_ bytes: [UInt8]) throws -> Int64 {
  var stream = makeStream(bytes)
  return try decodeSLEB128(from: &stream)
}

// MARK: - ULEB128 Tests

@Suite("ULEB128 decode")
struct ULEB128Tests {

  // MARK: UInt32

  @Test func zero() throws {
    #expect(try decodeU32([0x00]) == 0)
  }

  @Test func one() throws {
    #expect(try decodeU32([0x01]) == 1)
  }

  @Test func maxSingleByte() throws {
    // 127 = 0x7F: no continuation flag
    #expect(try decodeU32([0x7F]) == 127)
  }

  @Test func firstMultiByte() throws {
    // 128 = [0x80, 0x01]: smallest multi-byte value
    #expect(try decodeU32([0x80, 0x01]) == 128)
  }

  @Test func typicalValue() throws {
    // 300 = [0xAC, 0x02]
    // 300 = 0b1_0010_1100
    // Group1: 0b010_1100 = 0x2C | 0x80 = 0xAC
    // Group2: 0b000_0010 = 0x02
    #expect(try decodeU32([0xAC, 0x02]) == 300)
  }

  @Test func uint32Max() throws {
    // UInt32.max = 4294967295 = [0xFF, 0xFF, 0xFF, 0xFF, 0x0F]
    #expect(try decodeU32([0xFF, 0xFF, 0xFF, 0xFF, 0x0F]) == UInt32.max)
  }

  @Test func uint64Max() throws {
    // UInt64.max = [0xFF x 9, 0x01]
    #expect(
      try decodeU64([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        == UInt64.max
    )
  }

  // MARK: Byte consumption

  @Test func consumesOnlyNeededBytes() throws {
    // A 2-byte value followed by an extra byte: only 2 bytes should be consumed
    var stream = makeStream([0x80, 0x01, 0xFF])
    let value: UInt32 = try decodeULEB128(from: &stream)
    #expect(value == 128)
    #expect(stream.offset == 2)
  }

  // MARK: Error cases

  @Test func tooLongForUInt32() throws {
    // Non-zero excess bits in the 5th byte
    #expect(throws: LEB128Error.integerRepresentationTooLong) {
      try decodeU32([0x80, 0x80, 0x80, 0x80, 0x10])
    }
  }

  @Test func continuationBitOnFinalByte() throws {
    // Continuation flag set in the 5th byte (redundant encoding)
    #expect(throws: LEB128Error.integerRepresentationTooLong) {
      try decodeU32([0x80, 0x80, 0x80, 0x80, 0x8F])
    }
  }

  @Test func insufficientBytes() throws {
    // Stream ends while continuation flag is still set
    #expect(throws: LEB128Error.insufficientBytes) {
      try decodeU32([0x80])
    }
  }

  @Test func emptyBytes() throws {
    #expect(throws: LEB128Error.insufficientBytes) {
      try decodeU32([])
    }
  }
}

// MARK: - SLEB128 Tests

@Suite("SLEB128 decode")
struct SLEB128Tests {

  // MARK: Int32

  @Test func zero() throws {
    #expect(try decodeI32([0x00]) == 0)
  }

  @Test func positiveOne() throws {
    #expect(try decodeI32([0x01]) == 1)
  }

  @Test func negativeOne() throws {
    // -1 = [0x7F]: bit6=1 → sign-extended to all 1s
    #expect(try decodeI32([0x7F]) == -1)
  }

  @Test func negativeSixtyFour() throws {
    // -64 = [0x40]: bit6=1 → sign extension
    #expect(try decodeI32([0x40]) == -64)
  }

  @Test func positiveSixtyThree() throws {
    // 63 = [0x3F]: bit6=0 → no sign extension
    #expect(try decodeI32([0x3F]) == 63)
  }

  @Test func positiveOneTwoSeven() throws {
    // 127: bit6=1 so a single byte would decode as -1.
    // 127 must be encoded as 2 bytes: [0xFF, 0x00].
    #expect(try decodeI32([0xFF, 0x00]) == 127)
  }

  @Test func negativeOneTwoEight() throws {
    // -128 = [0x80, 0x7F]
    #expect(try decodeI32([0x80, 0x7F]) == -128)
  }

  @Test func positiveTwoFiftySix() throws {
    // 128 = [0x80, 0x01]
    #expect(try decodeI32([0x80, 0x01]) == 128)
  }

  @Test func int32Max() throws {
    // Int32.max = 2147483647 = [0xFF, 0xFF, 0xFF, 0xFF, 0x07]
    #expect(try decodeI32([0xFF, 0xFF, 0xFF, 0xFF, 0x07]) == Int32.max)
  }

  @Test func int32Min() throws {
    // Int32.min = -2147483648 = [0x80, 0x80, 0x80, 0x80, 0x78]
    #expect(try decodeI32([0x80, 0x80, 0x80, 0x80, 0x78]) == Int32.min)
  }

  // MARK: Int64

  @Test func int64Max() throws {
    // Int64.max = [0xFF x 8, 0xFF, 0x00]
    #expect(
      try decodeI64([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        == Int64.max
    )
  }

  @Test func int64Min() throws {
    // Int64.min = [0x80 x 9, 0x7F]
    #expect(
      try decodeI64([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7F])
        == Int64.min
    )
  }

  // MARK: Byte consumption

  @Test func consumesOnlyNeededBytes() throws {
    var stream = makeStream([0x7F, 0xFF])
    let value: Int32 = try decodeSLEB128(from: &stream)
    #expect(value == -1)
    #expect(stream.offset == 1)
  }

  // MARK: Error cases

  @Test func overflowInt32() throws {
    // [0xFF, 0xFF, 0xFF, 0xFF, 0x08]: 5th byte does not match sign extension
    #expect(throws: LEB128Error.overflow) {
      try decodeI32([0xFF, 0xFF, 0xFF, 0xFF, 0x08])
    }
  }

  @Test func tooLongInt32() throws {
    // Continuation flag set in the 5th byte
    #expect(throws: LEB128Error.integerRepresentationTooLong) {
      try decodeI32([0x80, 0x80, 0x80, 0x80, 0x80, 0x00])
    }
  }

  @Test func insufficientBytes() throws {
    #expect(throws: LEB128Error.insufficientBytes) {
      try decodeI32([0x80])
    }
  }
}
