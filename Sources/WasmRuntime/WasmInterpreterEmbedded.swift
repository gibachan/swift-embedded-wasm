// On-the-fly interpreter for the Wasm stack machine.
//
// Decodes opcodes directly from module.rawBytes as execution proceeds, using the
// pre-computed jump table (FunctionHandle.jumpTable) for O(1) control-flow target
// resolution. This eliminates per-call [Instruction] allocation.
//
// Locals are stored on the shared value stack starting at localBase, which means zero
// extra heap allocation per call beyond what the value stack already holds.

// MARK: - Embedded BSS global for WasmModule

// WasmModule (~2–5 KB on Embedded after the Fixed64_FunctionHandle / FixedJumpTable_JumpEntry
// size reduction) is too large to allocate as a local variable on the RP2040's 4 KB main stack.
// Declaring it as a module-level global places the storage in BSS (zero-initialised at boot),
// consuming no stack space.
//
// Usage:
//   _embeddedModule = try parser.parse()            // fill from BLE receive buffer
//   var interp = try WasmInterpreter(moduleRef: &_embeddedModule, ...)
//
// Safety: _embeddedModule outlives every WasmInterpreter — it is only reset at the next
// executeReceivedWasm() call, by which time the previous interpreter has been dropped.
#if hasFeature(Embedded)
  // nonisolated(unsafe): Embedded Swift has no concurrency; single-threaded bare-metal use only.
  nonisolated(unsafe) var _embeddedModule = WasmModule.empty
  // WasmInterpreter (~1.2 KB after FlatTableStorage reduction) is stored in BSS to avoid placing
  // it on the RP2040's 4 KB main stack.  executeReceivedWasm overwrites this before every use.
  nonisolated(unsafe) var _embeddedInterp = WasmInterpreter.empty
#endif

// MARK: - Interpreter stack type aliases

// These type aliases allow dispatchEmbedded / handleEmbeddedBranch to use a single
// set of inout parameter types that resolve to the fixed-size buffer types on Embedded
// and to plain Arrays on macOS.
//
// API compatibility notes:
//   - ValueStack / [Value]:          append(_:), removeLast() -> Value, count, isEmpty,
//                                    subscript[Int], removeSubrange(Int), removeSubrange(n...),
//                                    removeLast(k:), last (non-optional / forced below)
//   - CallStack / [EmbeddedFrame]:   append(_:), removeLast(), count, isEmpty, subscript[Int]
//   - FlatTableStorage / [[Value]]:  subscript[Int, Int], count(ofTable:), tableCount,
//                                    grow(_:by:fillValue:max:); [[Value]] gains these via extension
//   - Fixed32_Value / [Value]:       subscript[Int] get/set, count
//
// The one API divergence is `last`: [Value].last is Optional; ValueStack.last is not.
// All uses of valueStack.last in dispatchEmbedded use valueStack[valueStack.count-1]
// instead to work identically for both types.
// EmbeddedValueStack is [Value] on macOS and ValueStack on Embedded.
// ValueStack (~4 KB inout parameter) causes Swift debug-build stack frames of ~1.4 MB
// inside dispatchEmbedded (a very large function with many withUnsafeBytes closures).
// 512 KB test-thread stacks overflow immediately.  Using [Value] on macOS avoids this.
//
// Why [Value] / [EmbeddedFrame] on macOS:
// Both ValueStack (~4 KB) and CallStack (~3.5 KB on macOS) are large fixed-size structs
// that use withUnsafeBytes inside their subscript accessors.  When passed as inout
// parameters to dispatchEmbedded — a very large function with hundreds of case bodies —
// the Swift debug-build compiler reserves stack space for every live variable across the
// entire function body, producing a stack frame of 900 KB – 1.4 MB.  Swift Testing
// threads have a 512 KB stack, so the function crashes immediately.
//
// On Embedded targets (bare-metal or RTOS), the interpreter entry point runs on a
// thread sized for this use; the fixed-size buffers are required because malloc may be
// unavailable.
//
// On macOS the plain-Array alternatives avoid the oversized stack frame while keeping
// the same dispatch logic unchanged.  The single #if is the minimum conditional
// compilation needed to allow a shared dispatchEmbedded implementation.
//
// LabelStack uses a separate, independent #if inside its own struct body (Approach A).
// That conditional determines whether each EmbeddedFrame.labels is a fixed tuple or a
// [Label].  It does NOT affect the type aliases here.
//
// Conditional compilation for the macOS/Embedded split is confined to:
//   1. LabelStack internals (WasmInterpreter.swift) — one #if hasFeature(Embedded)
//   2. EmbeddedValueStack / EmbeddedCallStack / EmbeddedTableStorage type aliases (this file)
//   3. valueStack / frames initialisation in runIterativeEmbedded (this file)
//   4. return statement in runIterativeEmbedded (toArray() vs identity)
//   5. hostFunctions field and init (Fixed32_HostFunctionPtr vs [HostFunction] — fundamental type difference)
//   6. tables field and init (FlatTableStorage vs [[Value]] — ~16 KB struct causes stack overflow in debug builds)
// globals uses Fixed32_Value on both platforms (512 bytes — safe for all thread stacks; no #if needed).
#if hasFeature(Embedded)
  typealias EmbeddedValueStack = ValueStack
  typealias EmbeddedCallStack = CallStack
#else
  // TODO: Embedded Phase 5 — unify to ValueStack / CallStack once dispatchEmbedded
  // stack usage is reduced (e.g. by splitting into sub-functions).
  typealias EmbeddedValueStack = [Value]
  typealias EmbeddedCallStack = [EmbeddedFrame]
#endif
// EmbeddedTableStorage uses FlatTableStorage on Embedded (no malloc) and [[Value]] on macOS.
// FlatTableStorage is ~16 KB; passing it as inout to the large dispatchEmbedded function causes
// Swift debug-build stack frames of several MB, overflowing 512 KB Swift Testing thread stacks.
// [[Value]] on macOS avoids this while keeping the same FlatTableStorage API via the shim below.
// dispatchEmbedded uses the FlatTableStorage API exclusively: tables[ti, ei], tables.count(ofTable:),
// tables.tableCount, tables.grow(_:by:fillValue:max:).
#if hasFeature(Embedded)
  typealias EmbeddedTableStorage = FlatTableStorage
#else
  typealias EmbeddedTableStorage = [[Value]]
#endif
// EmbeddedGlobalStorage is Fixed32_Value on both platforms — no #if needed.
// Fixed32_Value is ~512 bytes (4 rows × 8 Value slots) and safe as an inout parameter on all stacks.
typealias EmbeddedGlobalStorage = Fixed32_Value

// MARK: - [[Value]] FlatTableStorage compatibility shim (macOS only)

// On macOS, EmbeddedTableStorage is [[Value]].  dispatchEmbedded uses the FlatTableStorage API
// (two-index subscript, count(ofTable:), tableCount, grow) — so [[Value]] must expose the same
// interface.  This extension is compiled only for non-Embedded builds; the real FlatTableStorage
// provides the same API natively on Embedded.
#if !hasFeature(Embedded)
  extension Array where Element == [Value] {
    /// Two-index subscript mirroring FlatTableStorage.subscript(ti:ei:).
    subscript(ti: Int, ei: Int) -> Value {
      get { self[ti][ei] }
      set { self[ti][ei] = newValue }
    }

    /// Element count for table `ti`.
    func count(ofTable ti: Int) -> Int { self[ti].count }

    /// Number of live tables (mirrors FlatTableStorage.tableCount).
    var tableCount: Int { count }

    /// Grow table `ti` by `delta` slots filled with `fillValue`.
    /// Returns the previous element count, or -1 if growth exceeds the declared max limit.
    /// Note: WasmLimits.maxTableElements is NOT enforced here — macOS uses heap-allocated
    /// [[Value]] so memory is not a hard constraint; only the module-declared max applies.
    mutating func grow(_ ti: Int, by delta: Int, fillValue: Value, max: Int?) -> Int32 {
      let old = self[ti].count
      let newSize = old + delta
      if let m = max, newSize > m { return -1 }
      // Overflow guard: if delta alone overflows Int, growth is impossible.
      guard delta <= Int.max - old else { return -1 }
      self[ti].append(contentsOf: [Value](repeating: fillValue, count: delta))
      return Int32(old)
    }
  }
#endif

// MARK: - [EmbeddedFrame] CallStack compatibility shim (macOS only)

// On macOS, EmbeddedCallStack is [EmbeddedFrame].  dispatchEmbedded uses the named
// field accessor API added to CallStack (ip(at:), setIp(at:), etc.) — so [EmbeddedFrame]
// must expose the same interface.  This extension is compiled only for non-Embedded builds.
#if !hasFeature(Embedded)
  extension Array where Element == EmbeddedFrame {
    @inline(__always) mutating func ip(at i: Int) -> UInt32 { self[i].ip }
    @inline(__always) mutating func setIp(at i: Int, _ v: UInt32) { self[i].ip = v }
    @inline(__always) mutating func jumpCursor(at i: Int) -> Int { self[i].jumpCursor }
    @inline(__always) mutating func setJumpCursor(at i: Int, _ v: Int) {
      self[i].jumpCursor = v
    }
    @inline(__always) mutating func incrementJumpCursor(at i: Int) {
      self[i].jumpCursor &+= 1
    }
    @inline(__always) mutating func handleIdx(at i: Int) -> Int { self[i].handleIdx }
    @inline(__always) mutating func localBase(at i: Int) -> Int { self[i].localBase }
    @inline(__always) mutating func localCount(at i: Int) -> Int { self[i].localCount }
    @inline(__always) mutating func resultCount(at i: Int) -> Int { self[i].resultCount }
    @inline(__always) mutating func labelsCount(at i: Int) -> Int { self[i].labels.count }
    @inline(__always) mutating func labelsIsEmpty(at i: Int) -> Bool {
      self[i].labels.isEmpty
    }
    @inline(__always) mutating func labelsLast(at i: Int) -> Label { self[i].labels.last }
    @inline(__always) mutating func label(at i: Int, index j: Int) -> Label {
      self[i].labels[j]
    }
    @inline(__always) mutating func appendLabel(at i: Int, _ label: Label) {
      self[i].labels.append(label)
    }
    @inline(__always) @discardableResult mutating func removeLastLabel(at i: Int) -> Label {
      self[i].labels.removeLast()
    }
    @inline(__always) mutating func clearLabels(at i: Int) { self[i].labels.removeAll() }
    @inline(__always) mutating func removeLabels(at i: Int, from j: Int) {
      self[i].labels.removeSubrange(j...)
    }
  }
#endif

// MARK: - BinaryReader

/// Zero-allocation byte reader over a fixed UnsafeBufferPointer<UInt8>.
///
/// Used by the on-the-fly decoder to read opcodes and LEB128 immediates directly
/// from the module's raw binary buffer without any intermediate allocation.
struct BinaryReader {
  let buffer: UnsafeBufferPointer<UInt8>
  var offset: Int

  @inline(__always)
  mutating func readByte() throws(InterpreterError) -> UInt8 {
    guard offset < buffer.count else { throw InterpreterError.unexpectedEnd }
    let b = buffer[offset]
    offset &+= 1
    return b
  }

  /// Unsigned LEB128 → UInt32
  @inline(__always)
  mutating func readU32() throws(InterpreterError) -> UInt32 {
    var result: UInt32 = 0
    var shift: UInt = 0
    while true {
      let byte = try readByte()
      result |= UInt32(byte & 0x7F) << shift
      if byte & 0x80 == 0 { return result }
      shift += 7
      if shift >= 35 { throw InterpreterError.unexpectedEnd }
    }
  }

  /// Signed LEB128 → Int32 (used for i32.const and block type s33)
  @inline(__always)
  mutating func readS32() throws(InterpreterError) -> Int32 {
    var result: Int32 = 0
    var shift = 0
    var byte: UInt8 = 0
    while true {
      byte = try readByte()
      result |= Int32(byte & 0x7F) &<< shift
      shift += 7
      if byte & 0x80 == 0 { break }
      if shift > 35 { throw InterpreterError.unexpectedEnd }
    }
    // Sign extend
    if shift < 32 && (byte & 0x40) != 0 {
      result |= ~Int32(0) &<< shift
    }
    return result
  }

  /// Signed LEB128 → Int64 (used for i64.const)
  @inline(__always)
  mutating func readS64() throws(InterpreterError) -> Int64 {
    var result: Int64 = 0
    var shift = 0
    var byte: UInt8 = 0
    while true {
      byte = try readByte()
      result |= Int64(byte & 0x7F) &<< shift
      shift += 7
      if byte & 0x80 == 0 { break }
      if shift > 70 { throw InterpreterError.unexpectedEnd }
    }
    // Sign extend
    if shift < 64 && (byte & 0x40) != 0 {
      result |= ~Int64(0) &<< shift
    }
    return result
  }

  /// 4-byte little-endian IEEE 754 float (f32.const)
  @inline(__always)
  mutating func readF32() throws(InterpreterError) -> Float {
    let b0 = UInt32(try readByte())
    let b1 = UInt32(try readByte())
    let b2 = UInt32(try readByte())
    let b3 = UInt32(try readByte())
    return Float(bitPattern: b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))
  }

  /// 8-byte little-endian IEEE 754 double (f64.const)
  @inline(__always)
  mutating func readF64() throws(InterpreterError) -> Double {
    let b0 = UInt64(try readByte())
    let b1 = UInt64(try readByte())
    let b2 = UInt64(try readByte())
    let b3 = UInt64(try readByte())
    let b4 = UInt64(try readByte())
    let b5 = UInt64(try readByte())
    let b6 = UInt64(try readByte())
    let b7 = UInt64(try readByte())
    let bits =
      b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) | (b4 << 32) | (b5 << 40) | (b6 << 48)
      | (b7 << 56)
    return Double(bitPattern: bits)
  }

  /// Block type (s33 encoding): negative → value type or void, non-negative → type index
  @inline(__always)
  mutating func readBlockType() throws(InterpreterError) -> BlockType {
    let raw = try readS32()
    if raw >= 0 { return .typeIndex(UInt32(raw)) }
    let byte = UInt8(raw & 0x7F)
    if byte == 0x40 { return .void }
    guard let vt = ValueType(rawValue: byte) else { throw InterpreterError.invalidValueType(byte) }
    return .value(vt)
  }
}

// MARK: - EmbeddedFrame

/// Call frame for the Embedded on-the-fly interpreter.
///
/// Locals are stored on the shared value stack starting at localBase.
/// Parameters are already there (pushed by the caller); additional declared
/// locals are zero-initialised by pushEmbeddedFrame() and appended immediately after.
///
/// ip is an absolute byte offset into module.rawBytes (= WasmModule.rawBytes).
/// jumpCursor is a monotonically-advancing index into FunctionHandle.jumpTable;
/// it is advanced by 1 each time a block/loop/if opcode is decoded, giving O(1)
/// lookup without scanning.
// internal (not private) so that CallStack (defined in WasmInterpreter.swift) can reference
// this type.
struct EmbeddedFrame {
  var ip: UInt32  // absolute byte offset in module.rawBytes
  var jumpCursor: Int  // monotonic index into handle.jumpTable
  let handleIdx: Int  // index into module.code
  let localBase: Int  // index of first local (= first param) on valueStack
  let localCount: Int  // total locals (params + declared); valueStack depth at body start
  let resultCount: Int  // number of return values
  var labels: LabelStack  // Approach A: LabelStack uses [Label] (heap, capacity 32) on macOS,
  // an 8-slot tuple on Embedded — see the doc comment on LabelStack in WasmInterpreter.swift
  // for why these were not unified onto a single capacity.

  /// Zero-value sentinel used to fill uninitialised slots in the fixed-size CallStack buffer.
  static let zero = EmbeddedFrame(
    ip: 0,
    jumpCursor: 0,
    handleIdx: 0,
    localBase: 0,
    localCount: 0,
    resultCount: 0,
    labels: LabelStack())
}

// MARK: - WasmInteger generic helpers

// These free functions are called from dispatchEmbedded case bodies.
// Defining them at module scope (rather than as methods) avoids any `self`-capture
// concern inside the non-mutating dispatchEmbedded.
//
// All functions take an explicit `_: T.Type` as their first parameter so Swift can always
// infer the concrete type T at the call site without relying on closure-parameter types.
// This eliminates ambiguity and removes any need to annotate operator closures.
//
// All functions are @inline(__always) so the compiler folds them into the call site via
// monomorphization, keeping the generated code identical to the hand-written i32/i64
// cases they replace.  No `@inlinable` is needed because all call sites are within the
// same module.

/// Pop two operands of type T, apply binary `op`, push result.
///
/// Used for: add, sub, mul, and, or, xor.
/// `op` is a non-capturing closure (e.g. `{ a, b in a &+ b }`) so it compiles to a
/// static function reference in Embedded Swift — no heap allocation.
@inline(__always)
func intBinaryOp<T: WasmInteger>(
  _ type: T.Type, _ stack: inout EmbeddedValueStack, _ op: (T, T) -> T
)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = try T.fromValue(stack.removeLast())
  let a = try T.fromValue(stack.removeLast())
  stack.append(op(a, b).toValue())
}

/// Pop two operands of type T, apply unsigned comparison `op`, push i32 result (0 or 1).
///
/// Used for: eq, ne, lt_u, gt_u, le_u, ge_u.
@inline(__always)
func intCmpOp<T: WasmInteger>(
  _ type: T.Type, _ stack: inout EmbeddedValueStack, _ op: (T, T) -> Bool
)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = try T.fromValue(stack.removeLast())
  let a = try T.fromValue(stack.removeLast())
  stack.append(.i32(op(a, b) ? 1 : 0))
}

/// Pop two operands, reinterpret as T.Signed, apply signed comparison `op`, push i32 (0/1).
///
/// Used for: lt_s, gt_s, le_s, ge_s.
@inline(__always)
func intSignedCmpOp<T: WasmInteger>(
  _ type: T.Type, _ stack: inout EmbeddedValueStack, _ op: (T.Signed, T.Signed) -> Bool
) throws(InterpreterError) {
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = (try T.fromValue(stack.removeLast())).toSigned()
  let a = (try T.fromValue(stack.removeLast())).toSigned()
  stack.append(.i32(op(a, b) ? 1 : 0))
}

/// eqz: pop T, push i32 1 if zero, else 0.
@inline(__always)
func intEqzOp<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard !stack.isEmpty else { throw InterpreterError.stackUnderflow }
  let a = try T.fromValue(stack.removeLast())
  stack.append(.i32(a == 0 ? 1 : 0))
}

/// clz/ctz/popcnt: pop T, apply count op (returning Int), push T-width result.
///
/// Per Wasm spec, clz/ctz/popcnt on i32 return i32 and on i64 return i64.
@inline(__always)
func intCountOp<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack, _ op: (T) -> Int)
  throws(InterpreterError)
{
  guard !stack.isEmpty else { throw InterpreterError.stackUnderflow }
  let a = try T.fromValue(stack.removeLast())
  stack.append(T(truncatingIfNeeded: op(a)).toValue())
}

/// div_s: signed division; traps on /0 and T.Signed.min / -1.
@inline(__always)
func intDivS<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = (try T.fromValue(stack.removeLast())).toSigned()
  let a = (try T.fromValue(stack.removeLast())).toSigned()
  guard b != 0 else { throw InterpreterError.divisionByZero }
  guard !(a == T.Signed.min && b == -1) else { throw InterpreterError.integerOverflow }
  stack.append(T.fromSigned(a / b).toValue())
}

/// div_u: unsigned division; traps on /0.
@inline(__always)
func intDivU<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = try T.fromValue(stack.removeLast())
  let a = try T.fromValue(stack.removeLast())
  guard b != 0 else { throw InterpreterError.divisionByZero }
  stack.append((a / b).toValue())
}

/// rem_s: signed remainder; traps on /0; returns 0 for T.Signed.min % -1.
@inline(__always)
func intRemS<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = (try T.fromValue(stack.removeLast())).toSigned()
  let a = (try T.fromValue(stack.removeLast())).toSigned()
  guard b != 0 else { throw InterpreterError.divisionByZero }
  let result: T.Signed = a == T.Signed.min && b == -1 ? 0 : a % b
  stack.append(T.fromSigned(result).toValue())
}

/// rem_u: unsigned remainder; traps on /0.
@inline(__always)
func intRemU<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = try T.fromValue(stack.removeLast())
  let a = try T.fromValue(stack.removeLast())
  guard b != 0 else { throw InterpreterError.divisionByZero }
  stack.append((a % b).toValue())
}

/// shl: left shift; shift amount is masked to the bit-width of T.
@inline(__always)
func intShl<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = try T.fromValue(stack.removeLast())
  let a = try T.fromValue(stack.removeLast())
  let shift = b & T(T.bitWidth - 1)
  stack.append((a &<< shift).toValue())
}

/// shr_s: arithmetic (signed) right shift; shift amount masked to bit-width of T.
@inline(__always)
func intShrS<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = try T.fromValue(stack.removeLast())
  let a = (try T.fromValue(stack.removeLast())).toSigned()
  // T.Signed and T have the same bit-width; mask shift to that width.
  let shiftU = b & T(T.bitWidth - 1)
  // Convert the masked shift to T.Signed for the signed right-shift operator.
  // T.Signed.init(exactly:) would be correct but may not exist; use truncatingIfNeeded
  // which is safe because shiftU is already in [0, bitWidth-1].
  let shift = T.Signed(truncatingIfNeeded: shiftU)
  stack.append(T.fromSigned(a >> shift).toValue())
}

/// shr_u: logical (unsigned) right shift; shift amount masked to bit-width of T.
@inline(__always)
func intShrU<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = try T.fromValue(stack.removeLast())
  let a = try T.fromValue(stack.removeLast())
  let shift = b & T(T.bitWidth - 1)
  stack.append((a &>> shift).toValue())
}

/// rotl: left rotation; rotation amount masked to bit-width of T.
@inline(__always)
func intRotl<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = try T.fromValue(stack.removeLast())
  let a = try T.fromValue(stack.removeLast())
  let shift = b & T(T.bitWidth - 1)
  let result = shift == 0 ? a : (a << shift | a >> (T(T.bitWidth) - shift))
  stack.append(result.toValue())
}

/// rotr: right rotation; rotation amount masked to bit-width of T.
@inline(__always)
func intRotr<T: WasmInteger>(_ type: T.Type, _ stack: inout EmbeddedValueStack)
  throws(InterpreterError)
{
  guard stack.count >= 2 else { throw InterpreterError.stackUnderflow }
  let b = try T.fromValue(stack.removeLast())
  let a = try T.fromValue(stack.removeLast())
  let shift = b & T(T.bitWidth - 1)
  let result = shift == 0 ? a : (a >> shift | a << (T(T.bitWidth) - shift))
  stack.append(result.toValue())
}

// MARK: - Embedded global interpreter stacks
//
// On Embedded targets (RP2040 / RP2350), CallStack (~34 KB) and ValueStack (~4 KB) are too large
// to allocate as local variables inside runIterativeEmbedded.  The Pico's main stack is only 4 KB
// by default; placing a 34 KB CallStack there overflows it immediately, producing a silent crash.
//
// The fix: declare these as file-scope globals so the linker places them in BSS (SRAM), not on the
// call stack.  reset() is O(1) — it sets _count = 0 without reinitialising the storage tuples.
// Single-threaded Embedded execution means there is no re-entrancy concern.
//
// This section is hidden from macOS builds (#if hasFeature(Embedded)); macOS uses plain [Value] /
// [EmbeddedFrame] arrays allocated locally, which have negligible overhead.
#if hasFeature(Embedded)
  var _wasmValueStack = ValueStack()
  var _wasmCallStack = CallStack()
  // _runIterativeEmbeddedCore copies `tables` (FlatTableStorage ≈1 KB) and `globals`
  // (Fixed32_Value ≈512 B) to locals so dispatchEmbedded can take them as inout.
  // On the RP2040's 4 KB main stack that leaves no headroom for the
  //   interpreter → dispatch → pushEmbeddedFrame → hostFn → pollingWait → cyw43_arch_poll
  // call chain.  Moving them to BSS reclaims ≈1.5 KB of stack.
  var _execLocalTables = FlatTableStorage()
  var _execLocalGlobals = Fixed32_Value()
#endif

// MARK: - WasmInterpreter Embedded extension

extension WasmInterpreter {

  // MARK: jumpCursorForIp

  /// Binary search: first index in jumpTable where entry.instrOffset >= ip.
  /// Called when ip changes non-sequentially (branch taken, function return, etc.).
  @inline(never) private func jumpCursorForIp(_ ip: UInt32, in jumpTable: FixedJumpTable_JumpEntry)
    -> Int
  {
    var lo = 0
    var hi = jumpTable.count
    while lo < hi {
      let mid = lo &+ (hi &- lo) / 2
      if jumpTable[mid].instrOffset < ip { lo = mid &+ 1 } else { hi = mid }
    }
    return lo
  }

  // MARK: runIterativeEmbedded

  /// Thin entry point: sets up the correct stack storage for each platform, then delegates
  /// to _runIterativeEmbeddedCore.
  ///
  /// On Embedded: uses global-scope ValueStack / CallStack (BSS, not call stack) to avoid a
  /// ~38 KB stack frame that would overflow RP2040's 4 KB main stack.  reset() is O(1).
  /// On macOS: allocates local [Value] / [EmbeddedFrame] arrays (heap, negligible cost).
  mutating func runIterativeEmbedded(
    functionIndex: Int,
    args: [Value],
    fuelLimit: Int = 10_000_000
  ) throws(InterpreterError) -> [Value] {
    #if hasFeature(Embedded)
      _wasmValueStack.reset()
      _wasmCallStack.reset()
      return try _runIterativeEmbeddedCore(
        functionIndex: functionIndex, args: args, fuelLimit: fuelLimit,
        valueStack: &_wasmValueStack, frames: &_wasmCallStack)
    #else
      var valueStack: EmbeddedValueStack = []
      var frames: EmbeddedCallStack = []
      return try _runIterativeEmbeddedCore(
        functionIndex: functionIndex, args: args, fuelLimit: fuelLimit,
        valueStack: &valueStack, frames: &frames)
    #endif
  }

  // MARK: _runIterativeEmbeddedCore

  /// On-the-fly Embedded interpreter.  Replaces the Phase 3 lazy-decode path.
  ///
  /// Value stack layout within a frame:
  ///   [localBase ..< localBase + localCount]  → parameters + declared locals
  ///   [localBase + localCount ...]             → operand stack for this frame
  ///
  /// Mutable interpreter state (memory, globals, tables, dropped segments) is extracted
  /// into local variables and passed as inout to dispatchEmbedded.  Written back to self
  /// via defer before return.
  private mutating func _runIterativeEmbeddedCore(
    functionIndex: Int,
    args: [Value],
    fuelLimit: Int,
    valueStack: inout EmbeddedValueStack,
    frames: inout EmbeddedCallStack
  ) throws(InterpreterError) -> [Value] {
    var fuel = fuelLimit

    var localMemory = memory
    // On Embedded, `globals` (~512 B) and `tables` (~1 KB) are stored in BSS globals
    // instead of stack locals to keep the RP2040's 4 KB main stack from overflowing when
    // the hostFn → pollingWait → cyw43_arch_poll() call chain runs during Wasm execution.
    #if hasFeature(Embedded)
      // Pointer-based copy avoids the 512-byte (globals) and 1,040-byte (tables) stack
      // temporaries that plain assignment would create when both src and dst are value types.
      withUnsafeMutableBytes(of: &globals) { src in
        withUnsafeMutableBytes(of: &_execLocalGlobals) { dst in
          dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
      }
      withUnsafeMutableBytes(of: &tables) { src in
        withUnsafeMutableBytes(of: &_execLocalTables) { dst in
          dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
      }
    #else
      var localGlobals = globals
      var localTables = tables
    #endif
    var localDroppedData = droppedDataSegments
    var localDroppedElem = droppedElementSegments
    var localExecInstr = executedInstructions
    var localPeakValueStack = peakValueStackDepth
    var localPeakCallStack = peakCallStackDepth
    defer {
      memory = localMemory
      #if hasFeature(Embedded)
        withUnsafeMutableBytes(of: &_execLocalGlobals) { src in
          withUnsafeMutableBytes(of: &globals) { dst in
            dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
          }
        }
        withUnsafeMutableBytes(of: &_execLocalTables) { src in
          withUnsafeMutableBytes(of: &tables) { dst in
            dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
          }
        }
      #else
        globals = localGlobals
        tables = localTables
      #endif
      droppedDataSegments = localDroppedData
      droppedElementSegments = localDroppedElem
      executedInstructions = localExecInstr
      peakValueStackDepth = localPeakValueStack
      peakCallStackDepth = localPeakCallStack
    }

    // MARK: embeddedReturn

    /// Pop the current frame, sliding return values down to localBase.
    @inline(__always)
    func embeddedReturn(fi: Int) throws(InterpreterError) {
      let resultCount = frames.resultCount(at: fi)
      let localBase = frames.localBase(at: fi)
      guard valueStack.count >= localBase + resultCount else {
        throw InterpreterError.stackUnderflow
      }
      let src = valueStack.count - resultCount
      for i in 0..<resultCount { valueStack[localBase + i] = valueStack[src + i] }
      valueStack.removeSubrange((localBase + resultCount)...)
      frames.removeLast()
    }

    // MARK: Seed and run

    #if !hasFeature(Embedded)
      // `module` is a `let` stored property, so `&module` cannot be taken directly; a
      // mutable local used to be made here (`var localModule = self.module`) purely to get
      // a WasmModule pointer. That local was a full-value copy of WasmModule, which was
      // negligible (~112 bytes) before the Fixed*_X section buffers were unified onto tuple
      // storage for both platforms (Documentations/hasFeature削除計画.md §5) but is now
      // several KB — large enough that a stack copy risks overflowing Swift Testing's
      // 512 KB worker-thread stack when combined with this function's other locals (this
      // was observed as a real SIGBUS crash during that unification work). Heap-allocating
      // the copy instead keeps the stack frame unchanged; this path never compiles for
      // Embedded (which uses self.moduleRef directly against a BSS global, with no copy).
      let localModulePtr = UnsafeMutablePointer<WasmModule>.allocate(capacity: 1)
      localModulePtr.initialize(to: self.module)
      defer {
        localModulePtr.deinitialize(count: 1)
        localModulePtr.deallocate()
      }
    #endif
    valueStack.append(contentsOf: args)
    #if hasFeature(Embedded)
      try pushEmbeddedFrame(
        self.moduleRef, functionIndex, args.count, &valueStack, &frames, &localMemory)
    #else
      try pushEmbeddedFrame(
        localModulePtr, functionIndex, args.count, &valueStack, &frames, &localMemory)
    #endif
    if valueStack.count > localPeakValueStack { localPeakValueStack = valueStack.count }
    if frames.count > localPeakCallStack { localPeakCallStack = frames.count }

    while !frames.isEmpty {
      let fi = frames.count - 1
      #if hasFeature(Embedded)
        let handle = self.moduleRef.pointee.code[frames.handleIdx(at: fi)]
      #else
        let handle = localModulePtr.pointee.code[frames.handleIdx(at: fi)]
      #endif
      let codeEnd = handle.codeOffset &+ handle.codeSize

      // Frame done when ip reaches (or passes) end of function body
      if frames.ip(at: fi) >= codeEnd {
        try embeddedReturn(fi: fi)
        continue
      }

      fuel -= 1
      if fuel < 0 { throw InterpreterError.executionLimitExceeded }

      // Phase 4 Part A: read the opcode byte and advance ip BEFORE calling dispatchEmbedded.
      //
      // We read the opcode inside withUnsafeBytes (a non-escaping borrow of self.module),
      // store it in a local, then call dispatchEmbedded OUTSIDE the closure.
      // This avoids an exclusivity violation: withUnsafeBytes borrows self (via module),
      // while dispatchEmbedded is mutating and needs exclusive write access to self.
      //
      // In Part B, dispatchEmbedded will also need to read LEB128 immediates.  Those bytes
      // will be extracted here (pre-copied into a small local buffer) so that dispatchEmbedded
      // can work without holding the withUnsafeBytes borrow.
      //
      // ip-commit protocol:
      //   - dispatchEmbedded sets frames.setIp(at: fi, nextIp) before returning for sequential ops.
      //   - For control-flow (br, call, return), dispatchEmbedded overrides ip itself.
      //   - We always pass `nextIp` (the byte offset immediately after the opcode byte) so that
      //     sequential opcodes can commit it with a single assignment.
      var opcode: UInt8 = 0
      var nextIp: UInt32 = frames.ip(at: fi)
      #if hasFeature(Embedded)
        // On Embedded, rawBytes is already UnsafeBufferPointer<UInt8> — use it directly.
        // No closure wrapper needed, so typed throws propagate naturally without the
        // opcodeErr workaround required by the macOS withUnsafeBytes(throws(Never)) path.
        var reader = BinaryReader(
          buffer: self.moduleRef.pointee.rawBytes, offset: Int(frames.ip(at: fi)))
        opcode = try reader.readByte()
        nextIp = UInt32(reader.offset)
      #else
        // On macOS, rawBytes is [UInt8]. withUnsafeBytes closure cannot throw directly
        // (it is typed throws(Never)), so we capture the error in a local and re-throw.
        var opcodeErr: InterpreterError? = nil
        localModulePtr.pointee.rawBytes.withUnsafeBytes { rawBuf throws(Never) in
          let typedBuf = rawBuf.bindMemory(to: UInt8.self)
          var reader = BinaryReader(buffer: typedBuf, offset: Int(frames.ip(at: fi)))
          do throws(InterpreterError) {
            opcode = try reader.readByte()
            nextIp = UInt32(reader.offset)
          } catch {
            opcodeErr = error
          }
        }
        if let e = opcodeErr { throw e }
      #endif

      #if hasFeature(Embedded)
        try dispatchEmbedded(
          moduleRef: self.moduleRef,
          opcode: opcode,
          nextIp: nextIp,
          fi: fi,
          valueStack: &valueStack,
          frames: &frames,
          memory: &localMemory,
          globals: &_execLocalGlobals,
          tables: &_execLocalTables,
          droppedData: &localDroppedData,
          droppedElem: &localDroppedElem,
          execInstr: &localExecInstr)
      #else
        try dispatchEmbedded(
          moduleRef: localModulePtr,
          opcode: opcode,
          nextIp: nextIp,
          fi: fi,
          valueStack: &valueStack,
          frames: &frames,
          memory: &localMemory,
          globals: &localGlobals,
          tables: &localTables,
          droppedData: &localDroppedData,
          droppedElem: &localDroppedElem,
          execInstr: &localExecInstr)
      #endif
      if valueStack.count > localPeakValueStack { localPeakValueStack = valueStack.count }
      if frames.count > localPeakCallStack { localPeakCallStack = frames.count }
    }

    #if hasFeature(Embedded)
      return valueStack.toArray()
    #else
      return valueStack  // [Value] is already [Value]
    #endif
  }

  // MARK: embeddedBlockArity / embeddedLoopBrArity

  /// Returns (brArity, paramCount) for a block/if block type.
  ///
  /// brArity = result count (values carried on br or fall-through exit from the block).
  /// paramCount = parameter count (values already on the stack when the block is entered).
  private func embeddedBlockArity(_ moduleRef: UnsafePointer<WasmModule>, _ bt: BlockType)
    -> (brArity: Int, paramCount: Int)
  {
    switch bt {
    case .void: return (0, 0)
    case .value: return (1, 0)
    case .typeIndex(let i):
      guard Int(i) < moduleRef.pointee.types.count else { return (0, 0) }
      let ft = moduleRef.pointee.types[Int(i)]
      return (ft.results.count, ft.params.count)
    }
  }

  /// Returns the br-arity for a loop block type.
  ///
  /// For loops, br restarts with the loop's input parameters, so brArity == paramCount.
  private func embeddedLoopBrArity(_ moduleRef: UnsafePointer<WasmModule>, _ bt: BlockType) -> Int {
    switch bt {
    case .void: return 0
    case .value: return 0
    case .typeIndex(let i):
      guard Int(i) < moduleRef.pointee.types.count else { return 0 }
      return moduleRef.pointee.types[Int(i)].params.count
    }
  }

  // MARK: pushEmbeddedFrame

  @inline(never) private func pushEmbeddedFrame(
    _ moduleRef: UnsafePointer<WasmModule>,
    _ funcIdx: Int, _ argCount: Int,
    _ valueStack: inout EmbeddedValueStack, _ frames: inout EmbeddedCallStack,
    _ memory: inout UnsafeMutableBufferPointer<UInt8>
  ) throws(InterpreterError) {
    guard valueStack.count >= argCount else { throw InterpreterError.stackUnderflow }
    let importedCount = moduleRef.pointee.importedFunctionCount
    if funcIdx < importedCount {
      let argsStart = valueStack.count - argCount
      #if hasFeature(Embedded)
        let resultCount = moduleRef.pointee.functionType(at: funcIdx).results.count
        precondition(
          resultCount <= 8,
          "HostFunctionPtr: resultCount exceeds 8-slot result buffer")
        // Copy arguments from ValueStack into a temporary allocation so we can pass
        // a contiguous raw pointer to the host function.  ValueStack stores elements in
        // sub-tuple fields which are not guaranteed to be contiguous across fields, so we
        // must copy rather than borrowing valueStack's internal storage directly.
        withUnsafeTemporaryAllocation(of: Value.self, capacity: max(argCount, 1)) { argsBuf in
          for i in 0..<argCount { argsBuf[i] = valueStack[argsStart + i] }
          withUnsafeTemporaryAllocation(of: Value.self, capacity: 8) { resultsBuf in
            let argsRaw: UnsafeRawPointer? =
              argCount > 0 ? UnsafeRawPointer(argsBuf.baseAddress!) : nil
            let resultsRaw: UnsafeMutableRawPointer? =
              resultCount > 0 ? UnsafeMutableRawPointer(resultsBuf.baseAddress!) : nil
            // UnsafeMutableBufferPointer.baseAddress gives direct mutable pointer access —
            // no withUnsafeMutableBytes wrapper needed (and that API doesn't exist on
            // UnsafeMutableBufferPointer<UInt8>).
            let memPtr = memory.baseAddress
            let memLen = Int32(memory.count)
            hostFunctions[funcIdx](argsRaw, Int32(argCount), memPtr, memLen, resultsRaw)
            valueStack.removeLast(argCount)
            for i in 0..<resultCount { valueStack.append(resultsBuf[i]) }
          }
        }
      #else
        var argsSlice: [Value] = []
        for i in argsStart..<(argsStart + argCount) { argsSlice.append(valueStack[i]) }
        // HostFunction takes [UInt8] (macOS public API); convert from UnsafeMutableBufferPointer.
        // TODO: Arena Step 3b — change HostFunction signature to UnsafeBufferPointer<UInt8>.
        let results = hostFunctions[funcIdx](argsSlice, Array(UnsafeBufferPointer(memory)))
        valueStack.removeLast(argCount)
        valueStack.append(contentsOf: results)
      #endif
      return
    }

    let localIdx = funcIdx - importedCount
    guard localIdx < moduleRef.pointee.code.count else { throw InterpreterError.functionNotFound }
    let handle = moduleRef.pointee.code[localIdx]
    let typeIdx = Int(moduleRef.pointee.functions[localIdx])
    let funcType = moduleRef.pointee.types[typeIdx]
    guard argCount == funcType.params.count else { throw InterpreterError.argumentCountMismatch }

    let localBase = valueStack.count - argCount

    // FixedLocals_ValueType does not conform to Sequence; iterate with index.
    for i in 0..<handle.locals.count {
      let vt = handle.locals[i]
      switch vt {
      case .i32: valueStack.append(.i32(0))
      case .i64: valueStack.append(.i64(0))
      case .f32: valueStack.append(.f32(0))
      case .f64: valueStack.append(.f64(0))
      case .funcref: valueStack.append(.funcref(nil))
      case .externref: valueStack.append(.externref(nil))
      }
    }

    let localCount = argCount + handle.locals.count
    frames.append(
      EmbeddedFrame(
        ip: handle.codeOffset,
        jumpCursor: 0,
        handleIdx: localIdx,
        localBase: localBase,
        localCount: localCount,
        resultCount: funcType.results.count,
        labels: LabelStack()))
  }

  // MARK: handleEmbeddedBranch

  @inline(never) private func handleEmbeddedBranch(
    _ moduleRef: UnsafePointer<WasmModule>,
    _ depth: UInt32, _ fi: Int,
    _ valueStack: inout EmbeddedValueStack, _ frames: inout EmbeddedCallStack
  ) throws(InterpreterError) {
    let d = Int(depth)
    let labelCount = frames.labelsCount(at: fi)

    if d >= labelCount {
      let resultCount = frames.resultCount(at: fi)
      let localBase = frames.localBase(at: fi)
      let src = valueStack.count - resultCount
      guard src >= localBase else { throw InterpreterError.stackUnderflow }
      for i in 0..<resultCount { valueStack[localBase + i] = valueStack[src + i] }
      valueStack.removeSubrange((localBase + resultCount)...)
      frames.clearLabels(at: fi)
      let handle = moduleRef.pointee.code[frames.handleIdx(at: fi)]
      frames.setIp(at: fi, handle.codeOffset &+ handle.codeSize)
      return
    }

    let targetIdx = labelCount - 1 - d
    let target = frames.label(at: fi, index: targetIdx)

    let src = valueStack.count - target.brArity
    guard src >= target.stackBase else { throw InterpreterError.stackUnderflow }
    for i in 0..<target.brArity { valueStack[target.stackBase + i] = valueStack[src + i] }
    valueStack.removeSubrange((target.stackBase + target.brArity)...)

    switch target.kind {
    case .loop:
      frames.removeLabels(at: fi, from: targetIdx + 1)
      let newIp = UInt32(target.continuationPc)
      frames.setIp(at: fi, newIp)
      frames.setJumpCursor(
        at: fi,
        jumpCursorForIp(newIp, in: moduleRef.pointee.code[frames.handleIdx(at: fi)].jumpTable))
    case .block, .ifElse:
      frames.removeLabels(at: fi, from: targetIdx)
      let newIp = UInt32(target.continuationPc)
      frames.setIp(at: fi, newIp)
      frames.setJumpCursor(
        at: fi,
        jumpCursorForIp(newIp, in: moduleRef.pointee.code[frames.handleIdx(at: fi)].jumpTable))
    }
  }

  // MARK: dispatchEmbedded

  /// Execute the already-decoded opcode.
  ///
  /// `nextIp` is the byte offset immediately after the opcode byte.  For sequential (non-branch)
  /// instructions, dispatchEmbedded sets frames.setIp(at: fi, nextIp) before returning.
  /// For control-flow instructions, dispatchEmbedded overrides frames.ip(at: fi) with the branch
  /// target directly.
  ///
  /// Immediate bytes are read here using local inline functions that index directly into
  /// module.rawBytes starting at nextIp.  The cursor is local to this method so there is
  /// no borrow conflict with the caller's withUnsafeBytes borrow (which is already released
  /// before dispatchEmbedded is called).
  ///
  // dispatchEmbedded is NOT mutating so that non-mutating method calls to
  // pushEmbeddedFrame / handleEmbeddedBranch do not require a new exclusive write to self.
  // Instructions that mutate interpreter state receive that state as inout parameters.
  private func dispatchEmbedded(
    moduleRef: UnsafePointer<WasmModule>,
    opcode: UInt8,
    nextIp: UInt32,
    fi: Int,
    valueStack: inout EmbeddedValueStack,
    frames: inout EmbeddedCallStack,
    memory: inout UnsafeMutableBufferPointer<UInt8>,
    globals: inout EmbeddedGlobalStorage,
    tables: inout EmbeddedTableStorage,
    droppedData: inout UInt64,
    droppedElem: inout UInt64,
    execInstr: inout UInt64
  ) throws(InterpreterError) {

    // moduleRef is an UnsafePointer to _embeddedModule (BSS global); field accesses via
    // moduleRef.pointee.xxx compile to direct loads — no WasmModule copy on the stack.

    // Cursor for reading LEB128 immediates that follow the opcode byte.
    // Starts at nextIp (the byte immediately after the opcode).
    // Each readXxxLocal() advances cursor in-place.
    var cursor = Int(nextIp)

    execInstr &+= 1

    @inline(__always)
    func readByteLocal() throws(InterpreterError) -> UInt8 {
      guard cursor < moduleRef.pointee.rawBytes.count else { throw InterpreterError.unexpectedEnd }
      let b = moduleRef.pointee.rawBytes[cursor]
      cursor &+= 1
      return b
    }

    @inline(__always)
    func readU32Local() throws(InterpreterError) -> UInt32 {
      var result: UInt32 = 0
      var shift: UInt = 0
      while true {
        let b = try readByteLocal()
        result |= UInt32(b & 0x7F) << shift
        if b & 0x80 == 0 { return result }
        shift += 7
        if shift >= 35 { throw InterpreterError.unexpectedEnd }
      }
    }

    @inline(__always)
    func readS32Local() throws(InterpreterError) -> Int32 {
      var result: Int32 = 0
      var shift = 0
      var byte: UInt8 = 0
      while true {
        byte = try readByteLocal()
        result |= Int32(byte & 0x7F) &<< shift
        shift += 7
        if byte & 0x80 == 0 { break }
        if shift > 35 { throw InterpreterError.unexpectedEnd }
      }
      if shift < 32 && (byte & 0x40) != 0 { result |= ~Int32(0) &<< shift }
      return result
    }

    @inline(__always)
    func readS64Local() throws(InterpreterError) -> Int64 {
      var result: Int64 = 0
      var shift = 0
      var byte: UInt8 = 0
      while true {
        byte = try readByteLocal()
        result |= Int64(byte & 0x7F) &<< shift
        shift += 7
        if byte & 0x80 == 0 { break }
        if shift > 70 { throw InterpreterError.unexpectedEnd }
      }
      if shift < 64 && (byte & 0x40) != 0 { result |= ~Int64(0) &<< shift }
      return result
    }

    @inline(__always)
    func readBlockTypeLocal() throws(InterpreterError) -> BlockType {
      let raw = try readS32Local()
      if raw >= 0 { return .typeIndex(UInt32(raw)) }
      let byte = UInt8(raw & 0x7F)
      if byte == 0x40 { return .void }
      guard let vt = ValueType(rawValue: byte) else {
        throw InterpreterError.invalidValueType(byte)
      }
      return .value(vt)
    }

    // MARK: Opcode dispatch

    switch opcode {

    // MARK: Control — unreachable / nop

    case 0x00:  // unreachable
      throw InterpreterError.unreachableReached

    case 0x01:  // nop
      frames.setIp(at: fi, nextIp)

    // MARK: Control — block (0x02)

    case 0x02:
      let bt = try readBlockTypeLocal()
      let (brArity, paramCount) = embeddedBlockArity(moduleRef, bt)
      let handle = moduleRef.pointee.code[frames.handleIdx(at: fi)]
      // Consume the jump table entry for this block opcode (monotonic cursor).
      // entry.instrOffset == byte position of the 0x02 opcode itself.
      let entry = handle.jumpTable[frames.jumpCursor(at: fi)]
      frames.incrementJumpCursor(at: fi)
      // entry.target1 = byte position of first instruction after blockEnd (br-continuation).
      frames.appendLabel(
        at: fi,
        Label(
          kind: .block,
          stackBase: valueStack.count - paramCount,
          brArity: brArity,
          continuationPc: Int(entry.target1)))
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: Control — loop (0x03)

    case 0x03:
      let bt = try readBlockTypeLocal()
      let loopBrArity = embeddedLoopBrArity(moduleRef, bt)
      let (_, paramCount) = embeddedBlockArity(moduleRef, bt)
      let handle = moduleRef.pointee.code[frames.handleIdx(at: fi)]
      let entry = handle.jumpTable[frames.jumpCursor(at: fi)]
      frames.incrementJumpCursor(at: fi)
      // entry.target1 = byte position of first instruction in the loop body (br restarts here).
      frames.appendLabel(
        at: fi,
        Label(
          kind: .loop,
          stackBase: valueStack.count - paramCount,
          brArity: loopBrArity,
          continuationPc: Int(entry.target1)))
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: Control — if (0x04)

    case 0x04:
      let bt = try readBlockTypeLocal()
      let (brArity, paramCount) = embeddedBlockArity(moduleRef, bt)
      let handle = moduleRef.pointee.code[frames.handleIdx(at: fi)]
      let entry = handle.jumpTable[frames.jumpCursor(at: fi)]
      frames.incrementJumpCursor(at: fi)
      // entry.target1:
      //   with else  → first byte of else body (condition-false jumps here).
      //   no else    → the `end` byte itself (condition-false jumps here so `end` pops the label).
      // entry.target2:
      //   with else  → byte after `end` (br-continuation; handleEmbeddedBranch already popped label).
      //   no else    → byte after `end` (same semantics).
      let continuationPc = Int(entry.target2)
      // The condition sits on top of the stack above any block parameters.
      // Subtract 1 for the condition so stackBase reflects the frame AFTER the condition is popped.
      frames.appendLabel(
        at: fi,
        Label(
          kind: .ifElse,
          stackBase: valueStack.count - paramCount - 1,
          brArity: brArity,
          continuationPc: continuationPc))
      // Pop condition and branch to else-start (or end) if false.
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let cond) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      if cond == 0 {
        // Jump to else clause (or to the end when there is no else).
        let target = entry.target1
        frames.setIp(at: fi, target)
        frames.setJumpCursor(
          at: fi,
          jumpCursorForIp(target, in: moduleRef.pointee.code[frames.handleIdx(at: fi)].jumpTable))
      } else {
        frames.setIp(at: fi, UInt32(cursor))
      }

    // MARK: Control — else (0x05)

    case 0x05:
      // Reached by normal fall-through from the then-body into the else opcode.
      // Jump to the continuation PC stored in the current (if/else) label, then pop it.
      guard !frames.labelsIsEmpty(at: fi) else { throw InterpreterError.stackUnderflow }
      let contPc = UInt32(frames.removeLastLabel(at: fi).continuationPc)
      frames.setIp(at: fi, contPc)
      frames.setJumpCursor(
        at: fi,
        jumpCursorForIp(contPc, in: moduleRef.pointee.code[frames.handleIdx(at: fi)].jumpTable))

    // MARK: Control — end (0x0B)

    case 0x0B:
      if !frames.labelsIsEmpty(at: fi) {
        // Normal fall-through exit from block/loop/if: pop the innermost label.
        frames.removeLastLabel(at: fi)
        frames.setIp(at: fi, nextIp)
      } else {
        // Final end of the function body — signal frame done by setting ip past codeEnd.
        let handle = moduleRef.pointee.code[frames.handleIdx(at: fi)]
        frames.setIp(at: fi, handle.codeOffset &+ handle.codeSize)
      }

    // MARK: Control — br (0x0C)

    case 0x0C:
      let depth = try readU32Local()
      // Set ip past the immediate so that handleEmbeddedBranch can overwrite it correctly
      // for the non-early-return path; early-return sets ip to codeEnd anyway.
      frames.setIp(at: fi, UInt32(cursor))
      try handleEmbeddedBranch(moduleRef, depth, fi, &valueStack, &frames)

    // MARK: Control — br_if (0x0D)

    case 0x0D:
      let depth = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let cond) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      if cond != 0 {
        frames.setIp(at: fi, UInt32(cursor))
        try handleEmbeddedBranch(moduleRef, depth, fi, &valueStack, &frames)
      } else {
        frames.setIp(at: fi, UInt32(cursor))
      }

    // MARK: Control — br_table (0x0E)

    case 0x0E:
      let count = try readU32Local()
      // TODO: Embedded Phase 5 — replace with a stack-allocated fixed-size buffer.
      var targets: [UInt32] = []
      for _ in 0..<count { targets.append(try readU32Local()) }
      let default_ = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let idx) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ui = UInt32(bitPattern: idx)
      let depth = ui < count ? targets[Int(ui)] : default_
      frames.setIp(at: fi, UInt32(cursor))
      try handleEmbeddedBranch(moduleRef, depth, fi, &valueStack, &frames)

    // MARK: Control — return (0x0F)

    case 0x0F:
      let resultCount = frames.resultCount(at: fi)
      let localBase = frames.localBase(at: fi)
      let src = valueStack.count - resultCount
      guard src >= localBase else { throw InterpreterError.stackUnderflow }
      for i in 0..<resultCount { valueStack[localBase + i] = valueStack[src + i] }
      valueStack.removeSubrange((localBase + resultCount)...)
      frames.clearLabels(at: fi)
      let handle = moduleRef.pointee.code[frames.handleIdx(at: fi)]
      frames.setIp(at: fi, handle.codeOffset &+ handle.codeSize)

    // MARK: Control — call (0x10)

    case 0x10:
      let funcIdx = try readU32Local()
      let funcType = moduleRef.pointee.functionType(at: Int(funcIdx))
      let argCount = funcType.params.count
      guard valueStack.count >= argCount else { throw InterpreterError.stackUnderflow }
      frames.setIp(at: fi, UInt32(cursor))
      try pushEmbeddedFrame(moduleRef, Int(funcIdx), argCount, &valueStack, &frames, &memory)

    // MARK: Control — call_indirect (0x11)

    case 0x11:
      let typeIdx = try readU32Local()
      let tableIdxOp = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let elemIdx) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let eIdx = Int(elemIdx)
      let ti = Int(tableIdxOp)
      guard ti < tables.tableCount else { throw InterpreterError.undefinedElement }
      guard eIdx >= 0 && eIdx < tables.count(ofTable: ti) else {
        throw InterpreterError.undefinedElement
      }
      guard case .funcref(let optFuncIdx) = tables[ti, eIdx], let resolvedFuncIdx = optFuncIdx
      else {
        throw InterpreterError.undefinedElement
      }
      let expectedType = moduleRef.pointee.types[Int(typeIdx)]
      let actualType = moduleRef.pointee.functionType(at: Int(resolvedFuncIdx))
      guard
        expectedType.params.count == actualType.params.count
          && expectedType.results.count == actualType.results.count
      else { throw InterpreterError.indirectCallTypeMismatch }
      for i in 0..<expectedType.params.count {
        guard expectedType.params[i] == actualType.params[i] else {
          throw InterpreterError.indirectCallTypeMismatch
        }
      }
      for i in 0..<expectedType.results.count {
        guard expectedType.results[i] == actualType.results[i] else {
          throw InterpreterError.indirectCallTypeMismatch
        }
      }
      let argCount = expectedType.params.count
      guard valueStack.count >= argCount else { throw InterpreterError.stackUnderflow }
      frames.setIp(at: fi, UInt32(cursor))
      try pushEmbeddedFrame(
        moduleRef, Int(resolvedFuncIdx), argCount, &valueStack, &frames, &memory)

    // MARK: Parametric — drop (0x1A) / select (0x1B)

    case 0x1A:  // drop
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      valueStack.removeLast()
      frames.setIp(at: fi, nextIp)

    case 0x1B:  // select
      guard valueStack.count >= 3 else { throw InterpreterError.stackUnderflow }
      guard case .i32(let cond) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let v2 = valueStack.removeLast()
      let v1 = valueStack.removeLast()
      valueStack.append(cond != 0 ? v1 : v2)
      frames.setIp(at: fi, nextIp)

    // MARK: Local variables (0x20-0x22)

    case 0x20:  // local.get
      let idx = try readU32Local()
      valueStack.append(valueStack[frames.localBase(at: fi) + Int(idx)])
      frames.setIp(at: fi, UInt32(cursor))

    case 0x21:  // local.set
      let idx = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      valueStack[frames.localBase(at: fi) + Int(idx)] = valueStack.removeLast()
      frames.setIp(at: fi, UInt32(cursor))

    case 0x22:  // local.tee
      let idx = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      valueStack[frames.localBase(at: fi) + Int(idx)] = valueStack[valueStack.count - 1]
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: Global variables (0x23-0x24)

    case 0x23:  // global.get
      let idx = try readU32Local()
      valueStack.append(globals[Int(idx)])
      frames.setIp(at: fi, UInt32(cursor))

    case 0x24:  // global.set
      let idx = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      globals[Int(idx)] = valueStack.removeLast()
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: Table (0x25-0x26)

    case 0x25:  // table.get
      let tableIdx25 = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let idx) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ti25 = Int(tableIdx25)
      guard ti25 < tables.tableCount else { throw InterpreterError.undefinedElement }
      let i25 = Int(UInt32(bitPattern: idx))
      guard i25 < tables.count(ofTable: ti25) else { throw InterpreterError.undefinedElement }
      valueStack.append(tables[ti25, i25])
      frames.setIp(at: fi, UInt32(cursor))

    case 0x26:  // table.set
      let tableIdx26 = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      let refVal = valueStack.removeLast()
      guard case .i32(let idx) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ti26 = Int(tableIdx26)
      guard ti26 < tables.tableCount else { throw InterpreterError.undefinedElement }
      let tableRefType =
        ti26 < moduleRef.pointee.tables.count ? moduleRef.pointee.tables[ti26].refType : .funcRef
      switch (tableRefType, refVal) {
      case (.funcRef, .funcref), (.externRef, .externref): break
      default: throw InterpreterError.typeMismatch
      }
      let i26 = Int(UInt32(bitPattern: idx))
      guard i26 < tables.count(ofTable: ti26) else { throw InterpreterError.undefinedElement }
      tables[ti26, i26] = refVal
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: Memory loads (0x28-0x35)

    case 0x28:  // i32.load
      _ = try readU32Local()  // align (ignored)
      let offset28 = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea28 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset28)
      guard ea28 + 4 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p28 = Int(ea28)
      let v28 =
        UInt32(memory[p28]) | (UInt32(memory[p28 + 1]) << 8)
        | (UInt32(memory[p28 + 2]) << 16) | (UInt32(memory[p28 + 3]) << 24)
      valueStack.append(.i32(Int32(bitPattern: v28)))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x29:  // i64.load
      _ = try readU32Local()  // align (ignored)
      let offset29 = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea29 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset29)
      guard ea29 + 8 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p29 = Int(ea29)
      let v29 =
        UInt64(memory[p29]) | (UInt64(memory[p29 + 1]) << 8)
        | (UInt64(memory[p29 + 2]) << 16) | (UInt64(memory[p29 + 3]) << 24)
        | (UInt64(memory[p29 + 4]) << 32) | (UInt64(memory[p29 + 5]) << 40)
        | (UInt64(memory[p29 + 6]) << 48) | (UInt64(memory[p29 + 7]) << 56)
      valueStack.append(.i64(Int64(bitPattern: v29)))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x2A:  // f32.load
      _ = try readU32Local()  // align (ignored)
      let offset2A = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea2A = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2A)
      guard ea2A + 4 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p2A = Int(ea2A)
      let bits2A =
        UInt32(memory[p2A]) | (UInt32(memory[p2A + 1]) << 8)
        | (UInt32(memory[p2A + 2]) << 16) | (UInt32(memory[p2A + 3]) << 24)
      valueStack.append(.f32(Float(bitPattern: bits2A)))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x2B:  // f64.load
      _ = try readU32Local()  // align (ignored)
      let offset2B = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea2B = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2B)
      guard ea2B + 8 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p2B = Int(ea2B)
      let bits2B =
        UInt64(memory[p2B]) | (UInt64(memory[p2B + 1]) << 8)
        | (UInt64(memory[p2B + 2]) << 16) | (UInt64(memory[p2B + 3]) << 24)
        | (UInt64(memory[p2B + 4]) << 32) | (UInt64(memory[p2B + 5]) << 40)
        | (UInt64(memory[p2B + 6]) << 48) | (UInt64(memory[p2B + 7]) << 56)
      valueStack.append(.f64(Double(bitPattern: bits2B)))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x2C:  // i32.load8_s
      _ = try readU32Local()  // align (ignored)
      let offset2C = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea2C = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2C)
      guard ea2C + 1 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      valueStack.append(.i32(Int32(Int8(bitPattern: memory[Int(ea2C)]))))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x2D:  // i32.load8_u
      _ = try readU32Local()  // align (ignored)
      let offset2D = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea2D = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2D)
      guard ea2D + 1 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      valueStack.append(.i32(Int32(memory[Int(ea2D)])))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x2E:  // i32.load16_s
      _ = try readU32Local()  // align (ignored)
      let offset2E = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea2E = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2E)
      guard ea2E + 2 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p2E = Int(ea2E)
      let raw2E = UInt16(memory[p2E]) | (UInt16(memory[p2E + 1]) << 8)
      valueStack.append(.i32(Int32(Int16(bitPattern: raw2E))))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x2F:  // i32.load16_u
      _ = try readU32Local()  // align (ignored)
      let offset2F = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea2F = UInt64(UInt32(bitPattern: addr)) + UInt64(offset2F)
      guard ea2F + 2 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p2F = Int(ea2F)
      let raw2F = UInt16(memory[p2F]) | (UInt16(memory[p2F + 1]) << 8)
      valueStack.append(.i32(Int32(raw2F)))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x30:  // i64.load8_s
      _ = try readU32Local()  // align (ignored)
      let offset30 = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea30 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset30)
      guard ea30 + 1 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      valueStack.append(.i64(Int64(Int8(bitPattern: memory[Int(ea30)]))))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x31:  // i64.load8_u
      _ = try readU32Local()  // align (ignored)
      let offset31 = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea31 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset31)
      guard ea31 + 1 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      valueStack.append(.i64(Int64(memory[Int(ea31)])))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x32:  // i64.load16_s
      _ = try readU32Local()  // align (ignored)
      let offset32 = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea32 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset32)
      guard ea32 + 2 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p32 = Int(ea32)
      let raw32 = UInt16(memory[p32]) | (UInt16(memory[p32 + 1]) << 8)
      valueStack.append(.i64(Int64(Int16(bitPattern: raw32))))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x33:  // i64.load16_u
      _ = try readU32Local()  // align (ignored)
      let offset33 = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea33 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset33)
      guard ea33 + 2 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p33 = Int(ea33)
      let raw33 = UInt16(memory[p33]) | (UInt16(memory[p33 + 1]) << 8)
      valueStack.append(.i64(Int64(raw33)))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x34:  // i64.load32_s
      _ = try readU32Local()  // align (ignored)
      let offset34 = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea34 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset34)
      guard ea34 + 4 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p34 = Int(ea34)
      let raw34 =
        UInt32(memory[p34]) | (UInt32(memory[p34 + 1]) << 8)
        | (UInt32(memory[p34 + 2]) << 16) | (UInt32(memory[p34 + 3]) << 24)
      valueStack.append(.i64(Int64(Int32(bitPattern: raw34))))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x35:  // i64.load32_u
      _ = try readU32Local()  // align (ignored)
      let offset35 = try readU32Local()
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea35 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset35)
      guard ea35 + 4 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p35 = Int(ea35)
      let raw35 =
        UInt32(memory[p35]) | (UInt32(memory[p35 + 1]) << 8)
        | (UInt32(memory[p35 + 2]) << 16) | (UInt32(memory[p35 + 3]) << 24)
      valueStack.append(.i64(Int64(raw35)))
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: Memory stores (0x36-0x3E)

    case 0x36:  // i32.store
      _ = try readU32Local()  // align (ignored)
      let offset36 = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .i32(let value) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea36 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset36)
      guard ea36 + 4 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p36 = Int(ea36)
      let u36 = UInt32(bitPattern: value)
      memory[p36] = UInt8(u36 & 0xFF)
      memory[p36 + 1] = UInt8((u36 >> 8) & 0xFF)
      memory[p36 + 2] = UInt8((u36 >> 16) & 0xFF)
      memory[p36 + 3] = UInt8((u36 >> 24) & 0xFF)
      frames.setIp(at: fi, UInt32(cursor))

    case 0x37:  // i64.store
      _ = try readU32Local()  // align (ignored)
      let offset37 = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .i64(let value) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea37 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset37)
      guard ea37 + 8 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p37 = Int(ea37)
      let u37 = UInt64(bitPattern: value)
      memory[p37] = UInt8(u37 & 0xFF)
      memory[p37 + 1] = UInt8((u37 >> 8) & 0xFF)
      memory[p37 + 2] = UInt8((u37 >> 16) & 0xFF)
      memory[p37 + 3] = UInt8((u37 >> 24) & 0xFF)
      memory[p37 + 4] = UInt8((u37 >> 32) & 0xFF)
      memory[p37 + 5] = UInt8((u37 >> 40) & 0xFF)
      memory[p37 + 6] = UInt8((u37 >> 48) & 0xFF)
      memory[p37 + 7] = UInt8((u37 >> 56) & 0xFF)
      frames.setIp(at: fi, UInt32(cursor))

    case 0x38:  // f32.store
      _ = try readU32Local()  // align (ignored)
      let offset38 = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let value) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea38 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset38)
      guard ea38 + 4 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p38 = Int(ea38)
      let u38 = value.bitPattern
      memory[p38] = UInt8(u38 & 0xFF)
      memory[p38 + 1] = UInt8((u38 >> 8) & 0xFF)
      memory[p38 + 2] = UInt8((u38 >> 16) & 0xFF)
      memory[p38 + 3] = UInt8((u38 >> 24) & 0xFF)
      frames.setIp(at: fi, UInt32(cursor))

    case 0x39:  // f64.store
      _ = try readU32Local()  // align (ignored)
      let offset39 = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let value) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea39 = UInt64(UInt32(bitPattern: addr)) + UInt64(offset39)
      guard ea39 + 8 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p39 = Int(ea39)
      let u39 = value.bitPattern
      memory[p39] = UInt8(u39 & 0xFF)
      memory[p39 + 1] = UInt8((u39 >> 8) & 0xFF)
      memory[p39 + 2] = UInt8((u39 >> 16) & 0xFF)
      memory[p39 + 3] = UInt8((u39 >> 24) & 0xFF)
      memory[p39 + 4] = UInt8((u39 >> 32) & 0xFF)
      memory[p39 + 5] = UInt8((u39 >> 40) & 0xFF)
      memory[p39 + 6] = UInt8((u39 >> 48) & 0xFF)
      memory[p39 + 7] = UInt8((u39 >> 56) & 0xFF)
      frames.setIp(at: fi, UInt32(cursor))

    case 0x3A:  // i32.store8
      _ = try readU32Local()  // align (ignored)
      let offset3A = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .i32(let value) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea3A = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3A)
      guard ea3A + 1 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      memory[Int(ea3A)] = UInt8(UInt32(bitPattern: value) & 0xFF)
      frames.setIp(at: fi, UInt32(cursor))

    case 0x3B:  // i32.store16
      _ = try readU32Local()  // align (ignored)
      let offset3B = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .i32(let value) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea3B = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3B)
      guard ea3B + 2 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p3B = Int(ea3B)
      let u3B = UInt32(bitPattern: value)
      memory[p3B] = UInt8(u3B & 0xFF)
      memory[p3B + 1] = UInt8((u3B >> 8) & 0xFF)
      frames.setIp(at: fi, UInt32(cursor))

    case 0x3C:  // i64.store8
      _ = try readU32Local()  // align (ignored)
      let offset3C = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .i64(let value) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea3C = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3C)
      guard ea3C + 1 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      memory[Int(ea3C)] = UInt8(UInt64(bitPattern: value) & 0xFF)
      frames.setIp(at: fi, UInt32(cursor))

    case 0x3D:  // i64.store16
      _ = try readU32Local()  // align (ignored)
      let offset3D = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .i64(let value) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea3D = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3D)
      guard ea3D + 2 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p3D = Int(ea3D)
      let u3D = UInt64(bitPattern: value)
      memory[p3D] = UInt8(u3D & 0xFF)
      memory[p3D + 1] = UInt8((u3D >> 8) & 0xFF)
      frames.setIp(at: fi, UInt32(cursor))

    case 0x3E:  // i64.store32
      _ = try readU32Local()  // align (ignored)
      let offset3E = try readU32Local()
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .i64(let value) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      guard case .i32(let addr) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let ea3E = UInt64(UInt32(bitPattern: addr)) + UInt64(offset3E)
      guard ea3E + 4 <= UInt64(memory.count) else { throw InterpreterError.memoryAccessOutOfBounds }
      let p3E = Int(ea3E)
      let u3E = UInt64(bitPattern: value)
      memory[p3E] = UInt8(u3E & 0xFF)
      memory[p3E + 1] = UInt8((u3E >> 8) & 0xFF)
      memory[p3E + 2] = UInt8((u3E >> 16) & 0xFF)
      memory[p3E + 3] = UInt8((u3E >> 24) & 0xFF)
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: memory.size / memory.grow (0x3F-0x40)

    case 0x3F:  // memory.size
      _ = try readByteLocal()  // reserved byte (must be 0x00)
      let pages3F = Int32(memory.count / 65536)
      valueStack.append(.i32(pages3F))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x40:  // memory.grow
      _ = try readByteLocal()  // reserved byte (must be 0x00)
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let delta) = valueStack.removeLast() else {
        throw InterpreterError.typeMismatch
      }
      let pageSize40: UInt64 = 65536
      let oldPages40 = memory.count / Int(pageSize40)
      let oldPagesI32_40 = Int32(oldPages40)
      // Treat delta as unsigned per Wasm spec — stay in UInt64 until after overflow guard.
      // Int(UInt32(bitPattern:)) traps on 32-bit RP2350 when the unsigned value > Int32.max.
      let n40u = UInt64(UInt32(bitPattern: delta))
      let newByteCount40 = n40u * pageSize40
      let newPages40u = UInt64(oldPages40) + n40u
      let memMax40: UInt32? = moduleRef.pointee.memories.first?.max
      let exceedsMax40: Bool
      if let maxPages = memMax40 {
        exceedsMax40 = newPages40u > UInt64(maxPages)
      } else {
        // No declared max: Wasm spec hard-limits to 65536 pages (4 GiB).
        exceedsMax40 = newPages40u > 65536
      }
      // Guard in UInt64 throughout to avoid Int overflow on 32-bit targets.
      // memoryCapacity is the arena-pre-allocated ceiling set at init.
      if newByteCount40 > UInt64(Int.max) || exceedsMax40
        || UInt64(memory.count) + newByteCount40 > UInt64(memoryCapacity)
      {
        valueStack.append(.i32(-1))
      } else {
        // Safe to convert — checked above that newByteCount40 <= Int.max.
        let newByteCount40Int = Int(newByteCount40)
        // The arena pre-allocated up to memoryCapacity bytes at memory.baseAddress.
        // The new pages are already zero-initialised (arena zeroed the full block at init).
        memory = UnsafeMutableBufferPointer(
          start: memory.baseAddress,
          count: memory.count + newByteCount40Int)
        valueStack.append(.i32(oldPagesI32_40))
      }
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: Constants (0x41-0x44)

    case 0x41:  // i32.const
      let value = try readS32Local()
      valueStack.append(.i32(value))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x42:  // i64.const
      let value = try readS64Local()
      valueStack.append(.i64(value))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x43:  // f32.const  (4 raw bytes LE — IEEE 754 bit pattern)
      let b0_43 = UInt32(try readByteLocal())
      let b1_43 = UInt32(try readByteLocal())
      let b2_43 = UInt32(try readByteLocal())
      let b3_43 = UInt32(try readByteLocal())
      valueStack.append(
        .f32(Float(bitPattern: b0_43 | (b1_43 << 8) | (b2_43 << 16) | (b3_43 << 24))))
      frames.setIp(at: fi, UInt32(cursor))

    case 0x44:  // f64.const  (8 raw bytes LE — IEEE 754 bit pattern)
      let c0_44 = UInt64(try readByteLocal())
      let c1_44 = UInt64(try readByteLocal())
      let c2_44 = UInt64(try readByteLocal())
      let c3_44 = UInt64(try readByteLocal())
      let c4_44 = UInt64(try readByteLocal())
      let c5_44 = UInt64(try readByteLocal())
      let c6_44 = UInt64(try readByteLocal())
      let c7_44 = UInt64(try readByteLocal())
      let bits44 =
        c0_44 | (c1_44 << 8) | (c2_44 << 16) | (c3_44 << 24) | (c4_44 << 32) | (c5_44 << 40)
        | (c6_44 << 48) | (c7_44 << 56)
      valueStack.append(.f64(Double(bitPattern: bits44)))
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: i32 comparisons (0x45-0x4F)

    case 0x45:  // i32.eqz
      try intEqzOp(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x46:  // i32.eq
      try intCmpOp(UInt32.self, &valueStack) { a, b in a == b }
      frames.setIp(at: fi, nextIp)

    case 0x47:  // i32.ne
      try intCmpOp(UInt32.self, &valueStack) { a, b in a != b }
      frames.setIp(at: fi, nextIp)

    case 0x48:  // i32.lt_s
      try intSignedCmpOp(UInt32.self, &valueStack) { a, b in a < b }
      frames.setIp(at: fi, nextIp)

    case 0x49:  // i32.lt_u
      try intCmpOp(UInt32.self, &valueStack) { a, b in a < b }
      frames.setIp(at: fi, nextIp)

    case 0x4A:  // i32.gt_s
      try intSignedCmpOp(UInt32.self, &valueStack) { a, b in a > b }
      frames.setIp(at: fi, nextIp)

    case 0x4B:  // i32.gt_u
      try intCmpOp(UInt32.self, &valueStack) { a, b in a > b }
      frames.setIp(at: fi, nextIp)

    case 0x4C:  // i32.le_s
      try intSignedCmpOp(UInt32.self, &valueStack) { a, b in a <= b }
      frames.setIp(at: fi, nextIp)

    case 0x4D:  // i32.le_u
      try intCmpOp(UInt32.self, &valueStack) { a, b in a <= b }
      frames.setIp(at: fi, nextIp)

    case 0x4E:  // i32.ge_s
      try intSignedCmpOp(UInt32.self, &valueStack) { a, b in a >= b }
      frames.setIp(at: fi, nextIp)

    case 0x4F:  // i32.ge_u
      try intCmpOp(UInt32.self, &valueStack) { a, b in a >= b }
      frames.setIp(at: fi, nextIp)

    // MARK: i64 comparisons (0x50-0x5A)

    case 0x50:  // i64.eqz
      try intEqzOp(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x51:  // i64.eq
      try intCmpOp(UInt64.self, &valueStack) { a, b in a == b }
      frames.setIp(at: fi, nextIp)

    case 0x52:  // i64.ne
      try intCmpOp(UInt64.self, &valueStack) { a, b in a != b }
      frames.setIp(at: fi, nextIp)

    case 0x53:  // i64.lt_s
      try intSignedCmpOp(UInt64.self, &valueStack) { a, b in a < b }
      frames.setIp(at: fi, nextIp)

    case 0x54:  // i64.lt_u
      try intCmpOp(UInt64.self, &valueStack) { a, b in a < b }
      frames.setIp(at: fi, nextIp)

    case 0x55:  // i64.gt_s
      try intSignedCmpOp(UInt64.self, &valueStack) { a, b in a > b }
      frames.setIp(at: fi, nextIp)

    case 0x56:  // i64.gt_u
      try intCmpOp(UInt64.self, &valueStack) { a, b in a > b }
      frames.setIp(at: fi, nextIp)

    case 0x57:  // i64.le_s
      try intSignedCmpOp(UInt64.self, &valueStack) { a, b in a <= b }
      frames.setIp(at: fi, nextIp)

    case 0x58:  // i64.le_u
      try intCmpOp(UInt64.self, &valueStack) { a, b in a <= b }
      frames.setIp(at: fi, nextIp)

    case 0x59:  // i64.ge_s
      try intSignedCmpOp(UInt64.self, &valueStack) { a, b in a >= b }
      frames.setIp(at: fi, nextIp)

    case 0x5A:  // i64.ge_u
      try intCmpOp(UInt64.self, &valueStack) { a, b in a >= b }
      frames.setIp(at: fi, nextIp)

    // MARK: f32 comparisons (0x5B-0x60)

    case 0x5B:  // f32.eq
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a == b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x5C:  // f32.ne
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a != b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x5D:  // f32.lt
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a < b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x5E:  // f32.gt
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a > b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x5F:  // f32.le
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a <= b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x60:  // f32.ge
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a >= b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    // MARK: f64 comparisons (0x61-0x66)

    case 0x61:  // f64.eq
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a == b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x62:  // f64.ne
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a != b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x63:  // f64.lt
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a < b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x64:  // f64.gt
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a > b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x65:  // f64.le
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a <= b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    case 0x66:  // f64.ge
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(a >= b ? 1 : 0))
      frames.setIp(at: fi, nextIp)

    // MARK: i32 unary / arithmetic / bitwise (0x67-0x78)

    case 0x67:  // i32.clz
      try intCountOp(UInt32.self, &valueStack) { $0.leadingZeroBitCount }
      frames.setIp(at: fi, nextIp)

    case 0x68:  // i32.ctz
      try intCountOp(UInt32.self, &valueStack) { $0.trailingZeroBitCount }
      frames.setIp(at: fi, nextIp)

    case 0x69:  // i32.popcnt
      try intCountOp(UInt32.self, &valueStack) { $0.nonzeroBitCount }
      frames.setIp(at: fi, nextIp)

    case 0x6A:  // i32.add
      try intBinaryOp(UInt32.self, &valueStack) { a, b in a &+ b }
      frames.setIp(at: fi, nextIp)

    case 0x6B:  // i32.sub
      try intBinaryOp(UInt32.self, &valueStack) { a, b in a &- b }
      frames.setIp(at: fi, nextIp)

    case 0x6C:  // i32.mul
      try intBinaryOp(UInt32.self, &valueStack) { a, b in a &* b }
      frames.setIp(at: fi, nextIp)

    case 0x6D:  // i32.div_s
      try intDivS(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x6E:  // i32.div_u
      try intDivU(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x6F:  // i32.rem_s
      try intRemS(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x70:  // i32.rem_u
      try intRemU(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x71:  // i32.and
      try intBinaryOp(UInt32.self, &valueStack) { a, b in a & b }
      frames.setIp(at: fi, nextIp)

    case 0x72:  // i32.or
      try intBinaryOp(UInt32.self, &valueStack) { a, b in a | b }
      frames.setIp(at: fi, nextIp)

    case 0x73:  // i32.xor
      try intBinaryOp(UInt32.self, &valueStack) { a, b in a ^ b }
      frames.setIp(at: fi, nextIp)

    case 0x74:  // i32.shl
      try intShl(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x75:  // i32.shr_s
      try intShrS(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x76:  // i32.shr_u
      try intShrU(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x77:  // i32.rotl
      try intRotl(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x78:  // i32.rotr
      try intRotr(UInt32.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    // MARK: i64 unary / arithmetic / bitwise (0x79-0x8A)

    case 0x79:  // i64.clz
      try intCountOp(UInt64.self, &valueStack) { $0.leadingZeroBitCount }
      frames.setIp(at: fi, nextIp)

    case 0x7A:  // i64.ctz
      try intCountOp(UInt64.self, &valueStack) { $0.trailingZeroBitCount }
      frames.setIp(at: fi, nextIp)

    case 0x7B:  // i64.popcnt
      try intCountOp(UInt64.self, &valueStack) { $0.nonzeroBitCount }
      frames.setIp(at: fi, nextIp)

    case 0x7C:  // i64.add
      try intBinaryOp(UInt64.self, &valueStack) { a, b in a &+ b }
      frames.setIp(at: fi, nextIp)

    case 0x7D:  // i64.sub
      try intBinaryOp(UInt64.self, &valueStack) { a, b in a &- b }
      frames.setIp(at: fi, nextIp)

    case 0x7E:  // i64.mul
      try intBinaryOp(UInt64.self, &valueStack) { a, b in a &* b }
      frames.setIp(at: fi, nextIp)

    case 0x7F:  // i64.div_s
      try intDivS(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x80:  // i64.div_u
      try intDivU(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x81:  // i64.rem_s
      try intRemS(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x82:  // i64.rem_u
      try intRemU(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x83:  // i64.and
      try intBinaryOp(UInt64.self, &valueStack) { a, b in a & b }
      frames.setIp(at: fi, nextIp)

    case 0x84:  // i64.or
      try intBinaryOp(UInt64.self, &valueStack) { a, b in a | b }
      frames.setIp(at: fi, nextIp)

    case 0x85:  // i64.xor
      try intBinaryOp(UInt64.self, &valueStack) { a, b in a ^ b }
      frames.setIp(at: fi, nextIp)

    case 0x86:  // i64.shl
      try intShl(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x87:  // i64.shr_s
      try intShrS(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x88:  // i64.shr_u
      try intShrU(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x89:  // i64.rotl
      try intRotl(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    case 0x8A:  // i64.rotr
      try intRotr(UInt64.self, &valueStack)
      frames.setIp(at: fi, nextIp)

    // MARK: f32 unary / arithmetic (0x8B-0x98)

    case 0x8B:  // f32.abs
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a.magnitude))
      frames.setIp(at: fi, nextIp)

    case 0x8C:  // f32.neg
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(-a))
      frames.setIp(at: fi, nextIp)

    case 0x8D:  // f32.ceil
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a.rounded(.up)))
      frames.setIp(at: fi, nextIp)

    case 0x8E:  // f32.floor
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a.rounded(.down)))
      frames.setIp(at: fi, nextIp)

    case 0x8F:  // f32.trunc
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a.rounded(.towardZero)))
      frames.setIp(at: fi, nextIp)

    case 0x90:  // f32.nearest
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a.rounded(.toNearestOrEven)))
      frames.setIp(at: fi, nextIp)

    case 0x91:  // f32.sqrt
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a.squareRoot()))
      frames.setIp(at: fi, nextIp)

    case 0x92:  // f32.add
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a + b))
      frames.setIp(at: fi, nextIp)

    case 0x93:  // f32.sub
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a - b))
      frames.setIp(at: fi, nextIp)

    case 0x94:  // f32.mul
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a * b))
      frames.setIp(at: fi, nextIp)

    case 0x95:  // f32.div
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(a / b))
      frames.setIp(at: fi, nextIp)

    case 0x96:  // f32.min
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      // Wasm f32.min: propagates NaN; treats -0 < +0
      let min96: Float
      if a.isNaN || b.isNaN {
        min96 = .nan
      } else if a == 0 && b == 0 {
        min96 = (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0
      } else {
        min96 = a < b ? a : b
      }
      valueStack.append(.f32(min96))
      frames.setIp(at: fi, nextIp)

    case 0x97:  // f32.max
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      // Wasm f32.max: propagates NaN; treats +0 > -0
      let max97: Float
      if a.isNaN || b.isNaN {
        max97 = .nan
      } else if a == 0 && b == 0 {
        max97 = (a.sign == .plus || b.sign == .plus) ? 0.0 : -0.0
      } else {
        max97 = a > b ? a : b
      }
      valueStack.append(.f32(max97))
      frames.setIp(at: fi, nextIp)

    case 0x98:  // f32.copysign
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f32(let b) = valueStack.removeLast(),
        case .f32(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(Float(signOf: b, magnitudeOf: a)))
      frames.setIp(at: fi, nextIp)

    // MARK: f64 unary / arithmetic (0x99-0xA6)

    case 0x99:  // f64.abs
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(a.magnitude))
      frames.setIp(at: fi, nextIp)

    case 0x9A:  // f64.neg
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(-a))
      frames.setIp(at: fi, nextIp)

    case 0x9B:  // f64.ceil
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(a.rounded(.up)))
      frames.setIp(at: fi, nextIp)

    case 0x9C:  // f64.floor
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(a.rounded(.down)))
      frames.setIp(at: fi, nextIp)

    case 0x9D:  // f64.trunc
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(a.rounded(.towardZero)))
      frames.setIp(at: fi, nextIp)

    case 0x9E:  // f64.nearest
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(a.rounded(.toNearestOrEven)))
      frames.setIp(at: fi, nextIp)

    case 0x9F:  // f64.sqrt
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(a.squareRoot()))
      frames.setIp(at: fi, nextIp)

    case 0xA0:  // f64.add
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(a + b))
      frames.setIp(at: fi, nextIp)

    case 0xA1:  // f64.sub
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(a - b))
      frames.setIp(at: fi, nextIp)

    case 0xA2:  // f64.mul
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(a * b))
      frames.setIp(at: fi, nextIp)

    case 0xA3:  // f64.div
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      // f64.div follows IEEE 754: division by zero yields ±infinity, not a trap.
      valueStack.append(.f64(a / b))
      frames.setIp(at: fi, nextIp)

    case 0xA4:  // f64.min
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      // Wasm f64.min: propagates NaN; treats -0 < +0
      let minA4: Double
      if a.isNaN || b.isNaN {
        minA4 = .nan
      } else if a == 0 && b == 0 {
        minA4 = (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0
      } else {
        minA4 = a < b ? a : b
      }
      valueStack.append(.f64(minA4))
      frames.setIp(at: fi, nextIp)

    case 0xA5:  // f64.max
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      // Wasm f64.max: propagates NaN; treats +0 > -0
      let maxA5: Double
      if a.isNaN || b.isNaN {
        maxA5 = .nan
      } else if a == 0 && b == 0 {
        maxA5 = (a.sign == .plus || b.sign == .plus) ? 0.0 : -0.0
      } else {
        maxA5 = a > b ? a : b
      }
      valueStack.append(.f64(maxA5))
      frames.setIp(at: fi, nextIp)

    case 0xA6:  // f64.copysign
      guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
      guard case .f64(let b) = valueStack.removeLast(),
        case .f64(let a) = valueStack.removeLast()
      else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(Double(signOf: b, magnitudeOf: a)))
      frames.setIp(at: fi, nextIp)

    // MARK: Conversion instructions (0xA7-0xC4)

    case 0xA7:  // i32.wrap_i64 — keep lower 32 bits of i64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(Int32(truncatingIfNeeded: a)))
      frames.setIp(at: fi, nextIp)

    case 0xA8:  // i32.trunc_f32_s — f32 → signed i32; traps on NaN, Inf, out-of-range
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      guard !a.isNaN && !a.isInfinite else { throw InterpreterError.invalidConversionToInteger }
      guard a >= -2_147_483_648.0 && a < 2_147_483_648.0
      else { throw InterpreterError.invalidConversionToInteger }
      valueStack.append(.i32(Int32(a)))
      frames.setIp(at: fi, nextIp)

    case 0xA9:  // i32.trunc_f32_u — f32 → unsigned i32; values in (-1,0) truncate to 0
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      guard !a.isNaN && !a.isInfinite else { throw InterpreterError.invalidConversionToInteger }
      guard a > -1.0 && a < 4_294_967_296.0 else {
        throw InterpreterError.invalidConversionToInteger
      }
      let u32A9: UInt32 = a < 0.0 ? 0 : UInt32(a)
      valueStack.append(.i32(Int32(bitPattern: u32A9)))
      frames.setIp(at: fi, nextIp)

    case 0xAA:  // i32.trunc_f64_s — f64 → signed i32; values in (-2147483649,-2147483648] are valid
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      guard !a.isNaN && !a.isInfinite else { throw InterpreterError.invalidConversionToInteger }
      guard a > -2_147_483_649.0 && a < 2_147_483_648.0
      else { throw InterpreterError.invalidConversionToInteger }
      valueStack.append(.i32(Int32(a)))
      frames.setIp(at: fi, nextIp)

    case 0xAB:  // i32.trunc_f64_u — f64 → unsigned i32; values in (-1,0) truncate to 0
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      guard !a.isNaN && !a.isInfinite else { throw InterpreterError.invalidConversionToInteger }
      guard a > -1.0 && a < 4_294_967_296.0 else {
        throw InterpreterError.invalidConversionToInteger
      }
      let u32AB: UInt32 = a < 0.0 ? 0 : UInt32(a)
      valueStack.append(.i32(Int32(bitPattern: u32AB)))
      frames.setIp(at: fi, nextIp)

    case 0xAC:  // i64.extend_i32_s — sign-extend i32 to i64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i64(Int64(a)))
      frames.setIp(at: fi, nextIp)

    case 0xAD:  // i64.extend_i32_u — zero-extend i32 to i64 (treat i32 as UInt32)
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i64(Int64(UInt32(bitPattern: a))))
      frames.setIp(at: fi, nextIp)

    case 0xAE:  // i64.trunc_f32_s — f32 → signed i64; -2^63 is exactly representable in f32
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      guard !a.isNaN && !a.isInfinite else { throw InterpreterError.invalidConversionToInteger }
      guard a >= -9_223_372_036_854_775_808.0 && a < 9_223_372_036_854_775_808.0
      else { throw InterpreterError.invalidConversionToInteger }
      valueStack.append(.i64(Int64(a)))
      frames.setIp(at: fi, nextIp)

    case 0xAF:  // i64.trunc_f32_u — f32 → unsigned i64; values in (-1,0) truncate to 0
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      guard !a.isNaN && !a.isInfinite else { throw InterpreterError.invalidConversionToInteger }
      guard a > -1.0 && a < 18_446_744_073_709_551_616.0
      else { throw InterpreterError.invalidConversionToInteger }
      let u64AF: UInt64 = a < 0.0 ? 0 : UInt64(a)
      valueStack.append(.i64(Int64(bitPattern: u64AF)))
      frames.setIp(at: fi, nextIp)

    case 0xB0:  // i64.trunc_f64_s — f64 → signed i64; lower bound -2^63 is exactly representable
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      guard !a.isNaN && !a.isInfinite else { throw InterpreterError.invalidConversionToInteger }
      guard a >= -9_223_372_036_854_775_808.0 && a < 9_223_372_036_854_775_808.0
      else { throw InterpreterError.invalidConversionToInteger }
      valueStack.append(.i64(Int64(a)))
      frames.setIp(at: fi, nextIp)

    case 0xB1:  // i64.trunc_f64_u — f64 → unsigned i64; values in (-1,0) truncate to 0
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      guard !a.isNaN && !a.isInfinite else { throw InterpreterError.invalidConversionToInteger }
      guard a > -1.0 && a < 18_446_744_073_709_551_616.0
      else { throw InterpreterError.invalidConversionToInteger }
      let u64B1: UInt64 = a < 0.0 ? 0 : UInt64(a)
      valueStack.append(.i64(Int64(bitPattern: u64B1)))
      frames.setIp(at: fi, nextIp)

    case 0xB2:  // f32.convert_i32_s — signed i32 to f32
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(Float(a)))
      frames.setIp(at: fi, nextIp)

    case 0xB3:  // f32.convert_i32_u — unsigned i32 (stored as signed i32) to f32
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(Float(UInt32(bitPattern: a))))
      frames.setIp(at: fi, nextIp)

    case 0xB4:  // f32.convert_i64_s — signed i64 to f32
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(Float(a)))
      frames.setIp(at: fi, nextIp)

    case 0xB5:  // f32.convert_i64_u — unsigned i64 (stored as signed i64) to f32
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(Float(UInt64(bitPattern: a))))
      frames.setIp(at: fi, nextIp)

    case 0xB6:  // f32.demote_f64 — reduce f64 to f32 (may lose precision; NaN/Inf preserved)
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(Float(a)))
      frames.setIp(at: fi, nextIp)

    case 0xB7:  // f64.convert_i32_s — signed i32 to f64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(Double(a)))
      frames.setIp(at: fi, nextIp)

    case 0xB8:  // f64.convert_i32_u — unsigned i32 (stored as signed i32) to f64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(Double(UInt32(bitPattern: a))))
      frames.setIp(at: fi, nextIp)

    case 0xB9:  // f64.convert_i64_s — signed i64 to f64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(Double(a)))
      frames.setIp(at: fi, nextIp)

    case 0xBA:  // f64.convert_i64_u — unsigned i64 (stored as signed i64) to f64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(Double(UInt64(bitPattern: a))))
      frames.setIp(at: fi, nextIp)

    case 0xBB:  // f64.promote_f32 — extend f32 to f64 (exact; NaN/Inf preserved)
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(Double(a)))
      frames.setIp(at: fi, nextIp)

    case 0xBC:  // i32.reinterpret_f32 — reinterpret IEEE 754 bit pattern of f32 as i32
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(Int32(bitPattern: a.bitPattern)))
      frames.setIp(at: fi, nextIp)

    case 0xBD:  // i64.reinterpret_f64 — reinterpret IEEE 754 bit pattern of f64 as i64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .f64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i64(Int64(bitPattern: a.bitPattern)))
      frames.setIp(at: fi, nextIp)

    case 0xBE:  // f32.reinterpret_i32 — reinterpret i32 bits as f32 IEEE 754 value
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f32(Float(bitPattern: UInt32(bitPattern: a))))
      frames.setIp(at: fi, nextIp)

    case 0xBF:  // f64.reinterpret_i64 — reinterpret i64 bits as f64 IEEE 754 value
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.f64(Double(bitPattern: UInt64(bitPattern: a))))
      frames.setIp(at: fi, nextIp)

    case 0xC0:  // i32.extend8_s — sign-extend low 8 bits of i32 to full i32
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(Int32(Int8(bitPattern: UInt8(a & 0xFF)))))
      frames.setIp(at: fi, nextIp)

    case 0xC1:  // i32.extend16_s — sign-extend low 16 bits of i32 to full i32
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i32(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i32(Int32(Int16(bitPattern: UInt16(a & 0xFFFF)))))
      frames.setIp(at: fi, nextIp)

    case 0xC2:  // i64.extend8_s — sign-extend low 8 bits of i64 to full i64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i64(Int64(Int8(bitPattern: UInt8(a & 0xFF)))))
      frames.setIp(at: fi, nextIp)

    case 0xC3:  // i64.extend16_s — sign-extend low 16 bits of i64 to full i64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i64(Int64(Int16(bitPattern: UInt16(a & 0xFFFF)))))
      frames.setIp(at: fi, nextIp)

    case 0xC4:  // i64.extend32_s — sign-extend low 32 bits of i64 to full i64
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      guard case .i64(let a) = valueStack.removeLast() else { throw InterpreterError.typeMismatch }
      valueStack.append(.i64(Int64(Int32(bitPattern: UInt32(a & 0xFFFF_FFFF)))))
      frames.setIp(at: fi, nextIp)

    // MARK: Reference instructions (0xD0-0xD2)

    case 0xD0:  // ref.null  immediate: reftype (1 byte: 0x70=funcref, 0x6F=externref)
      let refTypeByte = try readByteLocal()
      switch refTypeByte {
      case 0x70: valueStack.append(.funcref(nil))
      case 0x6F: valueStack.append(.externref(nil))
      default: throw InterpreterError.invalidValueType(refTypeByte)
      }
      frames.setIp(at: fi, UInt32(cursor))

    case 0xD1:  // ref.is_null  no immediate
      // Pops any reference type; pushes 1 if null, 0 if non-null.
      guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
      switch valueStack.removeLast() {
      case .funcref(let r): valueStack.append(.i32(r == nil ? 1 : 0))
      case .externref(let r): valueStack.append(.i32(r == nil ? 1 : 0))
      default: throw InterpreterError.typeMismatch
      }
      frames.setIp(at: fi, nextIp)

    case 0xD2:  // ref.func  immediate: funcIdx (u32)
      // Pushes a non-null funcref for the given function index.
      let funcIdxD2 = try readU32Local()
      let totalFunctions =
        moduleRef.pointee.importedFunctionCount + moduleRef.pointee.functions.count
      guard Int(funcIdxD2) < totalFunctions else { throw InterpreterError.functionNotFound }
      valueStack.append(.funcref(funcIdxD2))
      frames.setIp(at: fi, UInt32(cursor))

    // MARK: 0xFC prefix — saturating trunc + bulk memory + table ops

    case 0xFC:
      let subOpcode = try readU32Local()
      switch subOpcode {

      // --- saturating truncation (sub-opcodes 0-7, no further immediates) ---

      case 0:  // i32.trunc_sat_f32_s
        guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let satFC0: Int32
        if a.isNaN {
          satFC0 = 0
        } else if a < -2_147_483_648.0 {
          satFC0 = Int32.min
        } else if a >= 2_147_483_648.0 {
          satFC0 = Int32.max
        } else {
          satFC0 = Int32(a)
        }
        valueStack.append(.i32(satFC0))
        frames.setIp(at: fi, UInt32(cursor))

      case 1:  // i32.trunc_sat_f32_u
        guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let satFC1: UInt32
        if a.isNaN || a < 0.0 {
          satFC1 = 0
        } else if a >= 4_294_967_296.0 {
          satFC1 = UInt32.max
        } else {
          satFC1 = UInt32(a)
        }
        valueStack.append(.i32(Int32(bitPattern: satFC1)))
        frames.setIp(at: fi, UInt32(cursor))

      case 2:  // i32.trunc_sat_f64_s
        guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let satFC2: Int32
        if a.isNaN {
          satFC2 = 0
        } else if a < -2_147_483_648.0 {
          satFC2 = Int32.min
        } else if a >= 2_147_483_648.0 {
          satFC2 = Int32.max
        } else {
          satFC2 = Int32(a)
        }
        valueStack.append(.i32(satFC2))
        frames.setIp(at: fi, UInt32(cursor))

      case 3:  // i32.trunc_sat_f64_u
        guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let satFC3: UInt32
        if a.isNaN || a < 0.0 {
          satFC3 = 0
        } else if a >= 4_294_967_296.0 {
          satFC3 = UInt32.max
        } else {
          satFC3 = UInt32(a)
        }
        valueStack.append(.i32(Int32(bitPattern: satFC3)))
        frames.setIp(at: fi, UInt32(cursor))

      case 4:  // i64.trunc_sat_f32_s
        guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let satFC4: Int64
        if a.isNaN {
          satFC4 = 0
        } else if a < -9_223_372_036_854_775_808.0 {
          satFC4 = Int64.min
        } else if a >= 9_223_372_036_854_775_808.0 {
          satFC4 = Int64.max
        } else {
          satFC4 = Int64(a)
        }
        valueStack.append(.i64(satFC4))
        frames.setIp(at: fi, UInt32(cursor))

      case 5:  // i64.trunc_sat_f32_u
        guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
        guard case .f32(let a) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let satFC5: UInt64
        if a.isNaN || a < 0.0 {
          satFC5 = 0
        } else if a >= 18_446_744_073_709_551_616.0 {
          satFC5 = UInt64.max
        } else {
          satFC5 = UInt64(a)
        }
        valueStack.append(.i64(Int64(bitPattern: satFC5)))
        frames.setIp(at: fi, UInt32(cursor))

      case 6:  // i64.trunc_sat_f64_s
        guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let satFC6: Int64
        if a.isNaN {
          satFC6 = 0
        } else if a < -9_223_372_036_854_775_808.0 {
          satFC6 = Int64.min
        } else if a >= 9_223_372_036_854_775_808.0 {
          satFC6 = Int64.max
        } else {
          satFC6 = Int64(a)
        }
        valueStack.append(.i64(satFC6))
        frames.setIp(at: fi, UInt32(cursor))

      case 7:  // i64.trunc_sat_f64_u
        guard !valueStack.isEmpty else { throw InterpreterError.stackUnderflow }
        guard case .f64(let a) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let satFC7: UInt64
        if a.isNaN || a < 0.0 {
          satFC7 = 0
        } else if a >= 18_446_744_073_709_551_616.0 {
          satFC7 = UInt64.max
        } else {
          satFC7 = UInt64(a)
        }
        valueStack.append(.i64(Int64(bitPattern: satFC7)))
        frames.setIp(at: fi, UInt32(cursor))

      // --- bulk memory operations ---

      case 8:  // memory.init  immediates: dataidx (u32), reserved u32 (must be 0)
        let segIdxFC8 = try readU32Local()
        _ = try readU32Local()  // reserved (ignored)
        guard valueStack.count >= 3 else { throw InterpreterError.stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let src) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let dst) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let siFC8 = Int(segIdxFC8)
        guard siFC8 < moduleRef.pointee.data.count else {
          throw InterpreterError.memoryAccessOutOfBounds
        }
        let copyCountFC8 = Int(UInt32(bitPattern: n))
        let srcOffFC8 = Int(UInt32(bitPattern: src))
        let dstOffFC8 = Int(UInt32(bitPattern: dst))
        // A dropped segment has effective length 0.
        let segLenFC8 =
          droppedData & (UInt64(1) << siFC8) != 0 ? 0 : moduleRef.pointee.data[siFC8].bytes.count
        // Bounds check: applied unconditionally (n=0 with out-of-range src/dst still traps).
        guard srcOffFC8 + copyCountFC8 <= segLenFC8 else {
          throw InterpreterError.memoryAccessOutOfBounds
        }
        guard dstOffFC8 + copyCountFC8 <= memory.count else {
          throw InterpreterError.memoryAccessOutOfBounds
        }
        if copyCountFC8 > 0 {
          let segBytes = moduleRef.pointee.data[siFC8].bytes
          for i in 0..<copyCountFC8 {
            memory[dstOffFC8 + i] = segBytes[srcOffFC8 + i]
          }
        }
        frames.setIp(at: fi, UInt32(cursor))

      case 9:  // data.drop  immediate: dataidx (u32)
        let segIdxFC9 = try readU32Local()
        let siFC9 = Int(segIdxFC9)
        guard siFC9 < moduleRef.pointee.data.count else {
          throw InterpreterError.memoryAccessOutOfBounds
        }
        droppedData |= UInt64(1) << siFC9
        frames.setIp(at: fi, UInt32(cursor))

      case 10:  // memory.copy  immediates: dst_memidx (u32=0), src_memidx (u32=0)
        _ = try readU32Local()  // dst memory index (reserved, must be 0)
        _ = try readU32Local()  // src memory index (reserved, must be 0)
        guard valueStack.count >= 3 else { throw InterpreterError.stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let src) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let dst) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let copyCountFC10 = Int(UInt32(bitPattern: n))
        let srcOffFC10 = Int(UInt32(bitPattern: src))
        let dstOffFC10 = Int(UInt32(bitPattern: dst))
        // Bounds check: applied unconditionally.
        guard srcOffFC10 + copyCountFC10 <= memory.count else {
          throw InterpreterError.memoryAccessOutOfBounds
        }
        guard dstOffFC10 + copyCountFC10 <= memory.count else {
          throw InterpreterError.memoryAccessOutOfBounds
        }
        if copyCountFC10 > 0 {
          // Overlap-safe copy (memmove semantics).
          // Copy forward when dst <= src or regions do not overlap;
          // backward when dst > src and regions overlap to avoid clobbering src bytes.
          // UnsafeMutableBufferPointer.baseAddress gives direct access; no withUnsafeMutableBytes.
          let base = UnsafeMutableRawPointer(memory.baseAddress!)
          if dstOffFC10 <= srcOffFC10 || dstOffFC10 >= srcOffFC10 + copyCountFC10 {
            base.advanced(by: dstOffFC10).copyMemory(
              from: base.advanced(by: srcOffFC10), byteCount: copyCountFC10)
          } else {
            let dstPtr = base.advanced(by: dstOffFC10).assumingMemoryBound(to: UInt8.self)
            let srcPtr = base.advanced(by: srcOffFC10).assumingMemoryBound(to: UInt8.self)
            for i in stride(from: copyCountFC10 - 1, through: 0, by: -1) {
              dstPtr.advanced(by: i).pointee = srcPtr.advanced(by: i).pointee
            }
          }
        }
        frames.setIp(at: fi, UInt32(cursor))

      case 11:  // memory.fill  immediate: memidx (u32=0)
        _ = try readU32Local()  // memory index (reserved, must be 0)
        guard valueStack.count >= 3 else { throw InterpreterError.stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let val) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let dst) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let fillCountFC11 = Int(UInt32(bitPattern: n))
        let dstOffFC11 = Int(UInt32(bitPattern: dst))
        // Bounds check: applied unconditionally.
        guard dstOffFC11 + fillCountFC11 <= memory.count else {
          throw InterpreterError.memoryAccessOutOfBounds
        }
        if fillCountFC11 > 0 {
          let byteFC11 = UInt8(UInt32(bitPattern: val) & 0xFF)
          // initializeMemory compiles to a single memset call.
          // UnsafeMutableBufferPointer.baseAddress gives direct access; no withUnsafeMutableBytes.
          _ = UnsafeMutableRawPointer(memory.baseAddress!).advanced(by: dstOffFC11)
            .initializeMemory(as: UInt8.self, repeating: byteFC11, count: fillCountFC11)
        }
        frames.setIp(at: fi, UInt32(cursor))

      // --- table bulk operations ---

      case 12:  // table.init  immediates: elemidx (u32), tableidx (u32)
        let elemIdxFC12 = try readU32Local()
        let tableIdxFC12 = try readU32Local()
        guard valueStack.count >= 3 else { throw InterpreterError.stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let src) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let dst) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let eiFC12 = Int(elemIdxFC12)
        let tiFC12 = Int(tableIdxFC12)
        guard eiFC12 < moduleRef.pointee.elements.count else {
          throw InterpreterError.undefinedElement
        }
        guard tiFC12 < tables.tableCount else { throw InterpreterError.undefinedElement }
        let copyCountFC12 = Int(UInt32(bitPattern: n))
        // A dropped element segment has effective length 0.
        let elemLenFC12 =
          droppedElem & (UInt64(1) << eiFC12) != 0
          ? 0 : moduleRef.pointee.elements[eiFC12].functionIndices.count
        let srcOffFC12 = Int(UInt32(bitPattern: src))
        let dstOffFC12 = Int(UInt32(bitPattern: dst))
        // Bounds check: applied unconditionally.
        guard srcOffFC12 + copyCountFC12 <= elemLenFC12 else {
          throw InterpreterError.undefinedElement
        }
        guard dstOffFC12 + copyCountFC12 <= tables.count(ofTable: tiFC12) else {
          throw InterpreterError.undefinedElement
        }
        if copyCountFC12 > 0 {
          let elemsFC12 = moduleRef.pointee.elements[eiFC12].functionIndices
          let tableRefTypeFC12 =
            tiFC12 < moduleRef.pointee.tables.count
            ? moduleRef.pointee.tables[tiFC12].refType : .funcRef
          for i in 0..<copyCountFC12 {
            tables[tiFC12, dstOffFC12 + i] =
              tableRefTypeFC12 == .externRef
              ? .externref(elemsFC12[srcOffFC12 + i]) : .funcref(elemsFC12[srcOffFC12 + i])
          }
        }
        frames.setIp(at: fi, UInt32(cursor))

      case 13:  // elem.drop  immediate: elemidx (u32)
        let elemIdxFC13 = try readU32Local()
        let eiFC13 = Int(elemIdxFC13)
        guard eiFC13 < moduleRef.pointee.elements.count else {
          throw InterpreterError.undefinedElement
        }
        droppedElem |= UInt64(1) << eiFC13
        frames.setIp(at: fi, UInt32(cursor))

      case 14:  // table.copy  immediates: dst_tableidx (u32), src_tableidx (u32)
        let dstIdxFC14 = try readU32Local()
        let srcIdxFC14 = try readU32Local()
        guard valueStack.count >= 3 else { throw InterpreterError.stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let src) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        guard case .i32(let dst) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let diFC14 = Int(dstIdxFC14)
        let siFC14 = Int(srcIdxFC14)
        guard diFC14 < tables.tableCount && siFC14 < tables.tableCount else {
          throw InterpreterError.undefinedElement
        }
        let copyCountFC14 = Int(UInt32(bitPattern: n))
        let srcOffFC14 = Int(UInt32(bitPattern: src))
        let dstOffFC14 = Int(UInt32(bitPattern: dst))
        // Bounds check: applied unconditionally.
        guard srcOffFC14 + copyCountFC14 <= tables.count(ofTable: siFC14) else {
          throw InterpreterError.undefinedElement
        }
        guard dstOffFC14 + copyCountFC14 <= tables.count(ofTable: diFC14) else {
          throw InterpreterError.undefinedElement
        }
        if copyCountFC14 > 0 {
          if diFC14 == siFC14 {
            // Same table: overlap-safe copy (memmove semantics).
            if dstOffFC14 <= srcOffFC14 || dstOffFC14 >= srcOffFC14 + copyCountFC14 {
              for i in 0..<copyCountFC14 {
                tables[diFC14, dstOffFC14 + i] = tables[siFC14, srcOffFC14 + i]
              }
            } else {
              for i in stride(from: copyCountFC14 - 1, through: 0, by: -1) {
                tables[diFC14, dstOffFC14 + i] = tables[siFC14, srcOffFC14 + i]
              }
            }
          } else {
            // Different tables: no aliasing possible; always copy forward.
            for i in 0..<copyCountFC14 {
              tables[diFC14, dstOffFC14 + i] = tables[siFC14, srcOffFC14 + i]
            }
          }
        }
        frames.setIp(at: fi, UInt32(cursor))

      case 15:  // table.grow  immediate: tableidx (u32)
        let tableIdxFC15 = try readU32Local()
        guard valueStack.count >= 2 else { throw InterpreterError.stackUnderflow }
        guard case .i32(let delta) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        // Accept any reference type (funcref or externref) as the fill value.
        let refValFC15 = valueStack.removeLast()
        switch refValFC15 {
        case .funcref, .externref: break
        default: throw InterpreterError.typeMismatch
        }
        let tiFC15 = Int(tableIdxFC15)
        guard tiFC15 < tables.tableCount else { throw InterpreterError.undefinedElement }
        // Treat delta as unsigned per Wasm spec — guard before converting to Int
        // to avoid a trap on 32-bit RP2350 when the unsigned value > Int32.max.
        let nFC15u = UInt32(bitPattern: delta)
        let tableMaxFC15 =
          tiFC15 < moduleRef.pointee.tables.count
          ? moduleRef.pointee.tables[tiFC15].max.map(Int.init) : nil
        let growResultFC15: Int32
        // Compare in UInt64 to avoid UInt32(Int.max) truncation on 64-bit macOS.
        if UInt64(nFC15u) > UInt64(Int.max) {
          growResultFC15 = -1  // unsigned delta exceeds addressable range — fail
        } else {
          growResultFC15 = tables.grow(
            tiFC15, by: Int(nFC15u), fillValue: refValFC15, max: tableMaxFC15)
        }
        valueStack.append(.i32(growResultFC15))
        frames.setIp(at: fi, UInt32(cursor))

      case 16:  // table.size  immediate: tableidx (u32)
        let tableIdxFC16 = try readU32Local()
        let tiFC16 = Int(tableIdxFC16)
        guard tiFC16 < tables.tableCount else { throw InterpreterError.undefinedElement }
        valueStack.append(.i32(Int32(tables.count(ofTable: tiFC16))))
        frames.setIp(at: fi, UInt32(cursor))

      case 17:  // table.fill  immediate: tableidx (u32)
        let tableIdxFC17 = try readU32Local()
        guard valueStack.count >= 3 else { throw InterpreterError.stackUnderflow }
        guard case .i32(let n) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let fillRefFC17 = valueStack.removeLast()
        guard case .i32(let dst) = valueStack.removeLast() else {
          throw InterpreterError.typeMismatch
        }
        let tiFC17 = Int(tableIdxFC17)
        guard tiFC17 < tables.tableCount else { throw InterpreterError.undefinedElement }
        // Verify the fill value type matches the table's declared refType.
        let tableFillRefTypeFC17 =
          tiFC17 < moduleRef.pointee.tables.count
          ? moduleRef.pointee.tables[tiFC17].refType : .funcRef
        switch (tableFillRefTypeFC17, fillRefFC17) {
        case (.funcRef, .funcref), (.externRef, .externref): break
        default: throw InterpreterError.typeMismatch
        }
        let dstOffFC17 = Int(UInt32(bitPattern: dst))
        let fillCountFC17 = Int(UInt32(bitPattern: n))
        // Bounds check: applied unconditionally.
        guard dstOffFC17 + fillCountFC17 <= tables.count(ofTable: tiFC17) else {
          throw InterpreterError.undefinedElement
        }
        for i in 0..<fillCountFC17 {
          tables[tiFC17, dstOffFC17 + i] = fillRefFC17
        }
        frames.setIp(at: fi, UInt32(cursor))

      default:
        throw InterpreterError.invalidInstruction(0xFC)
      }

    // MARK: Default — unimplemented opcode

    default:
      throw InterpreterError.invalidInstruction(opcode)
    }
  }
}
