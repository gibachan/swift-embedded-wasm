import SwiftUI

struct ContentView: View {
  @State private var ble = BLEManager()
  @State private var blinkCount: Double = 1

  var body: some View {
    NavigationStack {
      List {
        Section {
          LabeledContent {
            Text(ble.isBluetoothOn ? "ON" : "OFF")
          } label: {
            Text("Bluetooth")
          }
          LabeledContent {
            Text(ble.isConnected ? "Connected" : "Disconnected")
          } label: {
            Text("Connection")
          }
          LabeledContent {
            Text(ble.isReady ? "Ready" : "Not Ready")
          } label: {
            Text("Ready")
          }
        } header: {
          Text("Status")
        }

        Section {
          LabeledContent {
            VStack {
              Slider(value: $blinkCount, in: 1...10, step: 1)
                .padding(.horizontal)
            }
          } label: {
            Text("Blink count: \(Int(blinkCount))")
          }

          Button("Blink") {
            ble.sendBlinkCount(Int(blinkCount))
          }
          .disabled(!ble.isReady)
        } header: {
          Text("Blinking")
        }

        Section {
          ForEach(Array(ble.log.enumerated()), id: \.offset) { _, item in
            Text(item)
              .font(.system(size: 12))
          }
        } header: {
          Text("Log")
        }
      }
      .navigationTitle("Bluetooth")
    }
  }
}

#Preview {
  ContentView()
}
