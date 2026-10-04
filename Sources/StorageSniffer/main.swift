import SwiftUI

StorageSnifferApp.main()

struct StorageSnifferApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @ViewState private var model = AppModel()

    var body: some Scene {
        Window("Storage Sniffer", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshPermissions()
                }
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Scan…") { model.backToStart() }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Move to Trash") { model.undoTrash() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndoTrash)
            }
            CommandMenu("Go") {
                Button("Enclosing Folder") { model.goUp() }
                    .keyboardShortcut(.upArrow)
                    .disabled(!model.canGoUp)
                Button("Open Selected Folder") {
                    if let folder = model.item(for: model.selection)?.folder { model.open(folder) }
                }
                .keyboardShortcut(.downArrow)
                Divider()
                Button("Rescan") { model.rescanAll() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || model.root == nil)
            }
            CommandMenu("Item") {
                Button("Reveal in Finder") {
                    if let item = model.item(for: model.selection) { model.reveal(item) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Move to Trash…") {
                    if let item = model.item(for: model.selection) { model.requestTrash(item) }
                }
                .keyboardShortcut(.delete)
            }
        }
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.phase == .start {
                StartView()
            } else {
                BrowserView()
            }
        }
        .animation(.snappy(duration: 0.2), value: model.phase == .start)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from `swift run` there is no bundle, so make sure we get a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
