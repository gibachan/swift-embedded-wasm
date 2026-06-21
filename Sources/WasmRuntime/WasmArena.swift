// WasmArena: bump-pointer arena allocator for the WASM runtime.
//
// Eliminates repeated malloc/free cycles for the dominant allocation
// (WasmInterpreter.memory = 64 KB linear memory) by reserving one large buffer
// up-front and bump-allocating from it.  After execution, a single reset() call
// reclaims all allocations in O(1) without individual free() calls.
//
// Platform strategy:
//   Embedded — the backing buffer is a C static array (wasm_arena.c), placed in
//              SRAM by the linker at start-up; zero heap usage.
//   macOS    — the backing buffer is a single heap allocation made once during
//              WasmArena.init via _ArenaStorage; subsequent allocate() calls never
//              call malloc again.
//
// Lifetime contract:
//   Any object that holds a pointer into the arena (e.g. WasmInterpreter.memory)
//   must be destroyed before the next reset() call.  executeReceivedWasm() ensures
//   this via lexical scoping: interp is dropped at the end of its do-block, which
//   precedes the reset() at the start of the next cycle.

// MARK: - macOS backing storage

// A reference-type wrapper so that WasmArena (a struct) can share ownership of
// the heap block without copying it.  On Embedded builds, this class is omitted
// entirely — the static C buffer replaces it.
#if !hasFeature(Embedded)
  /// Single-allocation backing for WasmArena on macOS.
  /// Holds a heap-allocated buffer for the lifetime of the Arena instance.
  private final class _ArenaStorage {
    let ptr: UnsafeMutablePointer<UInt8>
    let capacity: Int
    init(capacity: Int) {
      ptr = .allocate(capacity: capacity)
      // Zero-initialise so the first allocation after reset() sees clean memory,
      // matching the behaviour of the Embedded path (which also zero-initialises
      // the static buffer at program start).
      ptr.initialize(repeating: 0, count: capacity)
      self.capacity = capacity
    }
    deinit { ptr.deallocate() }
  }
#endif

// MARK: - WasmArena

/// Bump-pointer arena allocator backed by a single contiguous buffer.
///
/// Typical usage:
/// ```swift
/// // Embedded: one global arena, reset before each wasm execution cycle.
/// var wasmArena = WasmArena()
///
/// func executeReceivedWasm(...) {
///     wasmArena.reset()                          // O(1) — reclaim everything
///     let module = try parser.parse()
///     var interp = try WasmInterpreter(module: module, arena: &wasmArena, ...)
///     try interp.callExport(...)
///     // interp destroyed here — safe to reset arena on next call
/// }
///
/// // macOS tests: pass any size.
/// var arena = WasmArena(capacity: 128 * 1024)
/// var interp = try WasmInterpreter(module: module, arena: &arena, ...)
/// ```
///
/// Thread safety: WasmArena is a value type (struct) with mutating methods.
/// It is not thread-safe; the caller must ensure exclusive access.
struct WasmArena {
  // MARK: Backing storage (platform-specific)

  // The #if here is justified: on Embedded the backing pointer comes from a C
  // function (wasm_arena_ptr) whose type is an @convention(c) function pointer —
  // a type that does not exist on macOS.  On macOS we use a class for reference
  // semantics so the heap block is not copied on struct assignment.
  #if hasFeature(Embedded)
    // @_extern(c) imports the C symbols without requiring a bridging header.
    // This is the correct Embedded Swift pattern for calling C functions from
    // Sources/; the BridgingHeader.h in the Examples/ directory is only visible
    // to the Embedded example target, not to `make compile` (which compiles
    // Sources/ alone).
    @_extern(c, "wasm_arena_ptr")
    private static func wasm_arena_ptr_c() -> UnsafeMutablePointer<UInt8>?
    @_extern(c, "wasm_arena_size")
    private static func wasm_arena_size_c() -> UInt32

    // Pointer and capacity are set once in init() and never change.
    // On Embedded, wasm_arena_ptr() returns the address of the static C array.
    private let _base: UnsafeMutablePointer<UInt8>
    private let _capacity: Int

    init() {
      guard let p = WasmArena.wasm_arena_ptr_c() else {
        // wasm_arena_ptr() always returns non-nil for the static C array.
        // This branch is unreachable at runtime but required by the type system.
        preconditionFailure("wasm_arena_ptr returned nil")
      }
      _base = p
      _capacity = Int(WasmArena.wasm_arena_size_c())
    }
  #else
    private let _storage: _ArenaStorage
    // Computed properties forward to _storage so that allocate() / reset() code
    // is identical on both platforms.
    private var _base: UnsafeMutablePointer<UInt8> { _storage.ptr }
    private var _capacity: Int { _storage.capacity }

    /// Create an arena backed by a single heap allocation.
    ///
    /// - Parameter capacity: Total byte capacity of the arena.  Defaults to 96 KiB
    ///   to match the Embedded static buffer size.  Tests may pass a smaller value
    ///   to keep memory usage low.
    init(capacity: Int = 96 * 1024) {
      _storage = _ArenaStorage(capacity: capacity)
    }
  #endif

  // MARK: Common state

  /// Number of bytes consumed by outstanding allocations.
  private var _used: Int = 0

  /// Bytes consumed since the last reset().
  var usedBytes: Int { _used }

  /// Bytes available for future allocations.
  var availableBytes: Int { _capacity - _used }

  // MARK: Allocation

  /// Bump-allocate `count` bytes with the given power-of-two alignment.
  ///
  /// Returns a non-nil buffer on success, or nil when capacity would be exceeded.
  /// The returned memory is NOT zero-initialised — the caller must call
  /// `initialize(repeating:)` or equivalent before use (matching the contract of
  /// `UnsafeMutablePointer.allocate`, which does not guarantee zero bytes).
  ///
  /// - Parameters:
  ///   - count:     Number of bytes to allocate.  Must be >= 0.
  ///   - alignment: Byte alignment for the allocation start address.  Must be a
  ///                positive power of two (1, 2, 4, 8, ...).  Defaults to 1.
  mutating func allocate(
    count: Int,
    alignment: Int = 1
  ) -> UnsafeMutableBufferPointer<UInt8>? {
    precondition(count >= 0, "allocate(count:) must be non-negative")
    precondition(
      alignment > 0 && alignment & (alignment - 1) == 0,
      "alignment must be a positive power of two")
    // Round _used up to the next multiple of alignment.
    // Example: _used=1, alignment=4 → aligned=4.
    let aligned = (_used + alignment - 1) & ~(alignment - 1)
    guard aligned + count <= _capacity else { return nil }
    let ptr = _base.advanced(by: aligned)
    _used = aligned + count
    return UnsafeMutableBufferPointer(start: ptr, count: count)
  }

  // MARK: Reset

  /// Release all allocations in O(1) by resetting the bump pointer.
  ///
  /// The backing memory is NOT zeroed; each new allocation must be initialised
  /// by the caller (see allocate note above).
  ///
  /// All previously returned UnsafeMutableBufferPointer values become invalid
  /// after this call.  Any object holding a pointer into the arena (e.g.
  /// WasmInterpreter) must be destroyed before reset() is called.
  mutating func reset() { _used = 0 }
}
