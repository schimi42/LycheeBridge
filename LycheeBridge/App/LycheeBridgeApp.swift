import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = NSImage(named: "AppIcon")
    }
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

        WindowGroup("Lychee Tags", id: "lycheeTags") {
            LycheeTagsView(viewModel: viewModel)
        }
        .defaultSize(width: 640, height: 520)

        WindowGroup("Upload Progress", id: "uploadProgress") {
            UploadProgressWindow(viewModel: viewModel)
        }
        .defaultSize(width: 720, height: 520)

        .commands {
            DiagnosticsCommands()
            LycheeCommands()
        }
    }
}

struct LycheeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Lychee") {
            Button("Show Tags") {
                openWindow(id: "lycheeTags")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
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

struct LycheeTagsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lychee Tags")
                .font(.title2.bold())

            Text("Existing tags are used as suggestions while editing photo metadata.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Refresh Tags") {
                    Task { await viewModel.refreshTags() }
                }
                .disabled(viewModel.tagState.isRunning)

                WindowStatusLine(message: viewModel.tagMessage, state: viewModel.tagState)
            }

            if viewModel.tags.isEmpty {
                ContentUnavailableView(
                    "No Tags Loaded",
                    systemImage: "tag",
                    description: Text("Connect to Lychee or refresh the tag list.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    TagList(tags: viewModel.tags)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .task {
            if viewModel.tags.isEmpty,
               viewModel.configuration.serverURLString.isEmpty == false,
               viewModel.configuration.username.isEmpty == false {
                await viewModel.refreshTags()
            }
        }
    }
}

struct UploadProgressWindow: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var countdown: Int?
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Upload Progress")
                    .font(.title2.bold())

                Spacer()

                Button(closeButtonTitle) {
                    closeTask?.cancel()
                    dismiss()
                }
            }

            WindowStatusLine(message: viewModel.uploadMessage, state: viewModel.uploadState)

            if viewModel.uploader.isUploading || viewModel.uploader.results.isEmpty == false {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.uploader.results) { result in
                            UploadResultRow(result: result)
                        }

                        if viewModel.uploader.completedSummary.isEmpty == false {
                            Text(viewModel.uploader.completedSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "No Upload Running",
                    systemImage: "arrow.up.circle",
                    description: Text("Start an upload from the main window.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .onChange(of: viewModel.uploadState) { _, _ in
            updateCountdown()
        }
        .onChange(of: viewModel.uploader.completedSummary) { _, _ in
            updateCountdown()
        }
        .onDisappear {
            closeTask?.cancel()
        }
    }

    private var closeButtonTitle: String {
        if let countdown {
            return "Close (\(countdown))"
        }

        return "Close"
    }

    private func updateCountdown() {
        guard viewModel.uploadState == .succeeded,
              viewModel.uploader.results.isEmpty == false,
              countdown == nil,
              closeTask == nil else {
            return
        }

        closeTask = Task {
            for remaining in stride(from: 3, through: 1, by: -1) {
                await MainActor.run {
                    countdown = remaining
                }

                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    return
                }
            }

            await MainActor.run {
                dismiss()
                closeTask = nil
                countdown = nil
            }
        }
    }
}

private struct WindowStatusLine: View {
    let message: String
    let state: AsyncButtonState

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(color)
            .textSelection(.enabled)
    }

    private var color: Color {
        switch state {
        case .failed:
            return .red
        case .succeeded:
            return .green
        case .idle, .running:
            return .secondary
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
