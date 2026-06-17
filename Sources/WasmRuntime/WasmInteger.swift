// MARK: - WasmInteger protocol

/// Protocol that unifies UInt32 (i32) and UInt64 (i64) for generic arithmetic and bitwise
/// operations in the interpreter.
///
/// Embedded Swift compiles generic functions constrained by this protocol via
/// monomorphization (static dispatch), so there is zero runtime cost compared with
/// writing the i32 and i64 cases separately.
///
/// `fromValue` / `toValue` connect the unsigned bit-pattern types to the `Value` enum,
/// which stores i32/i64 as their signed counterparts (Int32/Int64) following the Wasm
/// convention that the integer types are uninterpreted bit patterns at rest on the stack.
///
/// Note: `@inlinable` is not required here because all call sites are within the same
/// module.  If the module is ever split, add `@inlinable` to all conformances and
/// the helpers that call `fromValue`/`toValue`.
protocol WasmInteger: FixedWidthInteger & UnsignedInteger {
  associatedtype Signed: FixedWidthInteger & SignedInteger
  init(bitPattern: Signed)

  /// Reinterpret the unsigned bit-pattern of self as its signed counterpart.
  /// Mirrors `Int32(bitPattern: UInt32)` / `Int64(bitPattern: UInt64)`.
  func toSigned() -> Signed

  /// Reinterpret a signed value's bit-pattern as its unsigned counterpart.
  /// Mirrors `UInt32(bitPattern: Int32)` / `UInt64(bitPattern: Int64)`.
  static func fromSigned(_ s: Signed) -> Self

  /// Extract the bit-pattern from a `Value` stack slot, or throw `.typeMismatch`.
  static func fromValue(_ v: Value) throws(WasmError) -> Self

  /// Wrap the bit-pattern back into the appropriate `Value` variant.
  func toValue() -> Value
}

extension UInt32: WasmInteger {
  typealias Signed = Int32

  @inline(__always) func toSigned() -> Int32 { Int32(bitPattern: self) }
  @inline(__always) static func fromSigned(_ s: Int32) -> UInt32 { UInt32(bitPattern: s) }

  @inline(__always)
  static func fromValue(_ v: Value) throws(WasmError) -> UInt32 {
    guard case .i32(let s) = v else { throw WasmError.typeMismatch }
    return UInt32(bitPattern: s)
  }

  @inline(__always)
  func toValue() -> Value { .i32(Int32(bitPattern: self)) }
}

extension UInt64: WasmInteger {
  typealias Signed = Int64

  @inline(__always) func toSigned() -> Int64 { Int64(bitPattern: self) }
  @inline(__always) static func fromSigned(_ s: Int64) -> UInt64 { UInt64(bitPattern: s) }

  @inline(__always)
  static func fromValue(_ v: Value) throws(WasmError) -> UInt64 {
    guard case .i64(let s) = v else { throw WasmError.typeMismatch }
    return UInt64(bitPattern: s)
  }

  @inline(__always)
  func toValue() -> Value { .i64(Int64(bitPattern: self)) }
}
