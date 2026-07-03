import Foundation

struct WasmEntry: Identifiable {
  let displayName: String
  let description: String
  let resourceName: String

  var id: String { displayName }

  static let all: [WasmEntry] = [
    WasmEntry(
      displayName: "gpio-blink-swift.wasm",
      description: "Swift compiler output (gpio-blink-swift.swift). Imports env.digitalWrite + env.sleep. Blinks GPIO 13 ten times at 300 ms interval.",
      resourceName: "gpio-blink-swift"),
    WasmEntry(
      displayName: "i32-add.wasm",
      description: "Swift compiler output (i32-add.swift). No host imports. Exports add(i32, i32) -> i32. Pico calls add(3, 4) and prints the result via UART.",
      resourceName: "i32-add"),
  ]
}
