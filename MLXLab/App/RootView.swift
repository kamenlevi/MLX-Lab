import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case library = "Library"
    case convert = "Convert"
    case benchmark = "Benchmark"
    case compare = "Compare"
    case chat = "Chat"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .library:   return "books.vertical"
        case .convert:   return "arrow.triangle.2.circlepath"
        case .benchmark: return "speedometer"
        case .compare:   return "chart.bar.xaxis"
        case .chat:      return "bubble.left.and.bubble.right"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var bridge: PythonBridge
    @EnvironmentObject var library: ModelLibrary
    @State private var selection: Tab = .library

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $selection) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationTitle("MLX Lab")
            .listStyle(.sidebar)
            .frame(minWidth: 180)
        } detail: {
            ZStack {
                switch selection {
                case .library:   LibraryView()
                case .convert:   ConvertView()
                case .benchmark: BenchmarkView()
                case .compare:   CompareView()
                case .chat:      ChatView()
                }
            }
            .toolbar { BridgeStatusToolbar() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConvert)) { _ in selection = .convert }
        .onReceive(NotificationCenter.default.publisher(for: .openLibrary)) { _ in selection = .library }
        .onReceive(NotificationCenter.default.publisher(for: .openChat))    { _ in selection = .chat }
        .onReceive(NotificationCenter.default.publisher(for: .openCompare)) { _ in selection = .compare }
    }
}

struct BridgeStatusToolbar: ToolbarContent {
    @EnvironmentObject var bridge: PythonBridge

    var body: some ToolbarContent {
        ToolbarItem(placement: .status) {
            HStack(spacing: 6) {
                Circle()
                    .fill(bridge.status.color)
                    .frame(width: 8, height: 8)
                Text(bridge.status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
