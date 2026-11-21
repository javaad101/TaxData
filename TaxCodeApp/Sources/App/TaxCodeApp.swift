import AppIntents
import SwiftUI
import TaxData

@main
struct TaxCodeApp: App {
    @State private var corpus = CorpusController()
    @FocusedValue(\.focusedWindowActions) private var windowActions
    @AppStorage("readerFontSize") private var readerFontSize: Double = 16.0

    init() {
        TaxLawShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        DocumentGroup(newDocument: TaxWorkflowDocument()) { file in
            WorkspaceView(document: file.$document, corpus: corpus)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        #endif
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find…") {
                    windowActions?.focusSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(windowActions == nil)
            }

            CommandGroup(after: .newItem) {
                Divider()
                Button("New Entity") {
                    windowActions?.newEntity()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(windowActions == nil)

                Button("New Asset") {
                    windowActions?.newAsset()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(windowActions == nil)
            }

            CommandGroup(after: .toolbar) {
                Divider()
                Button("Bigger Text") {
                    readerFontSize = min(30, readerFontSize + 1.5)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Smaller Text") {
                    readerFontSize = max(12, readerFontSize - 1.5)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    readerFontSize = 16.0
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandMenu("Navigate") {
                Button("Search") {
                    windowActions?.focusSearch()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(windowActions == nil)

                Button("To-Do") {
                    windowActions?.openTodos()
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(windowActions == nil)

                Button("Day Count") {
                    windowActions?.openDayCount()
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(windowActions == nil)

                Divider()

                Button("New Tab") {
                    windowActions?.newTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!(windowActions?.canNewTab ?? false))

                Button("Split View") {
                    windowActions?.toggleSplitPane()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!(windowActions?.canNewTab ?? false))

                Divider()

                Button("Back") {
                    windowActions?.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(windowActions?.canGoBack ?? false))

                Button("Forward") {
                    windowActions?.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(windowActions?.canGoForward ?? false))

                Divider()

                Button("Volumes & XML…") {
                    corpus.isShowingVolumeManager = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Provision Viewer", for: ProvisionRoute.self) { $route in
            PopOutProvisionWindow(initialRoute: route, corpus: corpus)
        }
        #if os(macOS)
        .defaultSize(width: 680, height: 720)
        #endif
    }
}
