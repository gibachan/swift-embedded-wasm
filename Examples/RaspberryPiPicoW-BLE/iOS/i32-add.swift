// Pure arithmetic Wasm module — no host imports needed.
// Exports a single function "add" that returns a &+ b.
@_expose(wasm, "add")
public func add(_ a: Int32, _ b: Int32) -> Int32 {
    a &+ b
}
