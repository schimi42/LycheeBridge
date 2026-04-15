import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var configuration: LycheeConfiguration
    @Published var credentials: LycheeCredentials
    @Published var albums: [LycheeAlbum] = []
    @Published var selectedAlbumID: String = ""
    @Published var pendingBundle: ShareImportBundle?
    @Published var connectionMessage: String = "Configure your Lychee server to begin."
    @Published var importMessage: String = "No pending photos."
    @Published var destinationMessage: String = "Load albums to choose a destination."
    @Published var uploadMessage: String = "Waiting for photos and a destination album."
    @Published var connectionState: AsyncButtonState = .idle
    @Published var albumState: AsyncButtonState = .idle
    @Published var uploadState: AsyncButtonState = .idle
    @Published var debugLog: String = "No debug trace yet."

    let uploader = UploadCoordinator()

    private let configurationStore = LycheeConfigurationStore()
    private let importStore = SharedImportStore()

    init() {
        do {
            let loaded = try configurationStore.load()
            self.configuration = loaded.0
            self.credentials = loaded.1
            self.selectedAlbumID = loaded.0.selectedAlbumID
        } catch {
            self.configuration = LycheeConfiguration()
            self.credentials = LycheeCredentials()
            self.connectionMessage = error.localizedDescription
        }
    }

    var canUpload: Bool {
        pendingBundle != nil && selectedAlbumIsValid && uploadState.isRunning == false
    }

    var canManagePendingImport: Bool {
        pendingBundle != nil && uploadState.isRunning == false
    }

    var configuredServerLabel: String {
        configuration.serverURLString.isEmpty ? "Not configured" : configuration.serverURLString
    }

    var selectedAlbumIsValid: Bool {
        albums.contains { $0.id == selectedAlbumID }
    }

    var selectedAlbumIsMissingFromLoadedAlbums: Bool {
        selectedAlbumID.isEmpty == false && selectedAlbumIsValid == false
    }

    func loadInitialState() async {
        await refreshPendingBundle()
        if configuration.serverURLString.isEmpty == false, configuration.username.isEmpty == false {
            await refreshAlbums()
        }
    }

    func handleIncomingURL(_ url: URL) async {
        guard url.scheme == AppGroup.incomingURLScheme else { return }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.host == AppGroup.incomingURLHost,
                  let bundleID = components.queryItems?.first(where: { $0.name == "id" })?.value,
                  let uuid = UUID(uuidString: bundleID) {
            do {
                let bundle = try importStore.bundle(withID: uuid)
                pendingBundle = bundle
                importMessage = "Loaded \(bundle.photoCountDescription) from \(bundle.sourceApplication ?? "Share Extension")."
            } catch {
                importMessage = error.localizedDescription
            }
        } else {
            await refreshPendingBundle()
        }
    }

    func saveConfiguration() {
        do {
            configuration.selectedAlbumID = selectedAlbumID
            try configurationStore.save(configuration: configuration, credentials: credentials)
            connectionMessage = "Saved Lychee connection settings."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func testConnection() async {
        connectionState = .running
        debugLog = "Starting connection test…"

        do {
            let client = makeClient()
            let albums = try await client.testConnection()
            configuration.lastSuccessfulConnection = Date()
            try configurationStore.save(configuration: configuration, credentials: credentials)
            self.albums = albums
            if configuration.selectedAlbumID.isEmpty == false,
               albums.contains(where: { $0.id == configuration.selectedAlbumID }) {
                selectedAlbumID = configuration.selectedAlbumID
            } else if selectedAlbumID.isEmpty || albums.contains(where: { $0.id == selectedAlbumID }) == false {
                selectedAlbumID = albums.first?.id ?? ""
            }
            persistSelectedAlbumID()
            connectionMessage = "Connected to Lychee."
            destinationMessage = albums.isEmpty ? "Connected, but no albums are available." : "Loaded \(albums.count) albums."
            connectionState = .succeeded
        } catch {
            connectionMessage = error.localizedDescription
            connectionState = .failed
        }
    }

    func refreshAlbums() async {
        albumState = .running
        destinationMessage = "Loading albums…"

        do {
            let client = makeClient()
            let albums = try await client.fetchAlbums()
            self.albums = albums
            if configuration.selectedAlbumID.isEmpty == false,
               albums.contains(where: { $0.id == configuration.selectedAlbumID }) {
                selectedAlbumID = configuration.selectedAlbumID
            } else if selectedAlbumID.isEmpty || albums.contains(where: { $0.id == selectedAlbumID }) == false {
                selectedAlbumID = albums.first?.id ?? ""
            }
            persistSelectedAlbumID()
            destinationMessage = albums.isEmpty ? "Connected, but no albums are available." : "Album list refreshed."
            albumState = .succeeded
        } catch {
            destinationMessage = error.localizedDescription
            albumState = .failed
        }
    }

    func refreshPendingBundle() async {
        do {
            pendingBundle = try importStore.latestBundle()
            if let pendingBundle {
                importMessage = "Ready to upload \(pendingBundle.photoCountDescription)."
            } else {
                importMessage = "No pending photos."
            }
        } catch {
            importMessage = error.localizedDescription
        }
    }

    func revealImportedFiles() {
        guard let pendingBundle else {
            importMessage = "No imported files to reveal."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting(pendingBundle.items.map(\.fileURL))
        importMessage = "Opened imported files in Finder."
    }

    func clearPendingImport() {
        guard let pendingBundle else {
            importMessage = "No pending photos to clear."
            return
        }

        do {
            try importStore.clear(bundleID: pendingBundle.id)
            self.pendingBundle = nil
            uploader.reset()
            importMessage = "Cleared pending import."
            uploadMessage = "Waiting for photos and a destination album."
            uploadState = .idle
        } catch {
            importMessage = error.localizedDescription
        }
    }

    func uploadPendingPhotos() async {
        guard let pendingBundle else {
            uploadMessage = "No shared photos are waiting to upload."
            return
        }

        guard selectedAlbumIsValid else {
            uploadMessage = "Choose a destination album before uploading."
            return
        }

        uploadState = .running
        uploadMessage = "Uploading \(pendingBundle.photoCountDescription)…"
        uploader.reset()

        let client = makeClient()
        await uploader.upload(bundle: pendingBundle, albumID: selectedAlbumID, client: client)

        if uploader.results.contains(where: {
            if case .failed = $0.status { return true }
            return false
        }) {
            uploadMessage = uploader.completedSummary
            uploadState = .failed
        } else {
            uploadMessage = uploader.completedSummary
            uploadState = .succeeded
            do {
                try importStore.clear(bundleID: pendingBundle.id)
                self.pendingBundle = nil
                importMessage = "No pending photos."
                scheduleAutomaticTerminationIfNeeded()
            } catch {
                uploadMessage += " Cleanup failed: \(error.localizedDescription)"
            }
        }
    }

    private func makeClient() -> LycheeClient {
        LycheeClient(configuration: configuration, credentials: credentials) { [weak self] trace in
            Task { @MainActor in
                self?.appendDebugTrace(trace)
            }
        }
    }

    func persistSelectedAlbumID() {
        guard configuration.selectedAlbumID != selectedAlbumID else {
            return
        }

        configuration.selectedAlbumID = selectedAlbumID

        do {
            try configurationStore.save(configuration: configuration, credentials: credentials)
        } catch {
            destinationMessage = error.localizedDescription
        }
    }

    private func scheduleAutomaticTerminationIfNeeded() {
        guard configuration.automaticallyCloseAfterUpload else {
            return
        }

        uploadMessage = "\(uploader.completedSummary) Closing LycheeBridge…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func appendDebugTrace(_ trace: LycheeDebugTrace) {
        if debugLog == "No debug trace yet." || debugLog == "Starting connection test…" {
            debugLog = trace.formatted
        } else {
            debugLog += "\n\n--------------------\n\n" + trace.formatted
        }
    }
}

enum AsyncButtonState {
    case idle
    case running
    case succeeded
    case failed

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
