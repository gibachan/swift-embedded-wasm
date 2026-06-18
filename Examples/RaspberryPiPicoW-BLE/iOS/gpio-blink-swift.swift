@_extern(wasm, module: "env", name: "digitalWrite")
func digitalWrite(_ pin: Int32, _ val: Int32)

@_extern(wasm, module: "env", name: "sleep")
func sleep(_ ms: Int32)

// Blink an external LED connected to GPIO 13, 10 times.
@_expose(wasm, "run")
public func run() {
    let pin: Int32 = 13
    var i: Int32 = 0
    while i < 10 {
        digitalWrite(pin, 1)
        sleep(300)
        digitalWrite(pin, 0)
        sleep(300)
        i = i &+ 1
    }
}
