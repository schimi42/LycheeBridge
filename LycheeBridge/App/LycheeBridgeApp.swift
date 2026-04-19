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

        WindowGroup("LLM Settings", id: "llmSettings") {
            LLMSettingsView(viewModel: viewModel)
        }
        .defaultSize(width: 720, height: 680)

        WindowGroup("LLM Diagnostics", id: "llmDiagnostics") {
            LLMDiagnosticsView(viewModel: viewModel)
        }
        .defaultSize(width: 900, height: 680)

        WindowGroup("Existing Photo Metadata", id: "existingPhotoMetadata") {
            ExistingPhotoMetadataView(viewModel: viewModel)
        }
        .defaultSize(width: 820, height: 640)

        .commands {
            DiagnosticsCommands()
            LycheeCommands()
            LLMCommands()
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

struct LLMCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("LLM") {
            Button("Show LLM Settings") {
                openWindow(id: "llmSettings")
            }
            .keyboardShortcut(",", modifiers: [.command, .shift])

            Button("Show LLM Diagnostics") {
                openWindow(id: "llmDiagnostics")
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Show Existing Photo Metadata") {
                openWindow(id: "existingPhotoMetadata")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
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

struct LLMSettingsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var preferredTagsText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("LLM Settings")
                    .font(.title2.bold())

                Text("Configure the vision model used to suggest titles and tags before uploading.")
                    .foregroundStyle(.secondary)

                GroupBox("Provider") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Provider", selection: $viewModel.llmConfiguration.providerKind) {
                            ForEach(LLMProviderKind.selectableCases) { providerKind in
                                Text(providerKind.title).tag(providerKind)
                            }
                        }
                        .pickerStyle(.menu)

                        switch viewModel.llmConfiguration.providerKind {
                        case .ollama:
                            TextField("Ollama server URL", text: $viewModel.llmConfiguration.endpointURLString)
                                .textFieldStyle(.roundedBorder)

                            TextField("Ollama model", text: $viewModel.llmConfiguration.modelName)
                                .textFieldStyle(.roundedBorder)
                        case .openAI:
                            TextField("OpenAI API base URL", text: $viewModel.llmConfiguration.openAIEndpointURLString)
                                .textFieldStyle(.roundedBorder)

                            SecureField("OpenAI API key", text: $viewModel.llmCredentials.openAIAPIKey)
                                .textFieldStyle(.roundedBorder)

                            TextField("OpenAI model", text: $viewModel.llmConfiguration.openAIModelName)
                                .textFieldStyle(.roundedBorder)

                            Text("The API key is stored in Keychain. The selected image preview is sent to OpenAI when suggestions are requested.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .openWebUI, .openAICompatible, .gemini:
                            EmptyView()
                        }

                        Toggle("Suggest titles", isOn: $viewModel.llmConfiguration.shouldSuggestTitle)
                            .toggleStyle(.switch)

                        Toggle("Suggest tags", isOn: $viewModel.llmConfiguration.shouldSuggestTags)
                            .toggleStyle(.switch)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Image Sent to LLM") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper(
                            "Maximum dimension: \(viewModel.llmConfiguration.imageOptions.maxPixelDimension) px",
                            value: $viewModel.llmConfiguration.imageOptions.maxPixelDimension,
                            in: 256...2048,
                            step: 128
                        )

                        HStack {
                            Text("JPEG quality")
                            Slider(value: $viewModel.llmConfiguration.imageOptions.jpegQuality, in: 0.35...0.95)
                            Text(viewModel.llmConfiguration.imageOptions.jpegQuality.formatted(.number.precision(.fractionLength(2))))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Prompt") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $viewModel.llmConfiguration.prompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 150)
                            .border(.quaternary)

                        Button("Reset Prompt") {
                            viewModel.resetLLMPrompt()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Preferred Tags") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("One tag per line. These are sent to the LLM as preferred suggestions.")
                            .foregroundStyle(.secondary)

                        TextEditor(text: $preferredTagsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 150)
                            .border(.quaternary)

                        HStack(spacing: 12) {
                            Button("Add Loaded Lychee Tags") {
                                commitPreferredTagsText()
                                viewModel.addLycheeTagsToLLMPreferredTags()
                                syncPreferredTagsText()
                            }
                            .disabled(viewModel.tags.isEmpty)

                            Button("Reset Default Tags") {
                                viewModel.resetLLMPreferredTags()
                                syncPreferredTagsText()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button("Save LLM Settings") {
                        commitPreferredTagsText()
                        viewModel.saveLLMConfiguration()
                    }
                    .buttonStyle(.borderedProminent)

                    WindowStatusLine(message: viewModel.llmMessage, state: viewModel.llmState)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear(perform: syncPreferredTagsText)
    }

    private func syncPreferredTagsText() {
        preferredTagsText = viewModel.llmConfiguration.normalizedPreferredTags.joined(separator: "\n")
    }

    private func commitPreferredTagsText() {
        let tags = preferredTagsText
            .components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: ",") }
        viewModel.llmConfiguration.preferredTags = ImportedPhotoEditableMetadata.normalizedTags(tags)
    }
}

struct LLMDiagnosticsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LLM Diagnostics")
                .font(.title2.bold())

            Text("The prepared image, prompt, and latest provider response are shown here.")
                .foregroundStyle(.secondary)

            if let diagnostic = viewModel.llmDiagnostic {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            diagnosticImage(diagnostic)

                            VStack(alignment: .leading, spacing: 8) {
                                Text(diagnostic.photoName)
                                    .font(.headline)
                                Text(diagnostic.createdAt.formatted(date: .abbreviated, time: .standard))
                                    .foregroundStyle(.secondary)

                                if let image = diagnostic.preparedImage {
                                    Text("\(image.pixelWidth) x \(image.pixelHeight), \(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file))")
                                        .foregroundStyle(.secondary)
                                }

                                if let suggestion = diagnostic.suggestion {
                                    labeledDiagnosticValue("Title", suggestion.normalizedTitle ?? "None")
                                    labeledDiagnosticValue("Tags", suggestion.normalizedTags.isEmpty ? "None" : suggestion.normalizedTags.joined(separator: ", "))
                                }
                            }
                        }

                        diagnosticTextBlock(title: "Prompt", text: diagnostic.prompt)
                        diagnosticTextBlock(title: "Response", text: diagnostic.response)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "No LLM Request Yet",
                    systemImage: "sparkles",
                    description: Text("Use Suggest with LLM on a pending photo to inspect the submitted image and prompt.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 480)
    }

    @ViewBuilder
    private func diagnosticImage(_ diagnostic: LLMDiagnosticSnapshot) -> some View {
        if let data = diagnostic.preparedImage?.data,
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 220, height: 220)
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private func labeledDiagnosticValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func diagnosticTextBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct ExistingPhotoMetadataView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Existing Photo Metadata")
                .font(.title2.bold())

            Text("Scan a Lychee album, send matching photos to the configured LLM, and apply suggested titles and tags back to Lychee.")
                .foregroundStyle(.secondary)

            GroupBox("Album Scan") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Album", selection: $viewModel.existingPhotoAlbumID) {
                        ForEach(viewModel.albums) { album in
                            Text(album.displayTitle).tag(album.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(viewModel.albums.isEmpty || viewModel.existingPhotoState.isRunning)

                    Picker("Photos", selection: $viewModel.existingPhotoFilter) {
                        ForEach(ExistingPhotoMetadataFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.existingPhotoState.isRunning)

                    Toggle("Overwrite existing titles by default", isOn: $viewModel.existingPhotoOverwriteExistingTitles)
                        .toggleStyle(.switch)
                        .disabled(viewModel.existingPhotoState.isRunning)

                    HStack(spacing: 12) {
                        Button("Load Photos") {
                            Task { await viewModel.loadExistingPhotosForMetadata() }
                        }
                        .disabled(viewModel.existingPhotoState.isRunning || viewModel.existingPhotoAlbumID.isEmpty)

                        Button("Suggest and Apply") {
                            Task { await viewModel.suggestMetadataForExistingPhotos() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.existingPhotoState.isRunning || viewModel.filteredExistingPhotos.isEmpty)

                        WindowStatusLine(message: viewModel.existingPhotoMessage, state: viewModel.existingPhotoState)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Suggestions are written directly to Lychee. Tags are appended. Photos without a meaningful title always receive one; existing titles are replaced only when enabled globally or per photo.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.existingPhotoResults.isEmpty {
                        ForEach(viewModel.filteredExistingPhotos) { photo in
                            ExistingPhotoRow(
                                photo: photo,
                                result: nil,
                                overwriteExistingTitle: Binding(
                                    get: { viewModel.existingPhotoShouldOverwriteTitle(for: photo) },
                                    set: { viewModel.setExistingPhotoTitleOverwrite($0, for: photo.id) }
                                ),
                                canEditTitleOverwrite: viewModel.existingPhotoState.isRunning == false
                            )
                        }
                    } else {
                        ForEach(viewModel.existingPhotoResults) { result in
                            ExistingPhotoRow(
                                photo: result.photo,
                                result: result,
                                overwriteExistingTitle: Binding(
                                    get: { viewModel.existingPhotoShouldOverwriteTitle(for: result.photo) },
                                    set: { viewModel.setExistingPhotoTitleOverwrite($0, for: result.photo.id) }
                                ),
                                canEditTitleOverwrite: viewModel.existingPhotoState.isRunning == false
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            viewModel.prepareExistingPhotoMetadataWindow()
        }
    }
}

private struct ExistingPhotoRow: View {
    let photo: LycheePhoto
    let result: ExistingPhotoMetadataResult?
    @Binding var overwriteExistingTitle: Bool
    let canEditTitleOverwrite: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(photo.displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                Text(photo.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Text(metadataSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let suggestion = result?.suggestion {
                    Text("Suggested: \(suggestion.normalizedTitle ?? "No title") · \(suggestion.normalizedTags.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if photo.hasMeaningfulTitle {
                    Toggle("Replace existing title", isOn: $overwriteExistingTitle)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .disabled(canEditTitleOverwrite == false)
                } else {
                    Text("Title will be applied")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.trailing)
                .frame(width: 180, alignment: .trailing)
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var metadataSummary: String {
        let titleState = photo.hasMeaningfulTitle ? "title set" : "no title"
        let tagState = photo.normalizedTags.isEmpty ? "no tags" : photo.normalizedTags.joined(separator: ", ")
        return "\(titleState) · \(tagState)"
    }

    private var statusText: String {
        guard let result else {
            return photo.needsMetadata ? "Needs metadata" : "Has metadata"
        }

        switch result.status {
        case .pending:
            return "Waiting"
        case .preparing:
            return "Preparing"
        case .suggesting:
            return "Asking LLM"
        case .applying:
            return "Applying"
        case .applied:
            return result.message
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        guard let result else {
            return photo.needsMetadata ? .orange : .secondary
        }

        switch result.status {
        case .applied:
            return .green
        case .failed:
            return .red
        case .pending, .preparing, .suggesting, .applying:
            return .secondary
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
