import SwiftUI

struct ContentView: View {
  @State private var ble = BLEManager()
  @State private var sendingEntry: WasmEntry?

  var body: some View {
    NavigationStack {
      List {
        Section("Status") {
          LabeledContent("Bluetooth", value: ble.isBluetoothOn ? "ON" : "OFF")
          LabeledContent("Connection", value: ble.isConnected ? "Connected" : "Disconnected")
          LabeledContent("Ready", value: ble.isReady ? "Ready" : "Not Ready")
        }

        Section("WASM") {
          ForEach(WasmEntry.all) { entry in
            let isSendingThis = sendingEntry?.id == entry.id && ble.isSending

            LabeledContent {
              Button {
                send(entry: entry)
              } label: {
                Text("Send")
              }
              .disabled(!ble.isReady || ble.isSending)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                  .font(.system(.body, design: .monospaced))
                Text(entry.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if isSendingThis {
                  ProgressView(value: ble.sendProgress)
                    .tint(.blue)
                  Text("\(Int(ble.sendProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .contentTransition(.numericText())
                    .animation(.default, value: ble.sendProgress)
                }
              }
              .padding(.vertical, 2)
            }
          }
        }

        Section("Log") {
          NavigationLink("Show Log (\(ble.log.count))") {
            LogView(log: ble.log)
          }
        }
      }
      .navigationTitle("PicoW-BLE")
      .onChange(of: ble.isSending) { _, sending in
        if !sending { sendingEntry = nil }
      }
    }
  }

  private func send(entry: WasmEntry) {
    guard let url = Bundle.main.url(forResource: entry.resourceName, withExtension: "wasm") else {
      ble.log.append("❌ \(entry.displayName) not found in bundle")
      return
    }
    do {
      let data = try Data(contentsOf: url)
      ble.log.append("📂 \(entry.displayName) (\(data.count) bytes)")
      sendingEntry = entry
      ble.sendWasm(data)
    } catch {
      ble.log.append("❌ Read error: \(error.localizedDescription)")
    }
  }
}

#Preview {
  ContentView()
}
