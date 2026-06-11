@_extern(wasm, module: "env", name: "blink")
func blink()

@_expose(wasm, "run")
public func run() {
    blink()
    blink()
    blink()
}
