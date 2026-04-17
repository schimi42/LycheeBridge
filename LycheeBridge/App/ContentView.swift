import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingClearPendingImport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionSection
                    pendingImportSection
                    metadataEditingSection
                    destinationSection
                    uploadSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("LycheeBridge")
            .task {
                await viewModel.loadInitialState()
            }
            .onOpenURL { url in
                Task {
                    await viewModel.handleIncomingURL(url)
                }
            }
            .onChange(of: viewModel.selectedAlbumID) { _, _ in
                viewModel.persistSelectedAlbumID()
            }
        }
        .frame(minWidth: 800, minHeight: 680)
    }

    private var connectionSection: some View {
        GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("https://gallery.example.com/", text: $viewModel.configuration.serverURLString)
                    .textFieldStyle(.roundedBorder)

                TextField("Username", text: $viewModel.configuration.username)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password", text: $viewModel.credentials.password)
                    .textFieldStyle(.roundedBorder)

                Toggle("Close the app automatically after a successful upload", isOn: $viewModel.configuration.automaticallyCloseAfterUpload)
                    .toggleStyle(.switch)

                HStack(spacing: 12) {
                    Button("Save Settings") {
                        viewModel.saveConfiguration()
                    }

                    Button("Test Connection") {
                        Task { await viewModel.testConnection() }
                    }
                    .disabled(viewModel.connectionState.isRunning)

                    Text(lastConnectionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                StatusLine(message: viewModel.connectionMessage, state: viewModel.connectionState)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pendingImportSection: some View {
        GroupBox("Pending Import") {
            VStack(alignment: .leading, spacing: 12) {
                Label(viewModel.pendingBundle?.photoCountDescription ?? "No pending photos", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)

                Text("Configured server: \(viewModel.configuredServerLabel)")
                    .foregroundStyle(.secondary)

                if let items = viewModel.pendingBundle?.items, items.isEmpty == false {
                    pendingFileList(items: items)
                }

                HStack(spacing: 12) {
                    Button("Refresh Pending Import") {
                        Task { await viewModel.refreshPendingBundle() }
                    }

                    Button("Reveal Imported Files") {
                        viewModel.revealImportedFiles()
                    }
                    .disabled(viewModel.canManagePendingImport == false)

                    Button("Clear Pending Import", role: .destructive) {
                        isConfirmingClearPendingImport = true
                    }
                    .disabled(viewModel.canManagePendingImport == false)

                    StatusLine(message: viewModel.importMessage, state: .idle)
                }
                .confirmationDialog(
                    "Clear the pending import?",
                    isPresented: $isConfirmingClearPendingImport
                ) {
                    Button("Clear Pending Import", role: .destructive) {
                        viewModel.clearPendingImport()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The copied files for this pending import will be removed from the shared container.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var destinationSection: some View {
        GroupBox("Destination") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Destination Album", selection: $viewModel.selectedAlbumID) {
                        if viewModel.selectedAlbumIsMissingFromLoadedAlbums {
                            Text("Saved album selection").tag(viewModel.selectedAlbumID)
                        }

                        if viewModel.albums.isEmpty {
                            Text("No albums loaded").tag("")
                        } else {
                            ForEach(viewModel.albums) { album in
                                Text(album.displayTitle).tag(album.id)
                            }
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Refresh Albums") {
                        Task { await viewModel.refreshAlbums() }
                    }
                    .disabled(viewModel.albumState.isRunning)
                }

                StatusLine(message: viewModel.destinationMessage, state: viewModel.albumState)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadataEditingSection: some View {
        GroupBox("Photo Metadata") {
            VStack(alignment: .leading, spacing: 14) {
                if let items = viewModel.pendingBundle?.items, items.isEmpty == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Common Tags")
                            .font(.headline)
                        EditableTagField(
                            tags: $viewModel.commonTags,
                            input: $viewModel.commonTagInput,
                            availableTags: viewModel.tags,
                            onAddTag: viewModel.addLocalTagSuggestion
                        )
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            PhotoMetadataEditor(
                                item: item,
                                metadata: metadataBinding(for: item),
                                availableTags: viewModel.tags,
                                onAddTag: viewModel.addLocalTagSuggestion
                            )

                            if item.id != items.last?.id {
                                Divider()
                                    .padding(.vertical, 14)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Pending Metadata",
                        systemImage: "tag",
                        description: Text("Share photos to edit titles and tags before upload.")
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var uploadSection: some View {
        GroupBox("Upload") {
            VStack(alignment: .leading, spacing: 12) {
                Button("Upload to Album") {
                    openWindow(id: "uploadProgress")
                    Task { await viewModel.uploadPendingPhotos() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.canUpload == false)

                StatusLine(message: viewModel.uploadMessage, state: viewModel.uploadState)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pendingFileList(items: [ImportedPhoto]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.prefix(8)) { item in
                HStack {
                    Text(item.displayName)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }

            if items.count > 8 {
                Text("And \(items.count - 8) more...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metadataBinding(for item: ImportedPhoto) -> Binding<ImportedPhotoEditableMetadata> {
        Binding {
            viewModel.editableMetadata[item.id] ?? ImportedPhotoEditableMetadata()
        } set: { metadata in
            viewModel.editableMetadata[item.id] = metadata
        }
    }

    private var lastConnectionText: String {
        guard let date = viewModel.configuration.lastSuccessfulConnection else {
            return "No successful connection yet"
        }

        return "Last connected \(date.formatted(date: .abbreviated, time: .shortened))"
    }

}

private struct StatusLine: View {
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

struct TagList: View {
    let tags: [LycheeTag]

    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(tags) { tag in
                Text(tag.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        }
    }
}

private struct PhotoMetadataEditor: View {
    let item: ImportedPhoto
    @Binding var metadata: ImportedPhotoEditableMetadata
    let availableTags: [LycheeTag]
    let onAddTag: (String) -> Void
    @State private var tagInput = ""

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                PhotoThumbnailImage(item: item, size: 128)

                editorFields
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    PhotoThumbnailImage(item: item, size: 92)

                    VStack(alignment: .leading, spacing: 4) {
                        photoTitle
                        fileDetails
                        metadataBadge
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                editorControls
            }
        }
        .padding(.vertical, 2)
    }

    private var editorFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    photoTitle
                    fileDetails
                }

                Spacer()

                metadataBadge
            }

            editorControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $metadata.manualTitle)
                .textFieldStyle(.roundedBorder)

            EditableTagField(
                tags: $metadata.manualTags,
                input: $tagInput,
                availableTags: availableTags,
                onAddTag: onAddTag
            )
        }
    }

    private var photoTitle: some View {
        Text(item.displayName)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var fileDetails: some View {
        Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var metadataBadge: some View {
        if item.metadata?.hasTransferableMetadata == true {
            Text("Prefilled from embedded metadata")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EditableTagField: View {
    @Binding var tags: [String]
    @Binding var input: String
    let availableTags: [LycheeTag]
    let onAddTag: (String) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Add tag", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addInputTag)

                Button("Add") {
                    addInputTag()
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if suggestionTags.isEmpty == false {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestionTags) { tag in
                            Button(tag.name) {
                                addSuggestedTag(tag.name)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            if tags.isEmpty == false {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 6) {
                            Text(tag)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Button {
                                removeTag(tag)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var suggestionTags: [LycheeTag] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return [] }
        let selected = Set(tags.map { $0.lowercased() })

        return availableTags
            .filter { tag in
                tag.name.range(of: query, options: [.caseInsensitive, .anchored]) != nil
                    && selected.contains(tag.name.lowercased()) == false
            }
            .prefix(8)
            .map { $0 }
    }

    private func addInputTag() {
        addTag(input)
        input = ""
    }

    private func addSuggestedTag(_ tag: String) {
        addTag(tag)
        input = ""
    }

    private func addTag(_ tag: String) {
        let normalized = ImportedPhotoEditableMetadata.normalizedTags(tags + [tag])
        tags = normalized
        if let addedTag = normalized.first(where: { $0.caseInsensitiveCompare(tag.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) {
            onAddTag(addedTag)
        }
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }
}

struct UploadResultRow: View {
    let result: UploadResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.itemName)
                    .font(.callout)

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .textSelection(.enabled)

                metadataStatusLines
            }

            Spacer()

            if case .failed = result.status {
                Button("Retry") {}
                    .disabled(true)
                    .help("Retry support will be added in a later step.")
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch result.status {
        case .pending:
            return "circle"
        case .uploading:
            return "arrow.up.circle"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }

    private var statusText: String {
        switch result.status {
        case .pending:
            return "Waiting"
        case .uploading:
            return "Uploading"
        case let .succeeded(remoteID):
            return remoteID.map { "Uploaded as \($0)" } ?? "Uploaded"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }

    private var statusColor: Color {
        switch result.status {
        case .pending, .uploading:
            return .secondary
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }

    @ViewBuilder
    private var metadataStatusLines: some View {
        if result.titleStatus != .notRequested {
            Text("Title: \(metadataStatusText(result.titleStatus))")
                .font(.caption)
                .foregroundStyle(metadataStatusColor(result.titleStatus))
                .textSelection(.enabled)
        }

        if result.tagStatus != .notRequested {
            Text("Tags: \(metadataStatusText(result.tagStatus))")
                .font(.caption)
                .foregroundStyle(metadataStatusColor(result.tagStatus))
                .textSelection(.enabled)
        }
    }

    private func metadataStatusText(_ status: MetadataOperationStatus) -> String {
        switch status {
        case .notRequested:
            return "Not requested"
        case .pending:
            return "Waiting"
        case .applying:
            return "Applying"
        case .applied:
            return "Applied"
        case let .skipped(message):
            return "Skipped: \(message)"
        case let .failed(message):
            return "Metadata failed: \(message)"
        }
    }

    private func metadataStatusColor(_ status: MetadataOperationStatus) -> Color {
        switch status {
        case .failed:
            return .red
        case .applied:
            return .green
        case .notRequested, .pending, .applying, .skipped:
            return .secondary
        }
    }
}

private struct PhotoThumbnailImage: View {
    let item: ImportedPhoto
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.fileURL) {
            image = NSImage(contentsOf: item.fileURL)
        }
    }
}
