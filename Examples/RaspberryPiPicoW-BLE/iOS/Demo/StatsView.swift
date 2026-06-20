import Charts
import SwiftUI

struct ExecutionStats: Identifiable {
  let id = UUID()
  let run: Int
  let instructionCount: UInt64
  let peakValueStack: Int
  let peakCallStack: Int

  // Parses "STATS:<instr>,<vsDepth>,<csDepth>"
  init?(statsLine: String, run: Int = 0) {
    let body = statsLine.dropFirst("STATS:".count)
    let parts = body.split(separator: ",", maxSplits: 2)
    guard parts.count == 3,
      let instr = UInt64(parts[0]),
      let vs = Int(parts[1]),
      let cs = Int(parts[2])
    else { return nil }
    self.run = run
    self.instructionCount = instr
    self.peakValueStack = vs
    self.peakCallStack = cs
  }
}

@available(iOS 16, *)
struct StatsView: View {
  let stats: [ExecutionStats]
  let onClear: () -> Void

  var body: some View {
    List {
      if stats.isEmpty {
        Text("No execution stats yet.\nRun a Wasm binary to see results.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
      } else {
        Section("Instructions Executed") {
          Chart(stats) { s in
            BarMark(
              x: .value("Run", s.run),
              y: .value("Instructions", Double(s.instructionCount))
            )
            .foregroundStyle(.blue)
          }
          .chartXAxisLabel("Execution #")
          .chartYAxisLabel("Count")
          .frame(height: 160)
        }

        Section("Stack Watermarks") {
          Chart(stats) { s in
            LineMark(
              x: .value("Run", s.run),
              y: .value("Depth", s.peakValueStack)
            )
            .foregroundStyle(.green)
            .symbol(.circle)

            LineMark(
              x: .value("Run", s.run),
              y: .value("Depth", s.peakCallStack)
            )
            .foregroundStyle(.orange)
            .symbol(.square)
          }
          .chartForegroundStyleScale([
            "Value Stack": Color.green,
            "Call Stack": Color.orange,
          ])
          .chartLegend(position: .topLeading)
          .frame(height: 160)
        }

        Section("Latest Run") {
          if let latest = stats.last {
            LabeledContent("Instructions", value: String(latest.instructionCount))
            LabeledContent("Peak Value Stack", value: "\(latest.peakValueStack)")
            LabeledContent("Peak Call Stack", value: "\(latest.peakCallStack)")
          }
        }

        Section {
          Button("Clear Stats", role: .destructive, action: onClear)
        }
      }
    }
    .navigationTitle("Execution Stats")
  }
}
