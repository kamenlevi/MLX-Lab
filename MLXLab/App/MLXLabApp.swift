import SwiftData
import SwiftUI

@main
struct MLXLabApp: App {
    @StateObject private var bridge = PythonBridge.shared
    @StateObject private var library = ModelLibrary.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bridge)
                .environmentObject(library)
                .frame(minWidth: 980, minHeight: 640)
                .task { await bridge.startIfNeeded() }
        }
        .modelContainer(library.container)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversion…") { NotificationCenter.default.post(name: .openConvert, object: nil) }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Show Library") { NotificationCenter.default.post(name: .openLibrary, object: nil) }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Show Chat") { NotificationCenter.default.post(name: .openChat, object: nil) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Show Compare") { NotificationCenter.default.post(name: .openCompare, object: nil) }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(bridge)
                .environmentObject(library)
        }
    }
}

extension Notification.Name {
    static let openConvert = Notification.Name("MLXLab.openConvert")
    static let openLibrary = Notification.Name("MLXLab.openLibrary")
    static let openChat = Notification.Name("MLXLab.openChat")
    static let openCompare = Notification.Name("MLXLab.openCompare")
}
