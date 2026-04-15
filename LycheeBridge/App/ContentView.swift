import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    configurationCard
                    importCard
                    uploadCard
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
        .frame(minWidth: 760, minHeight: 640)
    }

    private var configurationCard: some View {
        GroupBox("Lychee Connection") {
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
            }
        }
    }

    private var importCard: some View {
        GroupBox("Incoming Photos") {
            VStack(alignment: .leading, spacing: 12) {
                Label(viewModel.pendingBundle?.photoCountDescription ?? "No pending photos", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)

                Text("Configured server: \(viewModel.configuredServerLabel)")
                    .foregroundStyle(.secondary)

                if let items = viewModel.pendingBundle?.items, items.isEmpty == false {
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
                            Text("And \(items.count - 8) more…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button("Refresh Pending Import") {
                    Task { await viewModel.refreshPendingBundle() }
                }
            }
        }
    }

    private var uploadCard: some View {
        GroupBox("Album Upload") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Destination Album", selection: $viewModel.selectedAlbumID) {
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

                Button("Upload Photos") {
                    Task { await viewModel.uploadPendingPhotos() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.canUpload == false)

                if viewModel.uploader.isUploading || viewModel.uploader.results.isEmpty == false {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.uploader.results) { result in
                            HStack {
                                Text(result.itemName)
                                Spacer()
                                Text(statusLabel(for: result.status))
                                    .foregroundStyle(statusColor(for: result.status))
                            }
                        }

                        if viewModel.uploader.completedSummary.isEmpty == false {
                            Text(viewModel.uploader.completedSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ScrollView {
                    Text(viewModel.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 56, maxHeight: 120)
            }
        }
    }

    private var lastConnectionText: String {
        guard let date = viewModel.configuration.lastSuccessfulConnection else {
            return "No successful connection yet"
        }

        return "Last connected \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func statusLabel(for status: UploadResult.Status) -> String {
        switch status {
        case .pending:
            return "Pending"
        case .uploading:
            return "Uploading"
        case let .succeeded(remoteID):
            return remoteID.map { "Uploaded (\($0))" } ?? "Uploaded"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }

    private func statusColor(for status: UploadResult.Status) -> Color {
        switch status {
        case .pending, .uploading:
            return .secondary
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}
