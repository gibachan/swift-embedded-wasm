import SwiftUI

struct LogView: View {
  let log: [String]

  var body: some View {
    List {
      ForEach(Array(log.enumerated()), id: \.offset) { _, item in
        Text(item)
          .font(.system(size: 12, design: .monospaced))
      }
    }
    .navigationTitle("Log")
    .navigationBarTitleDisplayMode(.inline)
    .overlay {
      if log.isEmpty {
        ContentUnavailableView("No Logs", systemImage: "doc.text")
      }
    }
  }
}

#Preview {
  NavigationStack {
    LogView(log: ["🔍 Start Scan", "👀 Found: PicoLED", "🔗 Connected", "🎯 Writable characteristic found"])
  }
}
