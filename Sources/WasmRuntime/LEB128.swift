// Wasm バイナリフォーマットで使われる LEB128 可変長整数デコーダー
//
// 設計方針:
//   - Foundation 不使用（Embedded Swift 対応）
//   - ByteStream プロトコルで入力を抽象化（WasmKit の設計を参考）
//   - 型付き throws (Swift 6) でエラー型を明示
//   - @inlinable / @inline(__always) でホットパスをインライン化
//
// 参照:
//   https://webassembly.github.io/spec/core/binary/values.html#integers

enum LEB128Error: Error, Equatable {
  // 値が型のビット幅を超える（例: UInt32 に 5 バイト目に余分なビットがある）
  case overflow
  // Wasm 仕様違反: 冗長なエンコード（末尾に不要バイトが存在する）
  case integerRepresentationTooLong
  // バイト列が途中で終わった
  case insufficientBytes
}

// MARK: - ByteStream

/// バイトを 1 つずつ読み出す抽象。
/// プロトコルで抽象化することで、実装をゼロコピーのバッファ読み出しに差し替えられる。
protocol ByteStream {
  mutating func consume() throws(LEB128Error) -> UInt8
}

/// UnsafeBufferPointer ベースの ByteStream 実装。
///
/// Embedded Swift 環境ではヒープアロケーション不要で使用できる。
/// バッファの生存期間は呼び出し元が管理すること。
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

/// 符号なし整数の LEB128 デコード。
///
/// 対応型: UInt32, UInt64（Wasm バイナリで使用される型）
///
/// フォーマット:
///   各バイトの下位 7 bit がデータ、最上位 bit (0x80) が継続フラグ。
///   継続フラグが 0 のバイトで終端。
///
/// エラー:
///   - integerRepresentationTooLong: 型ビット幅を超えるビットが非ゼロ、または継続バイトが多すぎる
///   - insufficientBytes: バイト列が途中で終わった
func decodeULEB128<T: FixedWidthInteger & UnsignedInteger, S: ByteStream>(
  from stream: inout S
) throws(LEB128Error) -> T {
  let firstByte = try stream.consume()
  var result = T(firstByte & 0x7F)
  
  // 高速パス: 1 バイトで完結（値が 0...127 の場合、Wasm で最頻出）
  guard firstByte & 0x80 != 0 else { return result }
  
  var shift: UInt = 7
  while true {
    let byte = try stream.consume()
    let slice = T(byte & 0x7F)
    let nextShift = shift + 7
    
    // 型ビット幅に達した: このバイトは型に収まらないビットを持ってはいけない
    if nextShift >= UInt(T.bitWidth) {
      guard (byte >> (UInt(T.bitWidth) - shift)) == 0 else {
        throw .integerRepresentationTooLong
      }
      result |= slice << shift
      guard byte & 0x80 == 0 else { throw .integerRepresentationTooLong }
      return result
    }
    
    result |= slice << shift
    guard byte & 0x80 != 0 else { return result }
    shift = nextShift
  }
}

// MARK: - SLEB128

/// 符号付き整数の LEB128 デコード。
///
/// 対応型: Int32, Int64（Wasm バイナリで使用される型）
///
/// フォーマット:
///   各バイトの下位 7 bit がデータ、最上位 bit が継続フラグ。
///   最終バイトの bit 6 (0x40) が符号ビット。
///   型のビット幅に満たない場合は符号拡張する。
///
/// エラー:
///   - overflow: 余剰ビットが符号拡張と一致しない（値が型に収まらない）
///   - integerRepresentationTooLong: 継続バイトが多すぎる
///   - insufficientBytes: バイト列が途中で終わった
///
/// 実装メモ:
///   符号付き整数の左シフトはトラップになる可能性があるため &<< (overflow shift) を使用する。
///   例: Int32(0x78) &<< 28 は 0x80000000 となり、通常の << ではオーバーフロートラップになる。
func decodeSLEB128<T: FixedWidthInteger & SignedInteger, S: ByteStream>(
  from stream: inout S
) throws(LEB128Error) -> T {
  var result: T = 0
  var shift = 0
  var byte: UInt8 = 0
  
  while true {
    byte = try stream.consume()
    
    // 型ビット幅を超えた部分に継続バイトがあれば仕様違反
    if shift + 7 > T.bitWidth {
      guard byte & 0x80 == 0 else { throw .integerRepresentationTooLong }
      
      // 余剰ビット（型に収まらない部分）が符号拡張と一致するか検査する。
      //
      // Int8 の算術右シフトを使った検査（WasmKit より）:
      //   byte << 1 で継続ビットを除去し、bit6 を符号位置に移す。
      //   Int8 として算術右シフトすると符号ビットが伝播する。
      //   結果が 0 (正の符号拡張) または -1 (負の符号拡張) であれば余剰ビットは正当。
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
  
  // 符号拡張: 最終バイトの bit 6 が 1 なら、shift 以上の全ビットを 1 にする
  if shift < T.bitWidth && byte & 0x40 != 0 {
    result |= ~T(0) &<< shift
  }
  
  return result
}
