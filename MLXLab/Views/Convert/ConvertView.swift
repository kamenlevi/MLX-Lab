import SwiftUI

enum Quant: String, CaseIterable, Identifiable {
    case q3 = "q3", q4 = "q4", q6 = "q6", q8 = "q8", fp16 = "fp16"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .q3:   return "Q3 (3-bit affine, group 64)"
        case .q4:   return "Q4 (4-bit affine, group 64)"
        case .q6:   return "Q6 (6-bit affine, group 64)"
        case .q8:   return "Q8 (8-bit affine, group 64)"
        case .fp16: return "fp16 (no quantization)"
        }
    }
}

struct ConvertView: View {
    @EnvironmentObject var bridge: PythonBridge
    @EnvironmentObject var library: ModelLibrary

    @State private var query = ""
    @State private var results: [HFClient.Model] = []
    @State private var searching = false
    @State private var picked: HFClient.Model?
    @State private var pickedDetail: HFClient.ModelDetail?

    @State private var quant: Quant = .q4
    @State private var converting = false
    @State private var progressPct: Double = 0
    @State private var stage: String = ""
    @State private var stageMessage: String = ""
    @State private var errorText: String?
    @State private var activeRequestId: String?

    private let hf = HFClient()

    var body: some View {
        HSplitView {
            picker
                .frame(minWidth: 360, idealWidth: 420)
            wizard
                .frame(minWidth: 420)
        }
        .navigationTitle("Convert")
    }

    // MARK: search picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Search HuggingFace (e.g. Qwen3)", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runSearch)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).padding(.top, 12)

            List(selection: Binding(
                get: { picked?.id },
                set: { id in
                    picked = results.first { $0.id == id }
                    Task { await loadDetail() }
                }
            )) {
                ForEach(results) { m in
                    HFResultRow(model: m).tag(m.id)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: wizard

    private var wizard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let picked {
                    Text(picked.modelId).font(.title2).bold()
                    HStack(spacing: 8) {
                        if let tag = picked.pipelineTag { Tag(text: tag) }
                        if let dl = picked.downloads { Tag(text: "↓ \(dl.formatted(.number.notation(.compactName)))") }
                        compatibilityBadge
                    }
                    if let pickedDetail {
                        DisclosureGroup("Repository files (\(pickedDetail.siblings?.count ?? 0))") {
                            ForEach(pickedDetail.siblings ?? [], id: \.rfilename) { s in
                                Text(s.rfilename).font(.system(.caption, design: .monospaced))
                            }
                        }
                    }

                    Divider()

                    Picker("Quantization", selection: $quant) {
                        ForEach(Quant.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.radioGroup)

                    Divider()

                    HStack {
                        Button(converting ? "Converting…" : "Start Conversion") {
                            startConvert()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(converting)

                        if converting, activeRequestId != nil {
                            Button("Cancel") { cancelConvert() }
                                .buttonStyle(.bordered)
                        }
                    }

                    if converting || progressPct > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: progressPct)
                            HStack {
                                Text(stage.isEmpty ? "preparing" : stage)
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(progressPct * 100))%")
                                    .font(.caption.monospacedDigit())
                            }
                            if !stageMessage.isEmpty {
                                Text(stageMessage).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                } else {
                    ContentUnavailableView(
                        "Pick a model",
                        systemImage: "magnifyingglass",
                        description: Text("Search for an HF model, then choose a quantization.")
                    )
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var compatibilityBadge: some View {
        let tags = pickedDetail?.tags ?? picked?.tags ?? []
        let compat = HFClient.compatibility(for: tags)
        switch compat {
        case .supported:  Tag(text: "Supported")
        case .unknown:    Tag(text: "Unknown arch — may fail")
        case .unsupported:Tag(text: "Unsupported")
        }
    }

    // MARK: actions

    private func runSearch() {
        guard !query.isEmpty else { return }
        searching = true
        Task {
            defer { searching = false }
            do { results = try await hf.search(query: query) }
            catch { errorText = "Search failed: \(error.localizedDescription)" }
        }
    }

    private func loadDetail() async {
        guard let picked else { pickedDetail = nil; return }
        do { pickedDetail = try await hf.detail(repoId: picked.modelId) }
        catch { pickedDetail = nil }
    }

    private func startConvert() {
        guard let picked else { return }
        let safe = picked.modelId.replacingOccurrences(of: "/", with: "_")
        let outDir = AppPaths.modelsDir
            .appendingPathComponent("\(safe)-\(quant.rawValue)", isDirectory: true)

        if FileManager.default.fileExists(atPath: outDir.path) {
            errorText = "Output exists: \(outDir.path). Delete it first."
            return
        }

        converting = true
        progressPct = 0
        stage = ""
        stageMessage = ""
        errorText = nil

        do {
            activeRequestId = try bridge.call(op: "convert", payload: [
                "model": picked.modelId,
                "quant": quant.rawValue,
                "out_dir": outDir.path,
            ]) { event in
                handle(event: event, picked: picked, outDir: outDir)
            }
        } catch {
            converting = false
            errorText = error.localizedDescription
        }
    }

    private func handle(event: BridgeEvent, picked: HFClient.Model, outDir: URL) {
        switch event.kind {
        case .progress(let pct, let st, let msg):
            progressPct = pct
            stage = st
            stageMessage = msg
        case .log:
            break
        case .done(let result):
            converting = false
            activeRequestId = nil
            progressPct = 1.0
            let cfg = result.dict("config") ?? [:]
            _ = library.insertEntry(
                displayName: "\(picked.modelId.components(separatedBy: "/").last ?? picked.modelId) — \(quant.rawValue)",
                hfRepoId: picked.modelId,
                quantLabel: quant.rawValue,
                directoryPath: result.string("out_dir") ?? outDir.path,
                sizeBytes: Int64(result.int("size_bytes") ?? 0),
                architecture: (cfg["architectures"] as? [Any])?.first as? String,
                hiddenSize: cfg["hidden_size"] as? Int,
                numLayers: cfg["num_hidden_layers"] as? Int,
                vocabSize: cfg["vocab_size"] as? Int
            )
        case .error(let msg, _):
            converting = false
            activeRequestId = nil
            errorText = msg
        default: break
        }
    }

    private func cancelConvert() {
        if let id = activeRequestId { bridge.unregister(id) }
        activeRequestId = nil
        converting = false
        errorText = "Cancelled — partial files may remain on disk."
    }
}

private struct HFResultRow: View {
    let model: HFClient.Model
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.modelId).font(.system(.body, design: .monospaced))
            HStack(spacing: 8) {
                if let dl = model.downloads {
                    Label("\(dl.formatted(.number.notation(.compactName)))", systemImage: "arrow.down.circle")
                }
                if let likes = model.likes, likes > 0 {
                    Label("\(likes)", systemImage: "heart")
                }
                if let tag = model.pipelineTag { Text(tag) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
