import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
}

@main
struct LycheeBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .windowResizability(.contentSize)

        WindowGroup("API Diagnostics", id: "apiDiagnostics") {
            DiagnosticsView(viewModel: viewModel)
        }
        .defaultSize(width: 900, height: 620)

        .commands {
            DiagnosticsCommands()
        }
    }
}

struct DiagnosticsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Diagnostics") {
            Button("Show API Diagnostics") {
                openWindow(id: "apiDiagnostics")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Diagnostics")
                .font(.title2.bold())

            Text("Request and response traces are redacted before they are stored here.")
                .foregroundStyle(.secondary)

            ScrollView {
                Text(viewModel.debugLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 420)
    }
}
