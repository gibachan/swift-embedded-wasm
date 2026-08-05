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
/// Embedded builds: storage is an 8-element homogeneous tuple on the C stack — no malloc.
/// macOS builds:    storage is a [Label] array (heap-allocated), capacity 32.
///
/// This is intentionally NOT unified onto the Embedded 8-slot tuple (unlike the sibling
/// Fixed*_X buffers in WasmModule.swift — see Documentations/hasFeature削除計画.md §5.4).
/// The original justification written here — "keep EmbeddedFrame small so that CallStack
/// (64 tuple-frames) fits on the call stack" — does not hold for *macOS*, since macOS's
/// `EmbeddedCallStack` type alias resolves to `[EmbeddedFrame]` (a heap array defined in
/// WasmInterpreterEmbedded.swift), not to the tuple-based `CallStack` below; `CallStack` is
/// never instantiated on macOS. However, unifying storage onto a single capacity was tried
/// and reverted after two real regressions were found:
///   1. Growing WasmModule's Fixed*_X containers to unconditional tuple storage (§5.1–5.3 of
///      the plan) was, on its own, sufficient to overflow Swift Testing's 512 KB
///      worker-thread stack inside the already near-the-limit `_runIterativeEmbeddedCore` /
///      `dispatchEmbedded` machinery on macOS — reproduced as a SIGBUS crash. This falsified
///      the plan's assumption that `moduleRef`/pointer-passing makes container size growth
///      harmless; the margin was razor-thin to begin with.
///   2. Raising LabelStack's capacity to 32 (to match macOS's prior test coverage) risks the
///      same class of failure on the *real* Embedded target: `EmbeddedFrame` (which embeds
///      LabelStack) is stored in `CallStack`, a 64-frame tuple kept as a BSS global
///      (`_wasmCallStack` in WasmInterpreterEmbedded.swift) specifically to avoid the RP2040
///      stack overflow fixed by reducing LabelStack from 32 to 8 slots (see git history:
///      "Phase 5: fix RP2040 stack overflow — ... LabelStack 32→8 ..."). Reverting that
///      capacity reduction was not attempted here without on-device verification.
/// Keeping macOS on a 32-slot heap array preserves its wider test coverage (e.g. the
/// `switch` spectest, which nests more than 8 blocks) while leaving Embedded's already
/// hardware-verified 8-slot budget untouched. The single #if hasFeature(Embedded) inside
/// this struct remains Approach A from the design notes: one conditional at the boundary
/// between stack and heap storage, with a uniform API exposed to all callers.
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

  // Indexed access.  @inline(never) on both get and set keeps the 32-case switch
  // (inside withMutableRow) out of dispatchEmbedded's stack frame.
  // mutating get: self is passed by reference (inout ABI), no 4 KB ValueStack copy.
  subscript(index: Int) -> Value {
    @inline(never) mutating get { withMutableRow(index / 8) { $0[index % 8] } }
    @inline(never) set { withMutableRow(index / 8) { $0[index % 8] = newValue } }
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

  // @inline(__always) is safe: dispatchEmbedded accesses frames only via the
  // @inline(never) named field accessors below, never via this subscript directly.
  // The subscript is called only by append() (setter path) — not in the per-opcode loop.
  @inline(__always)
  subscript(index: Int) -> EmbeddedFrame {
    mutating get { withMutableRow(index / 8) { $0[index % 8] } }
    set { withMutableRow(index / 8) { $0[index % 8] = newValue } }
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
  // All access paths into CallStack storage (subscript and named field accessors below)
  // use withMutableRow → withUnsafeMutableBytes(of: &sN), which passes a pointer to BSS
  // storage without copying the 1248-byte sN tuple.
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
  mutating func initTable(_ ti: Int, size: Int, nullValue: Value) throws(InterpreterError) {
    guard size <= WasmLimits.maxTableElements else { throw InterpreterError.resourceLimitExceeded }
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

  // MARK: - Instantiation Helpers (shared between Embedded and macOS init)
  //
  // The Embedded and macOS `init` bodies below build largely identical data from the
  // module's Fixed*_X sections (Global/Table/Element/Data/Memory). Since Phase 1
  // (Documentations/hasFeature削除計画.md §5), these Fixed*_X types expose the same
  // count/subscript API on both platforms even where their internal storage still
  // differs, so the index-loops that only *read* module sections can be shared verbatim
  // as the private helpers below (Phase 2 of the same plan, §6.1).
  //
  // What remains platform-specific — and stays inside the two `#if hasFeature(Embedded)`
  // init bodies rather than being folded into these helpers — is: how `module` itself is
  // obtained (moduleRef global vs a value parameter), how `hostFunctions` is built
  // (`@convention(c)` pointers vs closures — deferred unification, see plan §6.3(b)), and
  // how `tables` is built (`FlatTableStorage` vs `[[Value]]` storage — deferred to Phase 3
  // pending the dispatchEmbedded stack-frame work, see plan §6.2).

  /// Builds the initial global-variable slots from the module's Global section.
  private static func buildGlobals(_ globals: Fixed32_GlobalDef) -> Fixed32_Value {
    var globalsArr = Fixed32_Value()
    for gi in 0..<globals.count { globalsArr.append(globals[gi].initValue) }
    return globalsArr
  }

  /// Maps an element segment's function index to the Value variant matching the
  /// destination table's declared reftype.
  @inline(__always)
  private static func tableRefValue(_ funcIdx: UInt32?, refType: RefType) -> Value {
    refType == .externRef ? .externref(funcIdx) : .funcref(funcIdx)
  }

  /// Page count declared by the module's own Memory section, used as a fallback when no
  /// host import supplies a memory. Returns 0 (no memory) if the module declares none.
  private static func declaredMemoryPages(_ memories: Fixed1_MemoryType) -> UInt32 {
    memories.first?.min ?? 0
  }

  /// Computes the byte size of the active memory view and the total capacity to
  /// pre-allocate from the arena, honouring the module's declared max page count (if any)
  /// and however much space the arena has left. Pre-allocating the full capacity up front
  /// lets memory.grow extend `memory.count` in place without a second allocation.
  private static func memoryByteCounts(
    memPageCount: UInt32, declaredMaxPages: UInt32?, arenaAvailableBytes: Int
  ) -> (initial: Int, capacity: Int) {
    let initialByteCount = Int(memPageCount) * 65536
    let arenaAvailablePages = arenaAvailableBytes / 65536
    let maxPages: Int
    if let declaredMax = declaredMaxPages {
      maxPages = min(Int(declaredMax), arenaAvailablePages)
    } else {
      maxPages = arenaAvailablePages
    }
    let capacityByteCount = max(maxPages, Int(memPageCount)) * 65536
    return (initialByteCount, capacityByteCount)
  }

  /// Copies active data segments (offset != nil) into freshly-allocated linear memory.
  /// Passive segments are left untouched in `data` for use by memory.init at runtime.
  private static func applyDataSegments(
    _ data: Fixed16_DataSegment, into memSlice: UnsafeMutableBufferPointer<UInt8>,
    initialByteCount: Int
  ) throws(InterpreterError) {
    for di in 0..<data.count {
      let seg = data[di]
      guard let offset = seg.offset else { continue }
      let start = Int(offset)
      let end = start + seg.bytes.count
      guard start >= 0 && end <= initialByteCount else { throw .memoryAccessOutOfBounds }
      for i in start..<end { memSlice[i] = seg.bytes[i - start] }
    }
  }

  /// Computes the dropped-element-segment bitmap per Wasm spec §4.5.4: active segments are
  /// dropped immediately after instantiation, and declarative segments (flags 3, 7) are
  /// pre-dropped so that ref.func stays valid while table.init can never reach them. Only
  /// true passive segments (flags 1, 5) remain available for table.init at runtime.
  private static func initialDroppedElementSegments(
    _ elements: Fixed16_ElementSegment
  ) throws(InterpreterError) -> UInt64 {
    guard elements.count <= 64 else { throw .resourceLimitExceeded }
    var droppedElems: UInt64 = 0
    for ei in 0..<elements.count {
      let seg = elements[ei]
      if !seg.isPassive || seg.isDeclarative { droppedElems |= UInt64(1) << ei }
    }
    return droppedElems
  }

  /// Computes the initial dropped-data-segment bitmap. All bits start clear (no segments
  /// dropped) — data.drop only ever sets bits at runtime — but instantiation still enforces
  /// the same 64-segment ceiling the bitmap's width allows, matching the element-segment
  /// counterpart above.
  private static func droppedDataSegmentsInitial(count: Int) throws(InterpreterError) -> UInt64 {
    guard count <= 64 else { throw .resourceLimitExceeded }
    return 0
  }

  // MARK: - Init

  #if hasFeature(Embedded)
    // ── Embedded init ──────────────────────────────────────────────────────────────────────────
    // WasmModule is ~2–5 KB on Embedded after FixedJumpTable / Fixed64_FunctionHandle reduction.
    // Even so, storing it as a local in executeReceivedWasm would push it onto the 4 KB main
    // stack together with WasmInterpreter itself (~1 KB), leaving <1 KB for the call chain.
    // The solution: keep WasmModule in _embeddedModule (BSS global) and pass an UnsafeMutablePointer.

    /// Convenience: instantiate module with no host imports (Embedded only).
    init(moduleRef: UnsafeMutablePointer<WasmModule>, arena: inout WasmArena)
      throws(InterpreterError)
    {
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
      throws(InterpreterError) where S.Element == HostImport
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
      self.globals = Self.buildGlobals(_embeddedModule.globals)

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
          tbls[ti, pos] = Self.tableRefValue(funcIdx, refType: refType)
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
      if memPageCount == 0 { memPageCount = Self.declaredMemoryPages(_embeddedModule.memories) }

      let byteCounts = Self.memoryByteCounts(
        memPageCount: memPageCount, declaredMaxPages: _embeddedModule.memories.first?.max,
        arenaAvailableBytes: arena.availableBytes)
      let initialByteCount = byteCounts.initial
      let capacityByteCount = byteCounts.capacity
      guard let memSlice = arena.allocate(count: capacityByteCount, alignment: 4) else {
        throw InterpreterError.resourceLimitExceeded
      }
      memSlice.initialize(repeating: 0)
      try Self.applyDataSegments(
        _embeddedModule.data, into: memSlice, initialByteCount: initialByteCount)
      self.memory = UnsafeMutableBufferPointer(start: memSlice.baseAddress, count: initialByteCount)
      self.memoryCapacity = capacityByteCount
      self.droppedDataSegments = try Self.droppedDataSegmentsInitial(
        count: _embeddedModule.data.count)

      self.droppedElementSegments = try Self.initialDroppedElementSegments(_embeddedModule.elements)

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
    init(module: WasmModule, arena: inout WasmArena) throws(InterpreterError) {
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
    init<S: Sequence>(module: WasmModule, arena: inout WasmArena, hostImports: S)
      throws(InterpreterError)
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
      self.globals = Self.buildGlobals(module.globals)

      // Build per-table storage from the Table section; one entry per declared table.
      // Each table slot holds a Value (.funcref or .externref) matching the table's declared refType.
      // Only active segments are applied at instantiation; passive segments are skipped
      // and remain available for use by table.init / elem.drop at runtime.
      // TODO: Embedded Phase 5 — replace [[Value]] with FlatTableStorage (see plan §6.2);
      // until then this loop can't be folded into the Embedded branch's FlatTableStorage build.
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
          tbls[ti][pos] = Self.tableRefValue(funcIdx, refType: refType)
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
      if memPageCount == 0 { memPageCount = Self.declaredMemoryPages(module.memories) }

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
      let byteCounts = Self.memoryByteCounts(
        memPageCount: memPageCount, declaredMaxPages: module.memories.first?.max,
        arenaAvailableBytes: arena.availableBytes)
      let initialByteCount = byteCounts.initial
      let capacityByteCount = byteCounts.capacity
      guard let memSlice = arena.allocate(count: capacityByteCount, alignment: 4) else {
        throw InterpreterError.resourceLimitExceeded
      }
      // Zero-initialise: arena does not guarantee zeroed memory after reset().
      // This matches the Wasm spec (§4.5.4): linear memory is zero-initialised at
      // instantiation.  memset-equivalent; fast for typical 64 KiB sizes.
      memSlice.initialize(repeating: 0)
      try Self.applyDataSegments(module.data, into: memSlice, initialByteCount: initialByteCount)
      // memory initially covers only the initial pages; the remaining pre-allocated bytes
      // serve as grow headroom (see memory.grow opcode 0x40 in WasmInterpreterEmbedded.swift).
      self.memory = UnsafeMutableBufferPointer(
        start: memSlice.baseAddress, count: initialByteCount)
      self.memoryCapacity = capacityByteCount
      // UInt64 bitmap supports at most 64 data segments (enforced inside the helper).
      self.droppedDataSegments = try Self.droppedDataSegmentsInitial(count: module.data.count)

      // Active element segments are treated as dropped after instantiation per Wasm spec §4.5.4.
      // Declarative segments (flags=3, 7) are also pre-dropped — they exist only to make
      // ref.func instructions valid, and must never be accessible via table.init.
      // flags=5 is passive (not declarative) and remains available for table.init.
      // UInt64 bitmap supports at most 64 element segments.
      self.droppedElementSegments = try Self.initialDroppedElementSegments(module.elements)

      // Wasm spec: the start function is called automatically at instantiation
      if let startIdx = module.start {
        _ = try call(functionIndex: Int(startIdx), args: [])
      }
    }
  #endif

  // MARK: - Public

  /// Calls an exported function by name (UTF-8 bytes)
  mutating func callExport(nameBytes: [UInt8], args: [Value]) throws(InterpreterError) -> [Value] {
    // Index-based loop works on both Fixed32_Export (Embedded) and [Export] (macOS)
    // now that Fixed32_Export exposes count + subscript on both platforms.
    for i in 0..<module.exports.count {
      let exp = module.exports[i]
      if exp.nameBytes.elementsEqual(nameBytes) && exp.kind == .function {
        return try call(functionIndex: Int(exp.index), args: args)
      }
    }
    throw InterpreterError.functionNotFound
  }

  /// Calls an exported function by StaticString name — zero-copy, no heap allocation.
  mutating func callExport(_ name: StaticString, args: [Value]) throws(InterpreterError) -> [Value]
  {
    for i in 0..<module.exports.count {
      let exp = module.exports[i]
      let matches = name.withUTF8Buffer { exp.nameBytes.elementsEqual($0) && exp.kind == .function }
      if matches { return try call(functionIndex: Int(exp.index), args: args) }
    }
    throw InterpreterError.functionNotFound
  }

  /// Calls a function by its unified function index (including imports)
  mutating func call(functionIndex: Int, args: [Value]) throws(InterpreterError) -> [Value] {
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
