import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isConfirmingClearPendingImport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionSection
                    pendingImportSection
                    destinationSection
                    uploadProgressSection
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
                    PendingPhotoGrid(items: items)
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

    private var uploadProgressSection: some View {
        GroupBox("Upload Progress") {
            VStack(alignment: .leading, spacing: 12) {
                Button("Upload to Album") {
                    Task { await viewModel.uploadPendingPhotos() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.canUpload == false)

                if viewModel.uploader.isUploading || viewModel.uploader.results.isEmpty == false {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.uploader.results) { result in
                            UploadResultRow(result: result)
                        }

                        if viewModel.uploader.completedSummary.isEmpty == false {
                            Text(viewModel.uploader.completedSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

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

private struct PendingPhotoGrid: View {
    let items: [ImportedPhoto]

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                PendingPhotoThumbnail(item: item)
            }
        }
    }
}

private struct UploadResultRow: View {
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
}

private struct PendingPhotoThumbnail: View {
    let item: ImportedPhoto
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(item.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 112, alignment: .leading)
        }
        .task(id: item.fileURL) {
            image = NSImage(contentsOf: item.fileURL)
        }
    }
}
