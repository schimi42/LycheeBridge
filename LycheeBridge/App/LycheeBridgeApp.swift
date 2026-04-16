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

        WindowGroup("Metadata Diagnostics", id: "metadataDiagnostics") {
            MetadataDiagnosticsView(viewModel: viewModel)
        }
        .defaultSize(width: 760, height: 620)

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

            Button("Show Metadata Diagnostics") {
                openWindow(id: "metadataDiagnostics")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
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

struct MetadataDiagnosticsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metadata Diagnostics")
                .font(.title2.bold())

            Text("Embedded metadata from the shared files is shown here before Lychee upload support is added.")
                .foregroundStyle(.secondary)

            if let bundle = viewModel.pendingBundle {
                List(bundle.items) { item in
                    MetadataDiagnosticsRow(item: item)
                }
            } else {
                ContentUnavailableView(
                    "No Pending Import",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Share photos to LycheeBridge, then reopen this window to inspect embedded title and tag metadata.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct MetadataDiagnosticsRow: View {
    let item: ImportedPhoto

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.displayName)
                .font(.headline)

            if let metadata = item.metadata {
                labeledValue("Detected title", metadata.title ?? "None")
                labeledValue("Detected tags", metadata.tags.isEmpty ? "None" : metadata.tags.joined(separator: ", "))

                if metadata.fields.isEmpty {
                    Text("No title, tag, keyword, caption, or description fields were found in the embedded image metadata.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Matched fields")
                            .font(.subheadline.bold())

                        ForEach(metadata.fields) { field in
                            Text("\(field.source) / \(field.name): \(field.value)")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text("No metadata extractor result was stored for this import.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
