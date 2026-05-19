import Charts
import SwiftData
import SwiftUI

struct CompareView: View {
    @Query(sort: \ModelEntry.createdAt, order: .reverse) private var entries: [ModelEntry]
    @State private var selected: Set<ModelEntry.ID> = []

    private struct Row: Identifiable {
        let id = UUID()
        let label: String
        let metric: String
        let value: Double
    }

    var body: some View {
        HSplitView {
            picker.frame(minWidth: 280)
            charts.frame(minWidth: 540)
        }
        .navigationTitle("Compare")
    }

    private var picker: some View {
        List(entries, selection: $selected) { entry in
            let latest = entry.benchmarks.sorted(by: { $0.ranAt > $1.ranAt }).first
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                if let r = latest {
                    Text("decode \(r.decodeTps, format: .number.precision(.fractionLength(1))) tok/s · \(r.peakMemoryGb, format: .number.precision(.fractionLength(2))) GB")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("no benchmarks yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tag(entry.id)
        }
        .listStyle(.inset)
    }

    private var picked: [ModelEntry] {
        entries.filter { selected.contains($0.id) }
    }

    private func latest(_ e: ModelEntry) -> BenchmarkRun? {
        e.benchmarks.sorted(by: { $0.ranAt > $1.ranAt }).first
    }

    @ViewBuilder
    private var charts: some View {
        if picked.count < 2 {
            ContentUnavailableView("Pick 2 or more models",
                                   systemImage: "chart.bar.xaxis",
                                   description: Text("Hold ⌘ to multi-select on the left."))
        } else if picked.contains(where: { latest($0) == nil }) {
            ContentUnavailableView("Missing benchmarks",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text("Every selected model needs at least one benchmark run."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    chart(title: "Decode tok/s") { entry in latest(entry)?.decodeTps ?? 0 }
                    chart(title: "Prefill tok/s") { entry in latest(entry)?.prefillTps ?? 0 }
                    chart(title: "Peak memory (GB)") { entry in latest(entry)?.peakMemoryGb ?? 0 }
                    chart(title: "First-token latency (ms)") { entry in latest(entry)?.firstTokenMs ?? 0 }
                    chart(title: "Perplexity") { entry in latest(entry)?.perplexity ?? 0 }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func chart(title: String, value: (ModelEntry) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Chart(picked) { entry in
                BarMark(
                    x: .value("Model", entry.displayName),
                    y: .value(title, value(entry))
                )
                .foregroundStyle(by: .value("Model", entry.displayName))
            }
            .frame(height: 220)
        }
    }
}
