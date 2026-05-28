import SwiftUI

struct ContentView: View {
  @State private var ble = BLEManager()
  @State private var blinkCount: Double = 1

  var body: some View {
    VStack(spacing: 16) {
      // --- 状態表示 ---
      Text(ble.isBluetoothOn ? "Bluetooth ON" : "Bluetooth OFF")
      Text(ble.isConnected ? "Connected" : "Disconnected")
      Text(ble.isReady ? "Ready" : "Not Ready")

      Divider()

      // --- 点滅回数の選択 ---
      Text("Blink count: \(Int(blinkCount))")
        .font(.headline)

      Slider(value: $blinkCount, in: 1...10, step: 1)
        .padding(.horizontal)

      Button("Blink") {
        ble.sendBlinkCount(Int(blinkCount))
      }
      .buttonStyle(.borderedProminent)
      .disabled(!ble.isReady)

      Divider()

      // --- 通信ログ ---
      List(Array(ble.log.enumerated()), id: \.offset) { _, item in
        Text(item)
          .font(.system(size: 12))
      }
    }
    .padding()
  }
}
