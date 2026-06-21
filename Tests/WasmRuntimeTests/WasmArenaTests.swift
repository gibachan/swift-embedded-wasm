import Testing

@testable import WasmRuntime

// MARK: - WasmArena unit tests

@Suite("WasmArena")
struct WasmArenaTests {

  // MARK: Basic allocation

  @Test func allocateReturnsNonNilBuffer() {
    var arena = WasmArena(capacity: 1024)
    let buf = arena.allocate(count: 64)
    #expect(buf != nil)
    #expect(buf?.count == 64)
  }

  @Test func allocatedBytesAreContiguous() {
    var arena = WasmArena(capacity: 1024)
    guard let first = arena.allocate(count: 16),
      let second = arena.allocate(count: 16)
    else {
      Issue.record("allocate returned nil unexpectedly")
      return
    }
    // Second allocation must begin immediately after the first (no gap, no overlap).
    let gap = Int(bitPattern: second.baseAddress) - Int(bitPattern: first.baseAddress)
    #expect(gap == 16)
  }

  @Test func allocateReturnsNilWhenFull() {
    var arena = WasmArena(capacity: 128)
    // Consume the entire arena.
    let first = arena.allocate(count: 128)
    #expect(first != nil)
    // Next allocation must fail.
    let overflow = arena.allocate(count: 1)
    #expect(overflow == nil)
  }

  @Test func allocateReturnsNilOnPartialOverflow() {
    var arena = WasmArena(capacity: 100)
    let _ = arena.allocate(count: 90)
    // Only 10 bytes remain; requesting 11 must fail.
    let overflow = arena.allocate(count: 11)
    #expect(overflow == nil)
  }

  // MARK: Alignment

  @Test func alignment4PadsCorrectly() {
    var arena = WasmArena(capacity: 1024)
    // Consume 1 byte — _used is now 1, not a multiple of 4.
    let _ = arena.allocate(count: 1)
    // Requesting alignment=4 must pad _used up to 4 before allocating.
    guard let aligned = arena.allocate(count: 8, alignment: 4) else {
      Issue.record("allocate(count:alignment:) returned nil unexpectedly")
      return
    }
    let addr = Int(bitPattern: aligned.baseAddress)
    #expect(addr % 4 == 0)
  }

  @Test func alignment8PadsCorrectly() {
    var arena = WasmArena(capacity: 1024)
    let _ = arena.allocate(count: 3)
    guard let aligned = arena.allocate(count: 16, alignment: 8) else {
      Issue.record("allocate(count:alignment:) returned nil unexpectedly")
      return
    }
    let addr = Int(bitPattern: aligned.baseAddress)
    #expect(addr % 8 == 0)
  }

  @Test func alignment1ProducesNoPadding() {
    var arena = WasmArena(capacity: 1024)
    let _ = arena.allocate(count: 3)
    // alignment=1 (default) must not add padding.
    guard let buf = arena.allocate(count: 8) else {
      Issue.record("allocate returned nil unexpectedly")
      return
    }
    // usedBytes should be exactly 3 + 8 = 11.
    #expect(arena.usedBytes == 11)
    let _ = buf  // suppress unused warning
  }

  // MARK: usedBytes / availableBytes

  @Test func usedBytesTracksAllocations() {
    var arena = WasmArena(capacity: 512)
    #expect(arena.usedBytes == 0)
    #expect(arena.availableBytes == 512)
    let _ = arena.allocate(count: 100)
    #expect(arena.usedBytes == 100)
    #expect(arena.availableBytes == 412)
  }

  // MARK: Reset

  @Test func resetReclaims() {
    var arena = WasmArena(capacity: 256)
    let _ = arena.allocate(count: 200)
    #expect(arena.usedBytes == 200)
    arena.reset()
    #expect(arena.usedBytes == 0)
    #expect(arena.availableBytes == 256)
  }

  @Test func allocateAfterReset() {
    var arena = WasmArena(capacity: 256)
    let _ = arena.allocate(count: 256)
    arena.reset()
    // After reset the full capacity should be re-usable.
    let second = arena.allocate(count: 256)
    #expect(second != nil)
  }

  // MARK: Write-through and initialisation

  @Test func allocatedMemoryCanBeWritten() {
    var arena = WasmArena(capacity: 256)
    guard var buf = arena.allocate(count: 4) else {
      Issue.record("allocate returned nil")
      return
    }
    buf.initialize(repeating: 0)
    buf[0] = 0xDE
    buf[1] = 0xAD
    buf[2] = 0xBE
    buf[3] = 0xEF
    #expect(buf[0] == 0xDE)
    #expect(buf[3] == 0xEF)
  }

  // MARK: macOS copy-semantics: shared storage across copies

  @Test func copySharesStorage() {
    // WARNING: copying a WasmArena is UNSAFE in production — both copies allocate
    // from the same backing buffer with independent bump pointers, so allocations
    // from one copy overwrite regions handed out by the other.
    // The correct usage is always via inout; never copy an arena and allocate from both copies.
    //
    // This test only documents the observed (mis)behaviour so a future reader is not
    // surprised by the copy semantics of the macOS _ArenaStorage path.
    var a = WasmArena(capacity: 128)
    var b = a  // struct copy — _ArenaStorage (class) is shared, but _used is independent
    let _ = a.allocate(count: 50)
    #expect(a.usedBytes == 50)
    #expect(b.usedBytes == 0)  // b's _used is 0; its allocations would alias a's
    let _ = b.allocate(count: 30)
    #expect(b.usedBytes == 30)
  }
}
