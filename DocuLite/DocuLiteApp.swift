import SwiftUI

@main
struct DocuLiteApp: App {
    @StateObject private var store = DocumentStore()

    var body: some Scene {
        WindowGroup("DocuLite") {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("保存") {
                    NotificationCenter.default.post(name: .doculiteSave, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}
