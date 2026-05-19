import SwiftData
import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: String
    var content: String
}

struct ChatView: View {
    @EnvironmentObject var bridge: PythonBridge
    @Query(sort: \ModelEntry.createdAt, order: .reverse) private var entries: [ModelEntry]

    @State private var pickedId: ModelEntry.ID?
    @State private var system: String = "You are a helpful assistant."
    @State private var draft: String = ""
    @State private var messages: [ChatMessage] = []
    @State private var generating = false
    @State private var firstTokenMs: Double?
    @State private var lastTps: Double = 0
    @State private var errorText: String?
    @State private var temperature: Double = 0.7
    @State private var maxTokens: Int = 512

    private var picked: ModelEntry? { entries.first { $0.id == pickedId } }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 280)
            transcript.frame(minWidth: 480)
        }
        .navigationTitle("Chat")
    }

    private var sidebar: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $pickedId) {
                    Text("Select…").tag(Optional<ModelEntry.ID>.none)
                    ForEach(entries) { e in Text(e.displayName).tag(Optional(e.id)) }
                }
            }
            Section("Sampling") {
                Slider(value: $temperature, in: 0...1.2, step: 0.05) { Text("Temperature") }
                Text("temperature \(temperature, format: .number.precision(.fractionLength(2)))")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Max tokens: \(maxTokens)", value: $maxTokens, in: 32...4096, step: 32)
            }
            Section("System") {
                TextEditor(text: $system)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
            }
            Section {
                Button("Clear conversation") {
                    messages.removeAll()
                    firstTokenMs = nil
                    lastTps = 0
                }
                .disabled(messages.isEmpty || generating)
            }
        }
        .formStyle(.grouped)
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { m in
                            MessageBubble(message: m)
                                .id(m.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.last?.content) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            stats
            composer
        }
    }

    private var stats: some View {
        HStack(spacing: 12) {
            if let ms = firstTokenMs {
                Text("first token \(ms, format: .number.precision(.fractionLength(0))) ms")
            }
            if lastTps > 0 {
                Text("\(lastTps, format: .number.precision(.fractionLength(1))) tok/s")
            }
            Spacer()
            if let errorText {
                Text(errorText).foregroundStyle(.red).lineLimit(1)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 140)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Type a message — ⌘↩ to send")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                }
            Button("Send") { send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(generating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || picked == nil)
        }
        .padding(12)
    }

    private func send() {
        guard let picked else { return }
        let userMsg = ChatMessage(role: "user", content: draft.trimmingCharacters(in: .whitespacesAndNewlines))
        messages.append(userMsg)
        let assistant = ChatMessage(role: "assistant", content: "")
        messages.append(assistant)
        draft = ""
        generating = true
        firstTokenMs = nil
        errorText = nil

        var payload: [String: Any] = [
            "model_path": picked.directoryPath,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": 0.95,
        ]
        var msgs: [[String: String]] = []
        if !system.isEmpty { msgs.append(["role": "system", "content": system]) }
        for m in messages where !m.content.isEmpty || m.role != "assistant" {
            msgs.append(["role": m.role, "content": m.content])
        }
        payload["messages"] = msgs

        do {
            _ = try bridge.call(op: "chat", payload: payload) { event in
                switch event.kind {
                case .firstToken(let ms):
                    firstTokenMs = ms
                case .token(let text, let tps):
                    lastTps = tps
                    if let i = messages.indices.last { messages[i].content += text }
                case .done(let r):
                    generating = false
                    lastTps = r.double("generation_tps") ?? lastTps
                case .error(let msg, _):
                    generating = false
                    errorText = msg
                default: break
                }
            }
        } catch {
            generating = false
            errorText = error.localizedDescription
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top) {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role.capitalized).font(.caption.bold()).foregroundStyle(.secondary)
                Text(message.content.isEmpty ? " " : message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(
                        message.role == "user"
                        ? Color.accentColor.opacity(0.18)
                        : Color.secondary.opacity(0.08)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }
}
