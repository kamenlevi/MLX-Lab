import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var bridge: PythonBridge
    @AppStorage("pythonPath") private var pythonPath: String = ""
    @AppStorage("defaultPrefillTokens") private var defaultPrefill: Int = 512
    @AppStorage("defaultDecodeTokens") private var defaultDecode: Int = 128

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            paths.tabItem { Label("Paths", systemImage: "folder") }
            help.tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        .frame(width: 520, height: 320)
        .padding()
    }

    private var general: some View {
        Form {
            Section("Defaults") {
                Stepper("Default prefill tokens: \(defaultPrefill)",
                        value: $defaultPrefill, in: 64...4096, step: 64)
                Stepper("Default decode tokens: \(defaultDecode)",
                        value: $defaultDecode, in: 16...1024, step: 16)
            }
            Section("Python") {
                HStack {
                    TextField("python3.11 path (blank = auto-detect)", text: $pythonPath)
                    Button("Browse…") { browsePython() }
                }
                Text(bridge.status.label).font(.caption).foregroundStyle(.secondary)
                if let err = bridge.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var paths: some View {
        Form {
            Section("Locations") {
                LabeledContent("App support") { Text(AppPaths.appSupport.path) }
                LabeledContent("Models") { Text(AppPaths.modelsDir.path) }
                LabeledContent("venv") { Text(AppPaths.venvDir.path) }
                LabeledContent("Bridge log") { Text(AppPaths.bridgeLog.path) }
            }
            Section {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.appSupport])
                }
            }
        }
        .formStyle(.grouped)
    }

    private var help: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Requirements").font(.headline)
                Text("• Apple Silicon Mac running macOS Sonoma or newer.\n• Homebrew python@3.11 in PATH (`brew install python@3.11`).\n• ~6–30 GB free disk depending on model size.")
                Text("Conversion").font(.headline)
                Text("MLX Lab calls `mlx_lm.convert` with affine quantization. The Q3/Q4/Q6/Q8 labels map to 3/4/6/8-bit affine quant with a group size of 64. There is no MLX equivalent of GGUF's _K variants.")
                Text("Benchmarks").font(.headline)
                Text("Prefill and decode throughputs come directly from `stream_generate`; peak memory from `mx.metal.get_peak_memory()`; perplexity from a fixed WikiText-2 sample of ~512 tokens averaged over 256-token windows.")
                Text("Logs").font(.headline)
                Text(AppPaths.bridgeLog.path).font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 4)
        }
    }

    private func browsePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            pythonPath = url.path
        }
    }
}
