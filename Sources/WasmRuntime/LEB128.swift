// LEB128 variable-length integer decoder used in the Wasm binary format
//
// Design notes:
//   - No Foundation dependency (compatible with Embedded Swift)
//   - Input is abstracted via the ByteStream protocol (inspired by WasmKit's design)
//   - Typed throws (Swift 6) make the error type explicit
//   - @inlinable / @inline(__always) inline hot paths
//
// Reference:
//   https://webassembly.github.io/spec/core/binary/values.html#integers

enum LEB128Error: Error, Equatable {
  // Value exceeds the bit width of the target type (e.g., extra non-zero bits in the 5th byte for UInt32)
  case overflow
  // Wasm spec violation: redundant encoding (unnecessary trailing bytes present)
  case integerRepresentationTooLong
  // Byte stream ended prematurely
  case insufficientBytes
}

// MARK: - ByteStream

/// Abstraction for reading bytes one at a time.
/// Protocol abstraction allows swapping the implementation for zero-copy buffer reads.
protocol ByteStream {
  mutating func consume() throws(LEB128Error) -> UInt8
}

/// ByteStream implementation backed by UnsafeBufferPointer.
///
/// Usable without heap allocation in Embedded Swift environments.
/// The caller is responsible for managing the buffer's lifetime.
struct BufferStream {
  private let buffer: UnsafeBufferPointer<UInt8>
  private(set) var offset: Int

  init(_ buffer: UnsafeBufferPointer<UInt8>, offset: Int = 0) {
    self.buffer = buffer
    self.offset = offset
  }

  var isExhausted: Bool { offset >= buffer.count }
}

extension BufferStream: ByteStream {
  @inline(__always)
  mutating func consume() throws(LEB128Error) -> UInt8 {
    guard offset < buffer.count else { throw .insufficientBytes }
    defer { offset += 1 }
    return buffer[offset]
  }
}

// MARK: - ULEB128

/// Decodes an unsigned LEB128-encoded integer.
///
/// Supported types: UInt32, UInt64 (types used in the Wasm binary format)
///
/// Format:
///   The lower 7 bits of each byte carry data; the MSB (0x80) is a continuation flag.
///   Terminates at the byte where the continuation flag is 0.
///
/// Errors:
///   - integerRepresentationTooLong: non-zero bits beyond the type's bit width, or too many continuation bytes
///   - insufficientBytes: byte stream ended prematurely
func decodeULEB128<T: FixedWidthInteger & UnsignedInteger, S: ByteStream>(
  from stream: inout S
) throws(LEB128Error) -> T {
  let firstByte = try stream.consume()
  var result = T(firstByte & 0x7F)

  // Fast path: single-byte value (0...127), the most common case in Wasm
  guard firstByte & 0x80 != 0 else { return result }

  var shift: UInt = 7
  while true {
    let byte = try stream.consume()
    let slice = T(byte & 0x7F)
    let nextShift = shift + 7

    // Reached the type's bit width: this byte must not carry bits that overflow the type
    if nextShift >= UInt(T.bitWidth) {
      guard (byte >> (UInt(T.bitWidth) - shift)) == 0 else {
        throw .integerRepresentationTooLong
      }
      result |= slice << shift
      // Continuation bit set here means there is a 6th+ byte, which exceeds the maximum.
      guard byte & 0x80 == 0 else { throw .integerRepresentationTooLong }
      return result
    }

    result |= slice << shift
    if byte & 0x80 == 0 {
      return result
    }
    shift = nextShift
  }
}

// MARK: - SLEB128

/// Decodes a signed LEB128-encoded integer.
///
/// Supported types: Int32, Int64 (types used in the Wasm binary format)
///
/// Format:
///   The lower 7 bits of each byte carry data; the MSB is a continuation flag.
///   Bit 6 (0x40) of the final byte is the sign bit.
///   Sign-extends if the value is narrower than the type's bit width.
///
/// Errors:
///   - overflow: excess bits do not match the sign extension (value does not fit in the type)
///   - integerRepresentationTooLong: too many continuation bytes
///   - insufficientBytes: byte stream ended prematurely
///
/// Implementation note:
///   Left-shifting signed integers can trap, so &<< (overflow shift) is used.
///   Example: Int32(0x78) &<< 28 yields 0x80000000, which would trap with the regular << operator.
func decodeSLEB128<T: FixedWidthInteger & SignedInteger, S: ByteStream>(
  from stream: inout S
) throws(LEB128Error) -> T {
  var result: T = 0
  var shift = 0
  var byte: UInt8 = 0

  while true {
    byte = try stream.consume()

    // A continuation byte past the type's bit width is a spec violation
    if shift + 7 > T.bitWidth {
      guard byte & 0x80 == 0 else { throw .integerRepresentationTooLong }

      // Verify that the excess bits (those that don't fit in the type) match the sign extension.
      //
      // Technique using Int8 arithmetic right shift (from WasmKit):
      //   Shift byte left by 1 to discard the continuation bit and move bit 6 to the sign position.
      //   Arithmetic right shift as Int8 propagates the sign bit.
      //   A result of 0 (positive sign extension) or -1 (negative sign extension) means the excess bits are valid.
      let remainingBitWidth = T.bitWidth - shift
      let signAndDiscardingBits = Int8(bitPattern: byte << 1) >> remainingBitWidth
      guard signAndDiscardingBits == 0 || signAndDiscardingBits == -1 else {
        throw .overflow
      }

      result |= T(byte & 0x7F) &<< shift
      return result
    }

    result |= T(byte & 0x7F) &<< shift
    shift += 7

    if byte & 0x80 == 0 { break }
  }

  // Sign extension: if bit 6 of the final byte is 1, set all bits from shift onward to 1
  if shift < T.bitWidth && byte & 0x40 != 0 {
    result |= ~T(0) &<< shift
  }

  return result
}
