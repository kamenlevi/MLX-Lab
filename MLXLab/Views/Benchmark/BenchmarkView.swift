import Charts
import SwiftData
import SwiftUI

struct BenchmarkView: View {
    @EnvironmentObject var bridge: PythonBridge
    @EnvironmentObject var library: ModelLibrary
    @Query(sort: \ModelEntry.createdAt, order: .reverse) private var entries: [ModelEntry]

    @State private var pickedId: ModelEntry.ID?
    @State private var prefillTokens = 512
    @State private var decodeTokens = 128
    @State private var doPerplexity = true

    @State private var running = false
    @State private var progressPct = 0.0
    @State private var stage = ""
    @State private var stageMessage = ""
    @State private var errorText: String?
    @State private var latest: BenchmarkRun?
    @State private var activeId: String?

    private var picked: ModelEntry? { entries.first { $0.id == pickedId } }

    var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 320)
            results
                .frame(minWidth: 480)
        }
        .navigationTitle("Benchmark")
    }

    private var controls: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $pickedId) {
                    Text("Select…").tag(Optional<ModelEntry.ID>.none)
                    ForEach(entries) { entry in
                        Text("\(entry.displayName)").tag(Optional(entry.id))
                    }
                }
            }
            Section("Workload") {
                Stepper("Prefill tokens: \(prefillTokens)", value: $prefillTokens, in: 64...4096, step: 64)
                Stepper("Decode tokens: \(decodeTokens)", value: $decodeTokens, in: 16...1024, step: 16)
                Toggle("Compute perplexity (WikiText2 sample)", isOn: $doPerplexity)
            }
            Section {
                Button(running ? "Running…" : "Run Benchmark") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(picked == nil || running)
                if running {
                    ProgressView(value: progressPct)
                    Text("\(stage) — \(stageMessage)").font(.caption).foregroundStyle(.secondary)
                }
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top)
    }

    @ViewBuilder
    private var results: some View {
        if let run = latest ?? picked?.benchmarks.sorted(by: { $0.ranAt > $1.ranAt }).first {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Latest run").font(.headline)
                    statsGrid(run)
                    Chart {
                        BarMark(x: .value("Metric", "Prefill tok/s"), y: .value("Value", run.prefillTps))
                            .foregroundStyle(.blue)
                        BarMark(x: .value("Metric", "Decode tok/s"), y: .value("Value", run.decodeTps))
                            .foregroundStyle(.green)
                    }
                    .frame(height: 200)
                    Chart {
                        BarMark(x: .value("Metric", "Peak GB"), y: .value("Value", run.peakMemoryGb))
                            .foregroundStyle(.orange)
                        BarMark(x: .value("Metric", "Active GB"), y: .value("Value", run.activeMemoryGb))
                            .foregroundStyle(.yellow)
                    }
                    .frame(height: 200)
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("No results yet",
                                   systemImage: "speedometer",
                                   description: Text("Pick a model and press Run Benchmark."))
        }
    }

    private func statsGrid(_ run: BenchmarkRun) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                Text("First token").foregroundStyle(.secondary)
                Text("\(run.firstTokenMs, format: .number.precision(.fractionLength(1))) ms")
            }
            GridRow {
                Text("Prefill").foregroundStyle(.secondary)
                Text("\(run.prefillTps, format: .number.precision(.fractionLength(1))) tok/s over \(run.prefillTokens) tokens")
            }
            GridRow {
                Text("Decode").foregroundStyle(.secondary)
                Text("\(run.decodeTps, format: .number.precision(.fractionLength(1))) tok/s over \(run.decodeTokens) tokens")
            }
            GridRow {
                Text("Peak memory").foregroundStyle(.secondary)
                Text("\(run.peakMemoryGb, format: .number.precision(.fractionLength(2))) GB (active \(run.activeMemoryGb, format: .number.precision(.fractionLength(2))))")
            }
            if let ppl = run.perplexity {
                GridRow {
                    Text("Perplexity").foregroundStyle(.secondary)
                    Text("\(ppl, format: .number.precision(.fractionLength(2))) over \(run.perplexityTokens) tokens")
                }
            }
            GridRow {
                Text("Elapsed").foregroundStyle(.secondary)
                Text("\(run.elapsedSeconds, format: .number.precision(.fractionLength(1))) s")
            }
        }
    }

    private func run() {
        guard let picked else { return }
        running = true; progressPct = 0; errorText = nil
        do {
            activeId = try bridge.call(op: "benchmark", payload: [
                "model_path": picked.directoryPath,
                "prefill_tokens": prefillTokens,
                "decode_tokens": decodeTokens,
                "perplexity": doPerplexity,
            ]) { event in handle(event: event, on: picked) }
        } catch {
            running = false
            errorText = error.localizedDescription
        }
    }

    private func handle(event: BridgeEvent, on entry: ModelEntry) {
        switch event.kind {
        case .progress(let p, let s, let m):
            progressPct = p; stage = s; stageMessage = m
        case .done(let r):
            running = false
            let run = BenchmarkRun(
                prefillTokens: r.int("prefill_tokens") ?? prefillTokens,
                prefillTps: r.double("prefill_tps") ?? 0,
                decodeTokens: r.int("decode_tokens") ?? decodeTokens,
                decodeTps: r.double("decode_tps") ?? 0,
                firstTokenMs: r.double("first_token_ms") ?? 0,
                peakMemoryGb: r.double("peak_memory_gb") ?? 0,
                activeMemoryGb: r.double("active_memory_gb") ?? 0,
                perplexity: r.double("perplexity"),
                perplexityTokens: r.int("perplexity_tokens") ?? 0,
                elapsedSeconds: r.double("elapsed_seconds") ?? 0
            )
            library.attachBenchmark(run, to: entry)
            latest = run
        case .error(let msg, _):
            running = false
            errorText = msg
        default: break
        }
    }
}
