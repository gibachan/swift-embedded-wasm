// Wasm stack machine interpreter — host type definitions and call dispatch
//
// Execution is performed by runIterativeEmbedded() in WasmInterpreterEmbedded.swift,
// which decodes opcodes on-the-fly from module.rawBytes using the pre-computed jump
// table (FunctionHandle.jumpTable) for O(1) control-flow resolution.
//
// This file contains: host function type definitions, HostImport, and the public
// call/callExport entry points that dispatch to the shared execution engine.

// MARK: - Host Function Types

/// Type of a host-provided function.
/// args: argument values, memory: read-only view of linear memory.
typealias HostFunction = ([Value], [UInt8]) -> [Value]

// TODO: Phase 4 — unify HostFunction and HostFunctionPtr into a single calling convention,
// eliminating the #if hasFeature(Embedded) branches throughout this file.
#if hasFeature(Embedded)
  /// @convention(c) function pointer for host-provided functions in Embedded builds.
  /// No heap allocation — host functions must use globals for any state they need.
  ///
  /// Parameters:
  ///   - args:        raw pointer to argument Values (reinterpret as UnsafePointer<Value> inside callee)
  ///   - argsCount:   number of arguments
  ///   - memory:      pointer to linear memory bytes (nil if no memory)
  ///   - memorySize:  number of bytes in linear memory
  ///   - results:     raw pointer to pre-allocated result buffer (nil if 0 results)
  ///
  /// UnsafeRawPointer / UnsafeMutableRawPointer are used instead of UnsafePointer<Value> /
  /// UnsafeMutablePointer<Value> because `Value` is a Swift enum and is not representable
  /// in @convention(c) function pointer signatures.
  typealias HostFunctionPtr =
    @convention(c) (
      UnsafeRawPointer?,
      Int32,
      UnsafeMutablePointer<UInt8>?,
      Int32,
      UnsafeMutableRawPointer?
    ) -> Void
#endif

/// Import bindings provided by the host at instantiation time.
///
/// Module and field names are `StaticString` (compile-time constants) so that
/// no heap allocation is required in Embedded Swift environments.
/// String literals are accepted directly without any change at the call site.
///
/// In non-Embedded builds, `functionDyn` and `memoryDyn` variants are also available
/// for test infrastructure that constructs names from runtime byte arrays.
/// In Embedded builds, `.function` accepts a `HostFunctionPtr` (@convention(c) pointer)
/// instead of a `HostFunction` closure to avoid heap allocation.
enum HostImport {
  #if hasFeature(Embedded)
    case function(StaticString, StaticString, HostFunctionPtr)  // (module, name, body)
    case memory(StaticString, StaticString, UInt32)  // (module, name, pages)
  #else
    case function(StaticString, StaticString, HostFunction)  // (module, name, body)
    case memory(StaticString, StaticString, UInt32)  // (module, name, pages)
    case functionDyn([UInt8], [UInt8], HostFunction)  // (moduleBytes, nameBytes, body)
    case memoryDyn([UInt8], [UInt8], UInt32)  // (moduleBytes, nameBytes, pages)
  #endif
}

// MARK: - Fixed4_HostImport

/// Stack-allocated container for up to 4 HostImport values.
/// Conforms to Sequence so it can be passed to WasmInterpreter.init in place of [HostImport].
/// On Embedded, this avoids the heap allocation that [HostImport] would require.
struct Fixed4_HostImport: Sequence {
  private var e0: HostImport?
  private var e1: HostImport?
  private var e2: HostImport?
  private var e3: HostImport?
  private(set) var count: Int = 0

  init() {}

  mutating func append(_ hi: HostImport) {
    if count < 4 {
      switch count {
      case 0: e0 = hi
      case 1: e1 = hi
      case 2: e2 = hi
      case 3: e3 = hi
      default: break
      }
      count += 1
    }
  }

  struct Iterator: IteratorProtocol {
    let base: Fixed4_HostImport
    var index: Int = 0
    mutating func next() -> HostImport? {
      guard index < base.count else { return nil }
      defer { index += 1 }
      switch index {
      case 0: return base.e0
      case 1: return base.e1
      case 2: return base.e2
      case 3: return base.e3
      default: return nil
      }
    }
  }

  func makeIterator() -> Iterator { Iterator(base: self) }
}

// MARK: - Fixed32_HostFunctionPtr (Embedded only)

// 32-slot fixed buffer for Embedded host functions (max WasmLimits.maxImports = 32).
// Eliminates the heap-allocated [HostFunctionPtr] array used during init.
// @convention(c) function pointers are pointer-sized and behave as bitwise-copyable
// values; withUnsafeBytes is safe for read access (no write access needed since
// hostFunctions is a `let` property — it is never mutated after init).
#if hasFeature(Embedded)
  struct Fixed32_HostFunctionPtr {
    private var s0, s1, s2,
      s3:
        (
          HostFunctionPtr, HostFunctionPtr, HostFunctionPtr, HostFunctionPtr,
          HostFunctionPtr, HostFunctionPtr, HostFunctionPtr, HostFunctionPtr
        )
    private var _count: Int

    init() {
      // Swift requires a zero-value function pointer to initialise the tuple.
      // This sentinel value is never called; it only fills uninitialised slots.
      let z: HostFunctionPtr = { _, _, _, _, _ in }
      let row = (z, z, z, z, z, z, z, z)
      s0 = row
      s1 = row
      s2 = row
      s3 = row
      _count = 0
    }

    var count: Int { _count }

    @inline(__always)
    subscript(index: Int) -> HostFunctionPtr {
      precondition(index >= 0 && index < _count)
      let row = index / 8
      let col = index % 8
      return withRow(row) { $0[col] }
    }

    @inline(__always)
    private func withRow<R>(_ row: Int, _ body: (UnsafePointer<HostFunctionPtr>) -> R) -> R {
      switch row {
      case 0:
        return withUnsafeBytes(of: s0) {
          body($0.baseAddress!.assumingMemoryBound(to: HostFunctionPtr.self))
        }
      case 1:
        return withUnsafeBytes(of: s1) {
          body($0.baseAddress!.assumingMemoryBound(to: HostFunctionPtr.self))
        }
      case 2:
        return withUnsafeBytes(of: s2) {
          body($0.baseAddress!.assumingMemoryBound(to: HostFunctionPtr.self))
        }
      default:
        return withUnsafeBytes(of: s3) {
          body($0.baseAddress!.assumingMemoryBound(to: HostFunctionPtr.self))
        }
      }
    }

    mutating func append(_ fn: HostFunctionPtr) {
      precondition(_count < 32, "Fixed32_HostFunctionPtr overflow: maxImports exceeded")
      let row = _count / 8
      let col = _count % 8
      // Direct tuple-element assignment avoids withUnsafeMutableBytes on function pointers.
      switch row {
      case 0:
        switch col {
        case 0: s0.0 = fn
        case 1: s0.1 = fn
        case 2: s0.2 = fn
        case 3: s0.3 = fn
        case 4: s0.4 = fn
        case 5: s0.5 = fn
        case 6: s0.6 = fn
        default: s0.7 = fn
        }
      case 1:
        switch col {
        case 0: s1.0 = fn
        case 1: s1.1 = fn
        case 2: s1.2 = fn
        case 3: s1.3 = fn
        case 4: s1.4 = fn
        case 5: s1.5 = fn
        case 6: s1.6 = fn
        default: s1.7 = fn
        }
      case 2:
        switch col {
        case 0: s2.0 = fn
        case 1: s2.1 = fn
        case 2: s2.2 = fn
        case 3: s2.3 = fn
        case 4: s2.4 = fn
        case 5: s2.5 = fn
        case 6: s2.6 = fn
        default: s2.7 = fn
        }
      default:
        switch col {
        case 0: s3.0 = fn
        case 1: s3.1 = fn
        case 2: s3.2 = fn
        case 3: s3.3 = fn
        case 4: s3.4 = fn
        case 5: s3.5 = fn
        case 6: s3.6 = fn
        default: s3.7 = fn
        }
      }
      _count += 1
    }
  }
#endif

// Wasm f32.min: propagates NaN; treats -0 < +0
private func wasmF32Min(_ a: Float, _ b: Float) -> Float {
  if a.isNaN || b.isNaN { return .nan }
  if a == 0 && b == 0 { return (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0 }
  return Swift.min(a, b)
}

// Wasm f32.max: propagates NaN; treats +0 > -0
private func wasmF32Max(_ a: Float, _ b: Float) -> Float {
  if a.isNaN || b.isNaN { return .nan }
  if a == 0 && b == 0 { return (a.sign == .plus || b.sign == .plus) ? 0.0 : -0.0 }
  return Swift.max(a, b)
}

// Wasm f64.min: propagates NaN; treats -0 < +0
private func wasmF64Min(_ a: Double, _ b: Double) -> Double {
  if a.isNaN || b.isNaN { return .nan }
  if a == 0 && b == 0 { return (a.sign == .minus || b.sign == .minus) ? -0.0 : 0.0 }
  return Swift.min(a, b)
}

// Wasm f64.max: propagates NaN; treats +0 > -0
private func wasmF64Max(_ a: Double, _ b: Double) -> Double {
  if a.isNaN || b.isNaN { return .nan }
  if a == 0 && b == 0 { return (a.sign == .plus || b.sign == .plus) ? 0.0 : -0.0 }
  return Swift.max(a, b)
}

// MARK: - Label (replaces Scope)

// internal (no modifier) so that WasmInterpreterEmbedded.swift (a separate file in the same
// module) can reference LabelKind and Label.  swift-format's FileScopedDeclarationPrivacy rule
// converts 'fileprivate' → 'private' on file-scoped declarations, breaking cross-file access;
// 'internal' (implicit) is the correct level for intra-module sharing.
enum LabelKind {
  case block  // br exits; jump to continuationPc (past blockEnd)
  case loop  // br restarts; jump to continuationPc (= startPc); label stays on stack
  case ifElse  // br exits; same as block
}

struct Label {
  let kind: LabelKind
  let stackBase: Int  // value stack depth when this label was entered
  let brArity: Int  // values carried by br (block/if: result count; loop: param count)
  let continuationPc: Int  // where br to this label jumps:
  //   block/if: past blockEnd (= blockEndPc + 1)
  //   loop:     first body instruction (restart)

  /// Zero-value sentinel used to fill uninitialised slots in the fixed-size label buffer.
  /// Never used as a live label; only serves as a default to satisfy Swift's requirement
  /// that tuple elements are initialised at construction time.
  static let zero = Label(kind: .block, stackBase: 0, brArity: 0, continuationPc: 0)
}

// block/loop/if arity is now pre-computed at parse time and stored directly in each
// Instruction case (brArity, paramCount fields). The blockArity() / loopBrArity()
// helpers that previously looked up module.types at runtime have been removed.

// MARK: - Fixed-size buffer types

// These types are shared across macOS and Embedded builds.
// On macOS, EmbeddedValueStack / EmbeddedCallStack are type-aliased to these types
// (see WasmInterpreterEmbedded.swift), so the same dispatchEmbedded implementation
// compiles for both targets without conditional compilation.

// MARK: LabelStack

/// Label stack used in EmbeddedFrame on both macOS and Embedded builds.
///
/// Provides the same public API on both platforms so that call sites in
/// dispatchEmbedded / handleEmbeddedBranch / pushEmbeddedFrame require no conditional
/// compilation beyond the single #if inside this struct.
///
/// Embedded builds: storage is a 32-element homogeneous tuple on the C stack — no malloc.
/// macOS builds:    storage is a [Label] array (heap-allocated) to keep EmbeddedFrame
///                  small (~56 bytes) so that CallStack (64 frames) fits on the call stack.
///
/// The single #if hasFeature(Embedded) inside this struct is Approach A from the
/// design notes: one conditional at the boundary between stack and heap storage, with a
/// uniform API exposed to all callers.
struct LabelStack {
  #if hasFeature(Embedded)
    // 8-element tuple (was 32); reduces EmbeddedFrame from 540 → 156 bytes so that the
    // multiple frame temporaries created by the subscript get accessor fit in the RP2040's
    // 4 KB main stack.  Wasm programs that nest more than 8 block/loop/if levels will
    // hit the precondition in append(_:) — acceptable for the current Pico demos.
    // See WasmLimits.maxLabelDepth for the matching runtime limit.
    private var storage: (Label, Label, Label, Label, Label, Label, Label, Label)  // 0-7
    private var _count: Int

    init() {
      let z = Label.zero
      storage = (z, z, z, z, z, z, z, z)
      _count = 0
    }

    var count: Int { _count }

    var isEmpty: Bool { _count == 0 }

    @inline(__always)
    mutating func append(_ label: Label) {
      precondition(_count < WasmLimits.maxLabelDepth, "LabelStack overflow")
      withUnsafeMutableBytes(of: &storage) { buf in
        let ptr = buf.baseAddress!.assumingMemoryBound(to: Label.self)
        ptr[_count] = label
      }
      _count &+= 1
    }

    @inline(__always)
    subscript(index: Int) -> Label {
      get {
        withUnsafeBytes(of: storage) { buf in
          let ptr = buf.baseAddress!.assumingMemoryBound(to: Label.self)
          return ptr[index]
        }
      }
      set {
        withUnsafeMutableBytes(of: &storage) { buf in
          let ptr = buf.baseAddress!.assumingMemoryBound(to: Label.self)
          ptr[index] = newValue
        }
      }
    }

    @inline(__always)
    mutating func removeSubrange(_ startIndex: Int) {
      guard startIndex < _count else { return }
      _count = startIndex
    }

    @inline(__always)
    mutating func removeSubrange(_ range: PartialRangeFrom<Int>) {
      removeSubrange(range.lowerBound)
    }

    @inline(__always)
    mutating func removeAll() {
      _count = 0
    }

    @inline(__always)
    @discardableResult
    mutating func removeLast() -> Label {
      let val = self[_count - 1]
      _count &-= 1
      return val
    }

    var last: Label { self[_count - 1] }

  #else
    // macOS: heap-allocated to keep EmbeddedFrame small so CallStack fits on the stack.
    // TODO: Embedded Phase 5 — remove this branch once the Embedded path is the only target.
    private var storage: [Label]  // TODO: Embedded Phase 5 — replace with tuple storage

    init() { storage = [] }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }

    @inline(__always)
    mutating func append(_ label: Label) {
      precondition(storage.count < WasmLimits.maxLabelDepth, "LabelStack overflow")
      storage.append(label)
    }

    @inline(__always)
    subscript(index: Int) -> Label {
      get { storage[index] }
      set { storage[index] = newValue }
    }

    @inline(__always)
    mutating func removeSubrange(_ startIndex: Int) {
      guard startIndex < storage.count else { return }
      storage.removeSubrange(startIndex...)
    }

    @inline(__always)
    mutating func removeSubrange(_ range: PartialRangeFrom<Int>) {
      guard range.lowerBound < storage.count else { return }
      storage.removeSubrange(range)
    }

    @inline(__always)
    mutating func removeAll() { storage.removeAll() }

    @inline(__always)
    @discardableResult
    mutating func removeLast() -> Label { storage.removeLast() }

    var last: Label { storage[storage.count - 1] }
  #endif
}

// MARK: ValueStack

/// Fixed-size value (operand) stack shared across macOS and Embedded builds
/// (max WasmLimits.maxValueStackDepth = 256 entries).
///
/// Stores elements in a 256-element contiguous tuple on (or close to) the C stack.
/// The same homogeneous-tuple layout guarantee applies as for LabelStack.
struct ValueStack {
  // 256-element storage packed as 32 × 8-element sub-tuples to keep the struct
  // declaration manageable.  The overall layout is identical to a 256-element tuple.
  private var s0: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s1: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s2: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s3: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s4: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s5: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s6: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s7: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s8: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s9: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s10: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s11: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s12: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s13: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s14: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s15: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s16: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s17: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s18: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s19: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s20: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s21: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s22: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s23: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s24: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s25: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s26: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s27: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s28: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s29: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s30: (Value, Value, Value, Value, Value, Value, Value, Value)
  private var s31: (Value, Value, Value, Value, Value, Value, Value, Value)

  private var _count: Int

  init() {
    let z = Value.i32(0)
    let row = (z, z, z, z, z, z, z, z)
    s0 = row
    s1 = row
    s2 = row
    s3 = row
    s4 = row
    s5 = row
    s6 = row
    s7 = row
    s8 = row
    s9 = row
    s10 = row
    s11 = row
    s12 = row
    s13 = row
    s14 = row
    s15 = row
    s16 = row
    s17 = row
    s18 = row
    s19 = row
    s20 = row
    s21 = row
    s22 = row
    s23 = row
    s24 = row
    s25 = row
    s26 = row
    s27 = row
    s28 = row
    s29 = row
    s30 = row
    s31 = row
    _count = 0
  }

  // mutating get: self is passed by reference (inout ABI), no 4 KB stack copy.
  // Callers access this via an inout EmbeddedValueStack — mutating avoids the copy-in.
  var count: Int { mutating get { _count } }

  var isEmpty: Bool { mutating get { _count == 0 } }

  // Indexed access.  @inline(never) on both get and set keeps the 32-case switch out of
  // dispatchEmbedded's stack frame — the same pattern used for CallStack accessors.
  // mutating get: self is passed by reference (inout ABI), no 4 KB ValueStack copy.
  subscript(index: Int) -> Value {
    @inline(never) mutating get {
      switch index / 8 {
      case 0:
        switch index % 8 {
        case 0: return s0.0
        case 1: return s0.1
        case 2: return s0.2
        case 3: return s0.3
        case 4: return s0.4
        case 5: return s0.5
        case 6: return s0.6
        default: return s0.7
        }
      case 1:
        switch index % 8 {
        case 0: return s1.0
        case 1: return s1.1
        case 2: return s1.2
        case 3: return s1.3
        case 4: return s1.4
        case 5: return s1.5
        case 6: return s1.6
        default: return s1.7
        }
      case 2:
        switch index % 8 {
        case 0: return s2.0
        case 1: return s2.1
        case 2: return s2.2
        case 3: return s2.3
        case 4: return s2.4
        case 5: return s2.5
        case 6: return s2.6
        default: return s2.7
        }
      case 3:
        switch index % 8 {
        case 0: return s3.0
        case 1: return s3.1
        case 2: return s3.2
        case 3: return s3.3
        case 4: return s3.4
        case 5: return s3.5
        case 6: return s3.6
        default: return s3.7
        }
      case 4:
        switch index % 8 {
        case 0: return s4.0
        case 1: return s4.1
        case 2: return s4.2
        case 3: return s4.3
        case 4: return s4.4
        case 5: return s4.5
        case 6: return s4.6
        default: return s4.7
        }
      case 5:
        switch index % 8 {
        case 0: return s5.0
        case 1: return s5.1
        case 2: return s5.2
        case 3: return s5.3
        case 4: return s5.4
        case 5: return s5.5
        case 6: return s5.6
        default: return s5.7
        }
      case 6:
        switch index % 8 {
        case 0: return s6.0
        case 1: return s6.1
        case 2: return s6.2
        case 3: return s6.3
        case 4: return s6.4
        case 5: return s6.5
        case 6: return s6.6
        default: return s6.7
        }
      case 7:
        switch index % 8 {
        case 0: return s7.0
        case 1: return s7.1
        case 2: return s7.2
        case 3: return s7.3
        case 4: return s7.4
        case 5: return s7.5
        case 6: return s7.6
        default: return s7.7
        }
      case 8:
        switch index % 8 {
        case 0: return s8.0
        case 1: return s8.1
        case 2: return s8.2
        case 3: return s8.3
        case 4: return s8.4
        case 5: return s8.5
        case 6: return s8.6
        default: return s8.7
        }
      case 9:
        switch index % 8 {
        case 0: return s9.0
        case 1: return s9.1
        case 2: return s9.2
        case 3: return s9.3
        case 4: return s9.4
        case 5: return s9.5
        case 6: return s9.6
        default: return s9.7
        }
      case 10:
        switch index % 8 {
        case 0: return s10.0
        case 1: return s10.1
        case 2: return s10.2
        case 3: return s10.3
        case 4: return s10.4
        case 5: return s10.5
        case 6: return s10.6
        default: return s10.7
        }
      case 11:
        switch index % 8 {
        case 0: return s11.0
        case 1: return s11.1
        case 2: return s11.2
        case 3: return s11.3
        case 4: return s11.4
        case 5: return s11.5
        case 6: return s11.6
        default: return s11.7
        }
      case 12:
        switch index % 8 {
        case 0: return s12.0
        case 1: return s12.1
        case 2: return s12.2
        case 3: return s12.3
        case 4: return s12.4
        case 5: return s12.5
        case 6: return s12.6
        default: return s12.7
        }
      case 13:
        switch index % 8 {
        case 0: return s13.0
        case 1: return s13.1
        case 2: return s13.2
        case 3: return s13.3
        case 4: return s13.4
        case 5: return s13.5
        case 6: return s13.6
        default: return s13.7
        }
      case 14:
        switch index % 8 {
        case 0: return s14.0
        case 1: return s14.1
        case 2: return s14.2
        case 3: return s14.3
        case 4: return s14.4
        case 5: return s14.5
        case 6: return s14.6
        default: return s14.7
        }
      case 15:
        switch index % 8 {
        case 0: return s15.0
        case 1: return s15.1
        case 2: return s15.2
        case 3: return s15.3
        case 4: return s15.4
        case 5: return s15.5
        case 6: return s15.6
        default: return s15.7
        }
      case 16:
        switch index % 8 {
        case 0: return s16.0
        case 1: return s16.1
        case 2: return s16.2
        case 3: return s16.3
        case 4: return s16.4
        case 5: return s16.5
        case 6: return s16.6
        default: return s16.7
        }
      case 17:
        switch index % 8 {
        case 0: return s17.0
        case 1: return s17.1
        case 2: return s17.2
        case 3: return s17.3
        case 4: return s17.4
        case 5: return s17.5
        case 6: return s17.6
        default: return s17.7
        }
      case 18:
        switch index % 8 {
        case 0: return s18.0
        case 1: return s18.1
        case 2: return s18.2
        case 3: return s18.3
        case 4: return s18.4
        case 5: return s18.5
        case 6: return s18.6
        default: return s18.7
        }
      case 19:
        switch index % 8 {
        case 0: return s19.0
        case 1: return s19.1
        case 2: return s19.2
        case 3: return s19.3
        case 4: return s19.4
        case 5: return s19.5
        case 6: return s19.6
        default: return s19.7
        }
      case 20:
        switch index % 8 {
        case 0: return s20.0
        case 1: return s20.1
        case 2: return s20.2
        case 3: return s20.3
        case 4: return s20.4
        case 5: return s20.5
        case 6: return s20.6
        default: return s20.7
        }
      case 21:
        switch index % 8 {
        case 0: return s21.0
        case 1: return s21.1
        case 2: return s21.2
        case 3: return s21.3
        case 4: return s21.4
        case 5: return s21.5
        case 6: return s21.6
        default: return s21.7
        }
      case 22:
        switch index % 8 {
        case 0: return s22.0
        case 1: return s22.1
        case 2: return s22.2
        case 3: return s22.3
        case 4: return s22.4
        case 5: return s22.5
        case 6: return s22.6
        default: return s22.7
        }
      case 23:
        switch index % 8 {
        case 0: return s23.0
        case 1: return s23.1
        case 2: return s23.2
        case 3: return s23.3
        case 4: return s23.4
        case 5: return s23.5
        case 6: return s23.6
        default: return s23.7
        }
      case 24:
        switch index % 8 {
        case 0: return s24.0
        case 1: return s24.1
        case 2: return s24.2
        case 3: return s24.3
        case 4: return s24.4
        case 5: return s24.5
        case 6: return s24.6
        default: return s24.7
        }
      case 25:
        switch index % 8 {
        case 0: return s25.0
        case 1: return s25.1
        case 2: return s25.2
        case 3: return s25.3
        case 4: return s25.4
        case 5: return s25.5
        case 6: return s25.6
        default: return s25.7
        }
      case 26:
        switch index % 8 {
        case 0: return s26.0
        case 1: return s26.1
        case 2: return s26.2
        case 3: return s26.3
        case 4: return s26.4
        case 5: return s26.5
        case 6: return s26.6
        default: return s26.7
        }
      case 27:
        switch index % 8 {
        case 0: return s27.0
        case 1: return s27.1
        case 2: return s27.2
        case 3: return s27.3
        case 4: return s27.4
        case 5: return s27.5
        case 6: return s27.6
        default: return s27.7
        }
      case 28:
        switch index % 8 {
        case 0: return s28.0
        case 1: return s28.1
        case 2: return s28.2
        case 3: return s28.3
        case 4: return s28.4
        case 5: return s28.5
        case 6: return s28.6
        default: return s28.7
        }
      case 29:
        switch index % 8 {
        case 0: return s29.0
        case 1: return s29.1
        case 2: return s29.2
        case 3: return s29.3
        case 4: return s29.4
        case 5: return s29.5
        case 6: return s29.6
        default: return s29.7
        }
      case 30:
        switch index % 8 {
        case 0: return s30.0
        case 1: return s30.1
        case 2: return s30.2
        case 3: return s30.3
        case 4: return s30.4
        case 5: return s30.5
        case 6: return s30.6
        default: return s30.7
        }
      default:
        switch index % 8 {
        case 0: return s31.0
        case 1: return s31.1
        case 2: return s31.2
        case 3: return s31.3
        case 4: return s31.4
        case 5: return s31.5
        case 6: return s31.6
        default: return s31.7
        }
      }
    }
    @inline(never) set {
      let row = index / 8
      let col = index % 8
      withMutableRow(row) { ptr in ptr[col] = newValue }
    }
  }

  @inline(__always)
  private mutating func withMutableRow<R>(_ row: Int, _ body: (UnsafeMutablePointer<Value>) -> R)
    -> R
  {
    switch row {
    case 0:
      return withUnsafeMutableBytes(of: &s0) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 1:
      return withUnsafeMutableBytes(of: &s1) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 2:
      return withUnsafeMutableBytes(of: &s2) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 3:
      return withUnsafeMutableBytes(of: &s3) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 4:
      return withUnsafeMutableBytes(of: &s4) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 5:
      return withUnsafeMutableBytes(of: &s5) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 6:
      return withUnsafeMutableBytes(of: &s6) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 7:
      return withUnsafeMutableBytes(of: &s7) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 8:
      return withUnsafeMutableBytes(of: &s8) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 9:
      return withUnsafeMutableBytes(of: &s9) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 10:
      return withUnsafeMutableBytes(of: &s10) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 11:
      return withUnsafeMutableBytes(of: &s11) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 12:
      return withUnsafeMutableBytes(of: &s12) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 13:
      return withUnsafeMutableBytes(of: &s13) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 14:
      return withUnsafeMutableBytes(of: &s14) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 15:
      return withUnsafeMutableBytes(of: &s15) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 16:
      return withUnsafeMutableBytes(of: &s16) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 17:
      return withUnsafeMutableBytes(of: &s17) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 18:
      return withUnsafeMutableBytes(of: &s18) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 19:
      return withUnsafeMutableBytes(of: &s19) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 20:
      return withUnsafeMutableBytes(of: &s20) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 21:
      return withUnsafeMutableBytes(of: &s21) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 22:
      return withUnsafeMutableBytes(of: &s22) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 23:
      return withUnsafeMutableBytes(of: &s23) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 24:
      return withUnsafeMutableBytes(of: &s24) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 25:
      return withUnsafeMutableBytes(of: &s25) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 26:
      return withUnsafeMutableBytes(of: &s26) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 27:
      return withUnsafeMutableBytes(of: &s27) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 28:
      return withUnsafeMutableBytes(of: &s28) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 29:
      return withUnsafeMutableBytes(of: &s29) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    case 30:
      return withUnsafeMutableBytes(of: &s30) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    default:
      return withUnsafeMutableBytes(of: &s31) {
        body($0.baseAddress!.assumingMemoryBound(to: Value.self))
      }
    }
  }

  /// Append a value.  Traps (preconditionFailure) when the 256-entry limit is reached.
  ///
  /// Non-throwing to maintain API compatibility with [Value].append(_:).
  /// Overflow is a programming error; the 256-slot limit is deliberately large enough
  /// for any well-behaved Wasm module targeting the RP2350.
  @inline(__always)
  mutating func append(_ value: Value) {
    precondition(_count < WasmLimits.maxValueStackDepth, "ValueStack overflow")
    self[_count] = value
    _count &+= 1
  }

  /// Pop and return the top value.
  ///
  /// Non-throwing to maintain API compatibility with [Value].removeLast().
  /// Callers that pop from the stack should guard count > 0 before calling (matching
  /// the guard...throw .stackUnderflow pattern used throughout dispatchEmbedded).
  @inline(__always)
  @discardableResult
  mutating func removeLast() -> Value {
    _count &-= 1
    return self[_count]
  }

  /// Remove the top `k` values without returning them.
  @inline(__always)
  mutating func removeLast(_ k: Int) {
    precondition(k >= 0 && k <= _count, "ValueStack removeLast underflow")
    _count -= k
  }

  /// Remove all entries from `startIndex` onwards (Int overload).
  @inline(__always)
  mutating func removeSubrange(_ startIndex: Int) {
    guard startIndex < _count else { return }
    _count = startIndex
  }

  /// Remove all entries from `range.lowerBound` onwards (PartialRangeFrom<Int> overload).
  /// Matches [Value].removeSubrange(_:) when called as removeSubrange(n...).
  @inline(__always)
  mutating func removeSubrange(_ range: PartialRangeFrom<Int>) {
    removeSubrange(range.lowerBound)
  }

  /// The top value (last pushed).  Caller must ensure count > 0.
  var last: Value { mutating get { self[_count - 1] } }

  /// The value at `offset` positions below the top (0 = top).
  @inline(__always)
  mutating func peekFromTop(_ offset: Int) -> Value { self[_count - 1 - offset] }

  /// Append the contents of an array (used for seeding args at call site).
  @inline(__always)
  mutating func append(contentsOf arr: [Value]) {
    for v in arr { append(v) }
  }

  /// Collect all values into a [Value] result array (used for returning results).
  mutating func toArray() -> [Value] {
    var out: [Value] = []
    for i in 0..<_count { out.append(self[i]) }
    return out
  }

  /// O(1) reset — clears the logical count without zeroing storage.
  /// Used by the Embedded global-stack pattern to re-use storage across executions.
  mutating func reset() { _count = 0 }
}

// MARK: CallStack

/// Fixed-size call stack shared across macOS and Embedded builds (max WasmLimits.maxCallDepth = 64 frames).
///
/// Holds EmbeddedFrame values in a 64-element tuple.  Same layout guarantee as LabelStack.
///
/// On macOS, LabelStack uses heap-allocated [Label] storage, so EmbeddedFrame is ~56 bytes
/// and 64 frames occupy ~3.5 KB on the call stack — well within macOS thread stack limits.
/// On Embedded, LabelStack uses a 32-element tuple (~1 KB per frame), so CallStack is ~67 KB —
/// acceptable for the RP2350 but requires the interpreter entry point to run on a thread
/// with adequate stack space.
struct CallStack {
  private var s0:
    (
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame,
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame
    )
  private var s1:
    (
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame,
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame
    )
  private var s2:
    (
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame,
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame
    )
  private var s3:
    (
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame,
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame
    )
  private var s4:
    (
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame,
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame
    )
  private var s5:
    (
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame,
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame
    )
  private var s6:
    (
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame,
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame
    )
  private var s7:
    (
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame,
      EmbeddedFrame, EmbeddedFrame, EmbeddedFrame, EmbeddedFrame
    )
  private var _count: Int

  init() {
    let z = EmbeddedFrame.zero
    let row = (z, z, z, z, z, z, z, z)
    s0 = row
    s1 = row
    s2 = row
    s3 = row
    s4 = row
    s5 = row
    s6 = row
    s7 = row
    _count = 0
  }

  // mutating get: self is passed by reference (inout ABI), no 10 KB CallStack copy.
  var count: Int { mutating get { _count } }

  var isEmpty: Bool { mutating get { _count == 0 } }

  @inline(__always)
  subscript(index: Int) -> EmbeddedFrame {
    get {
      let row = index / 8
      let col = index % 8
      return withRow(row) { ptr in ptr[col] }
    }
    set {
      let row = index / 8
      let col = index % 8
      withMutableRow(row) { ptr in ptr[col] = newValue }
    }
  }

  @inline(__always)
  private func withRow<R>(_ row: Int, _ body: (UnsafePointer<EmbeddedFrame>) -> R) -> R {
    switch row {
    case 0:
      return withUnsafeBytes(of: s0) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 1:
      return withUnsafeBytes(of: s1) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 2:
      return withUnsafeBytes(of: s2) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 3:
      return withUnsafeBytes(of: s3) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 4:
      return withUnsafeBytes(of: s4) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 5:
      return withUnsafeBytes(of: s5) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 6:
      return withUnsafeBytes(of: s6) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    default:
      return withUnsafeBytes(of: s7) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    }
  }

  @inline(__always)
  private mutating func withMutableRow<R>(
    _ row: Int, _ body: (UnsafeMutablePointer<EmbeddedFrame>) -> R
  ) -> R {
    switch row {
    case 0:
      return withUnsafeMutableBytes(of: &s0) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 1:
      return withUnsafeMutableBytes(of: &s1) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 2:
      return withUnsafeMutableBytes(of: &s2) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 3:
      return withUnsafeMutableBytes(of: &s3) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 4:
      return withUnsafeMutableBytes(of: &s4) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 5:
      return withUnsafeMutableBytes(of: &s5) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    case 6:
      return withUnsafeMutableBytes(of: &s6) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    default:
      return withUnsafeMutableBytes(of: &s7) {
        body($0.baseAddress!.assumingMemoryBound(to: EmbeddedFrame.self))
      }
    }
  }

  /// Append a frame.  Traps (preconditionFailure) when the 64-entry limit is reached.
  ///
  /// Non-throwing to maintain API compatibility with [EmbeddedFrame].append(_:).
  @inline(__always)
  mutating func append(_ frame: EmbeddedFrame) {
    precondition(_count < WasmLimits.maxCallDepth, "CallStack overflow")
    self[_count] = frame
    _count &+= 1
  }

  /// Remove and discard the top frame.
  @inline(__always)
  mutating func removeLast() {
    _count &-= 1
  }

  /// Top frame index (frames.count - 1).
  var topIndex: Int { _count - 1 }

  /// O(1) reset — clears the logical count without zeroing storage.
  /// Used by the Embedded global-stack pattern to re-use storage across executions.
  mutating func reset() { _count = 0 }

  // MARK: - Named field accessors (via withMutableRow — no sN copy)
  //
  // CallStack.subscript.get uses withRow → withUnsafeBytes(of: sN), which copies the
  // 1248-byte sN tuple to the stack on every frames[fi].field access.
  // These mutating accessors use withMutableRow → withUnsafeMutableBytes(of: &sN),
  // which passes a pointer to BSS storage without any copy.
  //
  // Used by dispatchEmbedded / handleEmbeddedBranch / _runIterativeEmbeddedCore so that
  // the Pico's 4 KB main stack is not overflowed on each opcode dispatch.
  // The macOS [EmbeddedFrame] type gets equivalent methods via extension (shim below).

  // @inline(never) prevents the 8-case withMutableRow switch from being expanded inline at
  // every call site in dispatchEmbedded.  With WMO the compiler would otherwise duplicate the
  // switch-8 body hundreds of times, inflating dispatchEmbedded's stack frame to ~344 KB.
  @inline(never) mutating func ip(at i: Int) -> UInt32 {
    withMutableRow(i / 8) { $0[i % 8].ip }
  }
  @inline(never) mutating func setIp(at i: Int, _ v: UInt32) {
    withMutableRow(i / 8) { $0[i % 8].ip = v }
  }
  @inline(never) mutating func jumpCursor(at i: Int) -> Int {
    withMutableRow(i / 8) { $0[i % 8].jumpCursor }
  }
  @inline(never) mutating func setJumpCursor(at i: Int, _ v: Int) {
    withMutableRow(i / 8) { $0[i % 8].jumpCursor = v }
  }
  @inline(never) mutating func incrementJumpCursor(at i: Int) {
    withMutableRow(i / 8) { $0[i % 8].jumpCursor &+= 1 }
  }
  @inline(never) mutating func handleIdx(at i: Int) -> Int {
    withMutableRow(i / 8) { $0[i % 8].handleIdx }
  }
  @inline(never) mutating func localBase(at i: Int) -> Int {
    withMutableRow(i / 8) { $0[i % 8].localBase }
  }
  @inline(never) mutating func localCount(at i: Int) -> Int {
    withMutableRow(i / 8) { $0[i % 8].localCount }
  }
  @inline(never) mutating func resultCount(at i: Int) -> Int {
    withMutableRow(i / 8) { $0[i % 8].resultCount }
  }
  @inline(never) mutating func labelsCount(at i: Int) -> Int {
    withMutableRow(i / 8) { $0[i % 8].labels.count }
  }
  @inline(never) mutating func labelsIsEmpty(at i: Int) -> Bool {
    withMutableRow(i / 8) { $0[i % 8].labels.isEmpty }
  }
  @inline(never) mutating func labelsLast(at i: Int) -> Label {
    withMutableRow(i / 8) { $0[i % 8].labels.last }
  }
  @inline(never) mutating func label(at i: Int, index j: Int) -> Label {
    withMutableRow(i / 8) { $0[i % 8].labels[j] }
  }
  @inline(never) mutating func appendLabel(at i: Int, _ label: Label) {
    withMutableRow(i / 8) { $0[i % 8].labels.append(label) }
  }
  @inline(never) @discardableResult mutating func removeLastLabel(at i: Int) -> Label {
    withMutableRow(i / 8) { $0[i % 8].labels.removeLast() }
  }
  @inline(never) mutating func clearLabels(at i: Int) {
    withMutableRow(i / 8) { $0[i % 8].labels.removeAll() }
  }
  @inline(never) mutating func removeLabels(at i: Int, from j: Int) {
    withMutableRow(i / 8) { $0[i % 8].labels.removeSubrange(j) }
  }
}

// MARK: FlatTableStorage

/// Fixed-size flat table storage (shared type; not yet wired to WasmInterpreter.tables — TODO: Embedded Phase 5).
///
/// The Wasm table is a sequence of reference values (funcref/externref).
/// All elements are packed into a single flat array of
/// WasmLimits.maxTables * WasmLimits.maxTableElements slots, with per-table
/// offsets and counts tracked separately.
///
/// Layout: tableSlot 0 occupies indices [0, maxTableElements),
///          tableSlot 1 occupies indices [maxTableElements, 2*maxTableElements), etc.
struct FlatTableStorage {
  private typealias Row = (Value, Value, Value, Value, Value, Value, Value, Value)
  #if hasFeature(Embedded)
    // Embedded: maxTables(4) × maxTableElements(16) = 64 slots, packed as 8 × 8-element rows.
    // Size ≈ 1 KB — safe to copy onto the 4 KB Pico stack as `var localTables = tables`.
    // The subscript uses withUnsafeBytes(of: storage) which adapts to any tuple size,
    // so this conditional only affects the tuple declaration and init.
    private var storage: (Row, Row, Row, Row, Row, Row, Row, Row)
  #else
    // macOS: maxTables(4) × maxTableElements(256) = 1024 slots, packed as 128 × 8-element rows.
    private var storage:
      (
        Row, Row, Row, Row, Row, Row, Row, Row,  // 0-7
        Row, Row, Row, Row, Row, Row, Row, Row,  // 8-15
        Row, Row, Row, Row, Row, Row, Row, Row,  // 16-23
        Row, Row, Row, Row, Row, Row, Row, Row,  // 24-31
        Row, Row, Row, Row, Row, Row, Row, Row,  // 32-39
        Row, Row, Row, Row, Row, Row, Row, Row,  // 40-47
        Row, Row, Row, Row, Row, Row, Row, Row,  // 48-55
        Row, Row, Row, Row, Row, Row, Row, Row,  // 56-63
        Row, Row, Row, Row, Row, Row, Row, Row,  // 64-71
        Row, Row, Row, Row, Row, Row, Row, Row,  // 72-79
        Row, Row, Row, Row, Row, Row, Row, Row,  // 80-87
        Row, Row, Row, Row, Row, Row, Row, Row,  // 88-95
        Row, Row, Row, Row, Row, Row, Row, Row,  // 96-103
        Row, Row, Row, Row, Row, Row, Row, Row,  // 104-111
        Row, Row, Row, Row, Row, Row, Row, Row,  // 112-119
        Row, Row, Row, Row, Row, Row, Row, Row  // 120-127
      )
  #endif
  // Per-table element counts (allocated sizes, not slot capacities).
  var tableCounts: (Int, Int, Int, Int)
  var tableCount: Int  // number of live tables (0..<tableCount are valid)

  init() {
    let z = Value.i32(0)
    let emptyRow: Row = (z, z, z, z, z, z, z, z)
    #if hasFeature(Embedded)
      storage = (emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow)
    #else
      // Initialise all 128 rows to the empty row sentinel.
      storage = (
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow,
        emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow, emptyRow
      )
    #endif
    tableCounts = (0, 0, 0, 0)
    tableCount = 0
  }

  /// Element count for table `ti`.
  @inline(__always)
  func count(ofTable ti: Int) -> Int {
    switch ti {
    case 0: return tableCounts.0
    case 1: return tableCounts.1
    case 2: return tableCounts.2
    default: return tableCounts.3
    }
  }

  @inline(__always)
  private mutating func setCount(_ n: Int, ofTable ti: Int) {
    switch ti {
    case 0: tableCounts.0 = n
    case 1: tableCounts.1 = n
    case 2: tableCounts.2 = n
    default: tableCounts.3 = n
    }
  }

  /// Flat index into storage for table `ti`, element `ei`.
  @inline(__always)
  private func flatIndex(_ ti: Int, _ ei: Int) -> Int {
    ti * WasmLimits.maxTableElements + ei
  }

  @inline(__always)
  subscript(ti: Int, ei: Int) -> Value {
    // mutating get avoids the 1,024-byte stack copy that withUnsafeBytes(of: storage) would
    // create (withUnsafeBytes takes its argument by value).  withUnsafeMutableBytes(of: &storage)
    // takes storage by reference — no copy, just a pointer into self's memory.
    mutating get {
      let idx = flatIndex(ti, ei)
      return withUnsafeMutableBytes(of: &storage) { buf in
        buf.baseAddress!.assumingMemoryBound(to: Value.self)[idx]
      }
    }
    set {
      let idx = flatIndex(ti, ei)
      withUnsafeMutableBytes(of: &storage) { buf in
        buf.baseAddress!.assumingMemoryBound(to: Value.self)[idx] = newValue
      }
    }
  }

  /// Initialise a table with `size` null-reference slots.
  @inline(__always)
  mutating func initTable(_ ti: Int, size: Int, nullValue: Value) throws(WasmError) {
    guard size <= WasmLimits.maxTableElements else { throw WasmError.resourceLimitExceeded }
    for i in 0..<size { self[ti, i] = nullValue }
    setCount(size, ofTable: ti)
    if ti >= tableCount { tableCount = ti + 1 }
  }

  /// Grow table `ti` by `delta` slots filled with `fillValue`.
  /// Returns the previous size, or -1 if growth exceeds the limit.
  @inline(__always)
  mutating func grow(_ ti: Int, by delta: Int, fillValue: Value, max: Int?) -> Int32 {
    let old = count(ofTable: ti)
    let newSize = old + delta
    if let m = max, newSize > m { return -1 }
    if newSize > WasmLimits.maxTableElements { return -1 }
    for i in old..<newSize { self[ti, i] = fillValue }
    setCount(newSize, ofTable: ti)
    return Int32(old)
  }
}

// MARK: - Interpreter

// Does not conform to Sendable because HostFunction (a closure) is not Sendable in non-Embedded builds.
struct WasmInterpreter {
  #if hasFeature(Embedded)
    // Embedded: reference to _embeddedModule global — avoids a ~2–5 KB copy in every call frame.
    // Safe: _embeddedModule lives for the entire program lifetime and is only written by
    // executeReceivedWasm() before this interpreter is constructed.
    // nonisolated(unsafe): Embedded has no concurrency; single-threaded bare-metal use only.
    nonisolated(unsafe) let moduleRef: UnsafePointer<WasmModule>

    /// Computed accessor so all existing `self.module` references compile without change.
    /// Uses `_embeddedModule` (BSS global) directly so the compiler emits a field-level load
    /// rather than copying the full WasmModule onto the caller's frame.
    @inline(__always) var module: WasmModule { _embeddedModule }
  #else
    let module: WasmModule
  #endif
  // Arena-backed linear memory pointer.  The lifetime of this buffer is owned by the
  // WasmArena passed to init; the WasmInterpreter must be destroyed before the arena
  // is reset.  UnsafeMutableBufferPointer is used on both platforms so that the type
  // is uniform and dispatchEmbedded needs no #if for memory access.
  var memory: UnsafeMutableBufferPointer<UInt8>
  // Total bytes pre-allocated from the arena at init time (>= memory.count).
  // memory.grow extends memory.count up to this limit without a new allocation.
  var memoryCapacity: Int
  #if hasFeature(Embedded)
    // In Embedded builds, host functions are @convention(c) pointers in a fixed-size buffer —
    // no heap allocation. internal (no modifier) so WasmInterpreterEmbedded.swift (same module,
    // separate file) can access hostFunctions from callHostFunction.
    let hostFunctions: Fixed32_HostFunctionPtr
  #else
    let hostFunctions: [HostFunction]
  #endif
  // internal (no modifier) so that WasmInterpreterEmbedded.swift (same module, separate file)
  // can pass these as inout arguments to dispatchEmbedded.
  var globals: Fixed32_Value  // mutable global variable slots (global.get/set)
  // Tables store Value (.funcref or .externref) directly to support both funcref and externref tables.
  // The reftype of each slot is determined by the table's declared RefType.
  #if hasFeature(Embedded)
    // Embedded: fixed-size flat storage — no heap allocation.
    var tables: FlatTableStorage  // reference tables; access via tables[ti, ei]
  #else
    var tables: [[Value]]  // TODO: Embedded Phase 5 — replace with FlatTableStorage
  #endif
  // Bit i = 1 means segment i has been dropped. Supports up to 64 segments.
  var droppedDataSegments: UInt64 = 0
  // Bit i = 1 means segment i has been dropped. Supports up to 64 segments.
  var droppedElementSegments: UInt64 = 0

  // MARK: - Execution Statistics

  // Counts WASM bytecode instructions dispatched. Host function calls are counted
  // as the call/call_indirect opcode only; the host function body itself is not counted.
  var executedInstructions: UInt64 = 0
  var peakValueStackDepth: Int = 0
  var peakCallStackDepth: Int = 0

  mutating func resetStats() {
    executedInstructions = 0
    peakValueStackDepth = 0
    peakCallStackDepth = 0
  }

  // MARK: - Init

  #if hasFeature(Embedded)
    // ── Embedded init ──────────────────────────────────────────────────────────────────────────
    // WasmModule is ~2–5 KB on Embedded after FixedJumpTable / Fixed64_FunctionHandle reduction.
    // Even so, storing it as a local in executeReceivedWasm would push it onto the 4 KB main
    // stack together with WasmInterpreter itself (~1 KB), leaving <1 KB for the call chain.
    // The solution: keep WasmModule in _embeddedModule (BSS global) and pass an UnsafeMutablePointer.

    /// Convenience: instantiate module with no host imports (Embedded only).
    init(moduleRef: UnsafeMutablePointer<WasmModule>, arena: inout WasmArena) throws(WasmError) {
      try self.init(moduleRef: moduleRef, arena: &arena, hostImports: Fixed4_HostImport())
    }

    /// Instantiates the module from a pointer to a global WasmModule (Embedded only).
    ///
    /// Typical usage in executeReceivedWasm:
    ///   _embeddedModule = try parser.parse()
    ///   var interp = try WasmInterpreter(moduleRef: &_embeddedModule, arena: &wasmArena, hostImports: hostImports)
    ///
    /// The caller must ensure that the pointed-to WasmModule outlives this interpreter.
    /// _embeddedModule is a program-lifetime global, so this requirement is always satisfied.
    init<S: Sequence>(
      moduleRef: UnsafeMutablePointer<WasmModule>, arena: inout WasmArena, hostImports: S
    )
      throws(WasmError) where S.Element == HostImport
    {
      self.moduleRef = UnsafePointer(moduleRef)
      // Access _embeddedModule fields directly (not through moduleRef.pointee) so each access
      // copies only the individual field, not the full WasmModule, avoiding stack overflow.

      // Embedded path: host functions are @convention(c) pointers in a fixed-size buffer — no heap.
      var funcs = Fixed32_HostFunctionPtr()
      for impIdx2 in 0..<_embeddedModule.imports.count {
        let imp = _embeddedModule.imports[impIdx2]
        guard case .function(let fi) = imp else { continue }
        var found = false
        for hi in hostImports {
          var body: HostFunctionPtr?
          switch hi {
          case .function(let m, let n, let fn):
            let matches = m.withUTF8Buffer { mBuf in
              n.withUTF8Buffer { fi.module.elementsEqual(mBuf) && fi.name.elementsEqual($0) }
            }
            if matches { body = fn }
          case .memory: break
          }
          if let fn = body {
            funcs.append(fn)
            found = true
            break
          }
        }
        guard found else { throw .importNotFound }
      }
      self.hostFunctions = funcs

      // Initialise globals from _embeddedModule.globals.initValue.
      var globalsArr = Fixed32_Value([])
      for gi in 0..<_embeddedModule.globals.count {
        globalsArr.append(_embeddedModule.globals[gi].initValue)
      }
      self.globals = globalsArr

      // Build per-table storage — Embedded: FlatTableStorage, no heap allocation.
      var tbls = FlatTableStorage()
      for ti2 in 0..<_embeddedModule.tables.count {
        let tbl = _embeddedModule.tables[ti2]
        let nullVal: Value = tbl.refType == .externRef ? .externref(nil) : .funcref(nil)
        try tbls.initTable(ti2, size: Int(tbl.min), nullValue: nullVal)
      }
      for segi in 0..<_embeddedModule.elements.count {
        let seg = _embeddedModule.elements[segi]
        guard !seg.isPassive else { continue }
        let ti = Int(seg.tableIndex)
        guard ti < tbls.tableCount else { throw .memoryAccessOutOfBounds }
        let start = Int(seg.offset)
        let refType = _embeddedModule.tables[ti].refType
        for (i, funcIdx) in seg.functionIndices.enumerated() {
          let pos = start + i
          guard pos < tbls.count(ofTable: ti) else { throw .memoryAccessOutOfBounds }
          tbls[ti, pos] = refType == .externRef ? .externref(funcIdx) : .funcref(funcIdx)
        }
      }
      self.tables = tbls

      // Determine memory size: prefer imported memory, fall back to local memory definition.
      var memPageCount: UInt32 = 0
      for impIdx in 0..<_embeddedModule.imports.count {
        let imp = _embeddedModule.imports[impIdx]
        guard case .memory(let mi) = imp else { continue }
        var found = false
        for hi in hostImports {
          var matchedPages: UInt32?
          switch hi {
          case .memory(let m, let n, let pages):
            let matches = m.withUTF8Buffer { mBuf in
              n.withUTF8Buffer { mi.module.elementsEqual(mBuf) && mi.name.elementsEqual($0) }
            }
            if matches { matchedPages = pages }
          default: break
          }
          if let pages = matchedPages {
            memPageCount = max(memPageCount, pages)
            found = true
            break
          }
        }
        guard found else { throw .importNotFound }
      }
      if memPageCount == 0, let localMem = _embeddedModule.memories.first {
        memPageCount = localMem.min
      }

      let initialByteCount = Int(memPageCount) * 65536
      let arenaAvailablePages = arena.availableBytes / 65536
      let maxPages: Int
      if let declaredMax = _embeddedModule.memories.first?.max {
        maxPages = min(Int(declaredMax), arenaAvailablePages)
      } else {
        maxPages = arenaAvailablePages
      }
      let capacityByteCount = max(maxPages, Int(memPageCount)) * 65536
      guard let memSlice = arena.allocate(count: capacityByteCount, alignment: 4) else {
        throw WasmError.resourceLimitExceeded
      }
      memSlice.initialize(repeating: 0)
      for di in 0..<_embeddedModule.data.count {
        let seg = _embeddedModule.data[di]
        guard let offset = seg.offset else { continue }
        let start = Int(offset)
        let end = start + seg.bytes.count
        guard start >= 0 && end <= initialByteCount else { throw .memoryAccessOutOfBounds }
        for i in start..<end { memSlice[i] = seg.bytes[i - start] }
      }
      self.memory = UnsafeMutableBufferPointer(start: memSlice.baseAddress, count: initialByteCount)
      self.memoryCapacity = capacityByteCount
      guard _embeddedModule.data.count <= 64 else { throw .resourceLimitExceeded }
      self.droppedDataSegments = 0

      guard _embeddedModule.elements.count <= 64 else { throw .resourceLimitExceeded }
      var droppedElems: UInt64 = 0
      for ei in 0..<_embeddedModule.elements.count {
        let seg = _embeddedModule.elements[ei]
        if !seg.isPassive || seg.isDeclarative { droppedElems |= UInt64(1) << ei }
      }
      self.droppedElementSegments = droppedElems

      if let startIdx = _embeddedModule.start {
        _ = try call(functionIndex: Int(startIdx), args: [])
      }
    }

    // Sentinel init used only to pre-populate the BSS global _embeddedInterp.
    // moduleRef = 1 (non-null, non-zero) is never dereferenced: the `module` computed
    // property returns _embeddedModule directly, ignoring moduleRef entirely.
    // _embeddedInterp is always fully overwritten by executeReceivedWasm before first use.
    private init(_sentinel: ()) {
      self.moduleRef = UnsafePointer(bitPattern: 1)!
      self.memory = UnsafeMutableBufferPointer(start: nil, count: 0)
      self.memoryCapacity = 0
      self.hostFunctions = Fixed32_HostFunctionPtr()
      self.globals = Fixed32_Value()
      self.tables = FlatTableStorage()
    }

    /// Zero-like sentinel used to pre-allocate `_embeddedInterp` in BSS.
    static var empty: WasmInterpreter { WasmInterpreter(_sentinel: ()) }

  #else
    // ── macOS init ─────────────────────────────────────────────────────────────────────────────

    /// Convenience: instantiate module with no host imports.
    init(module: WasmModule, arena: inout WasmArena) throws(WasmError) {
      try self.init(module: module, arena: &arena, hostImports: Fixed4_HostImport())
    }

    /// Instantiates the module.
    ///
    /// - arena: Arena allocator from which linear memory is allocated.  The caller must
    ///   keep the arena alive (and not call reset()) for the lifetime of this interpreter.
    /// - hostImports: host-provided imports (functions and memories) required by the module.
    ///   Accepts any Sequence of HostImport — pass [HostImport] on macOS or Fixed4_HostImport
    ///   on Embedded to avoid heap allocation. Throws .importNotFound if an import is declared
    ///   but no matching entry is provided.
    init<S: Sequence>(module: WasmModule, arena: inout WasmArena, hostImports: S) throws(WasmError)
    where S.Element == HostImport {
      self.module = module

      // Match host functions to imports, preserving import order.
      // fi.module / fi.name are [UInt8]; StaticString cases use withUTF8Buffer for
      // zero-copy byte comparison without Unicode normalisation.
      var funcs: [HostFunction] = []
      // Index-based loop: Fixed32_Import does not conform to Sequence.
      for impIdx in 0..<module.imports.count {
        let imp = module.imports[impIdx]
        guard case .function(let fi) = imp else { continue }
        var found = false
        for hi in hostImports {
          var body: HostFunction?
          switch hi {
          case .function(let m, let n, let fn):
            let matches = m.withUTF8Buffer { mBuf in
              n.withUTF8Buffer { fi.module.elementsEqual(mBuf) && fi.name.elementsEqual($0) }
            }
            if matches { body = fn }
          case .functionDyn(let mBytes, let nBytes, let fn):
            if fi.module.elementsEqual(mBytes) && fi.name.elementsEqual(nBytes) { body = fn }
          default: break
          }
          if let fn = body {
            funcs.append(fn)
            found = true
            break
          }
        }
        guard found else { throw .importNotFound }
      }
      self.hostFunctions = funcs

      // Initialise globals from module.globals.initValue.
      // Index-based loop works on both Fixed32_GlobalDef (Embedded) and [GlobalDef] (macOS)
      // now that Fixed32_GlobalDef exposes count + subscript on both platforms.
      var globalsArr = Fixed32_Value([])
      for gi in 0..<module.globals.count { globalsArr.append(module.globals[gi].initValue) }
      self.globals = globalsArr

      // Build per-table storage from the Table section; one entry per declared table.
      // Each table slot holds a Value (.funcref or .externref) matching the table's declared refType.
      // Only active segments are applied at instantiation; passive segments are skipped
      // and remain available for use by table.init / elem.drop at runtime.
      var tbls: [[Value]] = []
      for ti2 in 0..<module.tables.count {
        let tbl = module.tables[ti2]
        let nullVal: Value = tbl.refType == .externRef ? .externref(nil) : .funcref(nil)
        tbls.append([Value](repeating: nullVal, count: Int(tbl.min)))
      }
      // Apply active element segments; index-based loop works on both Fixed16_ElementSegment and [ElementSegment].
      for segi in 0..<module.elements.count {
        let seg = module.elements[segi]
        guard !seg.isPassive else { continue }  // passive segments are not applied at instantiation
        let ti = Int(seg.tableIndex)
        guard ti < tbls.count else { throw .memoryAccessOutOfBounds }
        let start = Int(seg.offset)
        // Use the table's declared refType to produce the correct Value variant.
        let refType = module.tables[ti].refType
        for (i, funcIdx) in seg.functionIndices.enumerated() {
          let pos = start + i
          guard pos < tbls[ti].count else { throw .memoryAccessOutOfBounds }
          tbls[ti][pos] = refType == .externRef ? .externref(funcIdx) : .funcref(funcIdx)
        }
      }
      self.tables = tbls

      // Determine memory size: prefer imported memory, fall back to local memory definition.
      // Use an index loop for Embedded compatibility (Fixed32_Import is the Embedded-path type; see WasmModule.swift).
      var memPageCount: UInt32 = 0
      for impIdx in 0..<module.imports.count {
        let imp = module.imports[impIdx]
        guard case .memory(let mi) = imp else { continue }
        var found = false
        for hi in hostImports {
          var matchedPages: UInt32?
          switch hi {
          case .memory(let m, let n, let pages):
            let matches = m.withUTF8Buffer { mBuf in
              n.withUTF8Buffer { mi.module.elementsEqual(mBuf) && mi.name.elementsEqual($0) }
            }
            if matches { matchedPages = pages }
          case .memoryDyn(let mBytes, let nBytes, let pages):
            if mi.module.elementsEqual(mBytes) && mi.name.elementsEqual(nBytes) {
              matchedPages = pages
            }
          default: break
          }
          if let pages = matchedPages {
            memPageCount = max(memPageCount, pages)
            found = true
            break
          }
        }
        guard found else { throw .importNotFound }
      }
      if memPageCount == 0, let localMem = module.memories.first {
        memPageCount = localMem.min
      }

      // Allocate linear memory from the arena (1 page = 64 KiB).
      // Using the arena eliminates the repeated malloc/free cycle that [UInt8] allocation
      // would incur on every executeReceivedWasm() call.
      //
      // memory.grow support: pre-allocate the declared maximum capacity so that
      // memory.grow can extend memory.count within the same backing block.
      // The active view (memory) starts at initialPages; memoryCapacity tracks the full
      // pre-allocated size so that memory.grow knows the hard upper bound.
      // Passive segments (offset == nil) are retained in module.data for use by memory.init
      // at runtime; they are not applied at instantiation.
      let initialByteCount = Int(memPageCount) * 65536
      // Pre-allocate up to the declared max pages so that memory.grow can extend
      // memory.count within the same backing block (no second malloc).
      // When no max is declared the Wasm spec allows up to 65536 pages (4 GiB), which
      // we obviously cannot reserve; instead we use however many full pages fit in the
      // remaining arena space, rounded down to a page boundary.
      // This keeps memory.grow working for realistic workloads on both macOS (256 KiB
      // arena, up to 4 pages) and Embedded (96 KiB arena).
      let arenaAvailablePages = arena.availableBytes / 65536
      let maxPages: Int
      if let declaredMax = module.memories.first?.max {
        maxPages = min(Int(declaredMax), arenaAvailablePages)
      } else {
        // No declared max: use full available arena space.
        maxPages = arenaAvailablePages
      }
      // Ensure the capacity is at least the initial page count (edge case: arena is almost full).
      let capacityByteCount = max(maxPages, Int(memPageCount)) * 65536
      guard let memSlice = arena.allocate(count: capacityByteCount, alignment: 4) else {
        throw WasmError.resourceLimitExceeded
      }
      // Zero-initialise: arena does not guarantee zeroed memory after reset().
      // This matches the Wasm spec (§4.5.4): linear memory is zero-initialised at
      // instantiation.  memset-equivalent; fast for typical 64 KiB sizes.
      memSlice.initialize(repeating: 0)
      for di in 0..<module.data.count {
        let seg = module.data[di]
        guard let offset = seg.offset else { continue }  // skip passive segments
        let start = Int(offset)
        let end = start + seg.bytes.count
        guard start >= 0 && end <= initialByteCount else { throw .memoryAccessOutOfBounds }
        for i in start..<end { memSlice[i] = seg.bytes[i - start] }
      }
      // memory initially covers only the initial pages; the remaining pre-allocated bytes
      // serve as grow headroom (see memory.grow opcode 0x40 in WasmInterpreterEmbedded.swift).
      self.memory = UnsafeMutableBufferPointer(
        start: memSlice.baseAddress, count: initialByteCount)
      self.memoryCapacity = capacityByteCount
      // UInt64 bitmap supports at most 64 data segments.
      guard module.data.count <= 64 else { throw .resourceLimitExceeded }
      self.droppedDataSegments = 0  // all bits clear = no segments dropped

      // Active element segments are treated as dropped after instantiation per Wasm spec §4.5.4.
      // Declarative segments (flags=3, 7) are also pre-dropped — they exist only to make
      // ref.func instructions valid, and must never be accessible via table.init.
      // flags=5 is passive (not declarative) and remains available for table.init.
      // Only true passive segments (isPassive==true, isDeclarative==false) remain available
      // for table.init at runtime.
      // UInt64 bitmap supports at most 64 element segments.
      // Use an index loop for Embedded compatibility (Fixed16_ElementSegment is the Embedded-path type; see WasmModule.swift).
      guard module.elements.count <= 64 else { throw .resourceLimitExceeded }
      var droppedElems: UInt64 = 0
      for ei in 0..<module.elements.count {
        let seg = module.elements[ei]
        if !seg.isPassive || seg.isDeclarative { droppedElems |= UInt64(1) << ei }
      }
      self.droppedElementSegments = droppedElems

      // Wasm spec: the start function is called automatically at instantiation
      if let startIdx = module.start {
        _ = try call(functionIndex: Int(startIdx), args: [])
      }
    }
  #endif

  // MARK: - Public

  /// Calls an exported function by name (UTF-8 bytes)
  mutating func callExport(nameBytes: [UInt8], args: [Value]) throws(WasmError) -> [Value] {
    // Index-based loop works on both Fixed32_Export (Embedded) and [Export] (macOS)
    // now that Fixed32_Export exposes count + subscript on both platforms.
    for i in 0..<module.exports.count {
      let exp = module.exports[i]
      if exp.nameBytes.elementsEqual(nameBytes) && exp.kind == .function {
        return try call(functionIndex: Int(exp.index), args: args)
      }
    }
    throw WasmError.functionNotFound
  }

  /// Calls an exported function by StaticString name — zero-copy, no heap allocation.
  mutating func callExport(_ name: StaticString, args: [Value]) throws(WasmError) -> [Value] {
    for i in 0..<module.exports.count {
      let exp = module.exports[i]
      let matches = name.withUTF8Buffer { exp.nameBytes.elementsEqual($0) && exp.kind == .function }
      if matches { return try call(functionIndex: Int(exp.index), args: args) }
    }
    throw WasmError.functionNotFound
  }

  /// Calls a function by its unified function index (including imports)
  mutating func call(functionIndex: Int, args: [Value]) throws(WasmError) -> [Value] {
    let importedCount = module.importedFunctionCount

    if functionIndex < importedCount {
      // Host function: dispatch via the appropriate calling convention
      #if hasFeature(Embedded)
        return callHostFunction(index: functionIndex, args: args)
      #else
        // HostFunction takes [UInt8] (macOS public API); convert from UnsafeMutableBufferPointer.
        // Array(UnsafeBufferPointer(memory)) copies the bytes into a new [UInt8] — acceptable
        // since host function calls are rare and keeping HostFunction's signature stable avoids
        // cascading changes through all test call sites.
        // TODO: Arena Step 3b — change HostFunction to take UnsafeBufferPointer<UInt8> directly,
        //        eliminating this copy.
        return hostFunctions[functionIndex](args, Array(UnsafeBufferPointer(memory)))
      #endif
    }

    // Local function: validate and run iteratively
    let localIdx = functionIndex - importedCount
    let typeIndex = Int(module.functions[localIdx])
    let funcType = module.types[typeIndex]
    guard args.count == funcType.params.count else {
      throw .argumentCountMismatch
    }

    return try runIterativeEmbedded(functionIndex: functionIndex, args: args)
  }

  // MARK: - Embedded Host Function Dispatch

  #if hasFeature(Embedded)
    /// Calls a host function by index using the @convention(c) HostFunctionPtr interface.
    ///
    /// This helper is used by `call(functionIndex:args:)` in Embedded builds to avoid
    /// heap-captured closures. Arguments are passed via UnsafeBufferPointer and results
    /// are read from a fixed 8-slot stack buffer.
    ///
    /// Limitation: host functions returning more than 8 values are not supported in Embedded.
    private mutating func callHostFunction(index: Int, args: [Value]) -> [Value] {
      let resultCount = module.functionType(at: index).results.count
      // Fixed 8-slot result buffer; host functions returning >8 values are unsupported in
      // Embedded builds. Guard against out-of-bounds writes at runtime.
      precondition(
        resultCount <= 8,
        "HostFunctionPtr: resultCount \(resultCount) exceeds 8-slot result buffer — not supported in Embedded"
      )
      // withUnsafeTemporaryAllocation guarantees correct alignment and stride for Value
      // elements — unlike a homogeneous tuple, whose layout Swift does not formally guarantee.
      var results: [Value] = []
      withUnsafeTemporaryAllocation(of: Value.self, capacity: 8) { resultsBuf in
        args.withUnsafeBytes { argsRaw in
          let argsPtr: UnsafeRawPointer? = argsRaw.baseAddress
          let resultsRaw: UnsafeMutableRawPointer? =
            resultCount > 0 ? UnsafeMutableRawPointer(resultsBuf.baseAddress!) : nil
          // memory is UnsafeMutableBufferPointer<UInt8> — baseAddress gives direct mutable
          // pointer access; withUnsafeMutableBytes does not exist on this type.
          let memPtr = memory.baseAddress
          let memLen = Int32(memory.count)
          // Pass args as UnsafeRawPointer — callee reinterprets to UnsafePointer<Value>.
          hostFunctions[index](argsPtr, Int32(args.count), memPtr, memLen, resultsRaw)
        }
        for i in 0..<resultCount {
          results.append(resultsBuf[i])
        }
      }
      return results
    }
  #endif
}
