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
    @Published var statusMessage: String = "Configure your Lychee server to begin."
    @Published var connectionState: AsyncButtonState = .idle
    @Published var albumState: AsyncButtonState = .idle
    @Published var uploadState: AsyncButtonState = .idle
    @Published var debugLog: String = "No debug trace yet."
    @Published var showDebugLog = true

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
            self.statusMessage = error.localizedDescription
        }
    }

    var canUpload: Bool {
        pendingBundle != nil && selectedAlbumID.isEmpty == false && uploadState.isRunning == false
    }

    var configuredServerLabel: String {
        configuration.serverURLString.isEmpty ? "Not configured" : configuration.serverURLString
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
                statusMessage = "Loaded \(bundle.photoCountDescription) from \(bundle.sourceApplication ?? "Share Extension")."
            } catch {
                statusMessage = error.localizedDescription
            }
        } else {
            await refreshPendingBundle()
        }
    }

    func saveConfiguration() {
        do {
            configuration.selectedAlbumID = selectedAlbumID
            try configurationStore.save(configuration: configuration, credentials: credentials)
            statusMessage = "Saved Lychee connection settings."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func testConnection() async {
        connectionState = .running
        debugLog = "Starting connection test…"

        do {
            let client = makeClient()
            let albums = try await client.testConnection()
            configuration.lastSuccessfulConnection = Date()
            configuration.lastAuthenticatedAt = Date()
            try configurationStore.save(configuration: configuration, credentials: credentials)
            self.albums = albums
            if configuration.selectedAlbumID.isEmpty == false,
               albums.contains(where: { $0.id == configuration.selectedAlbumID }) {
                selectedAlbumID = configuration.selectedAlbumID
            } else if selectedAlbumID.isEmpty || albums.contains(where: { $0.id == selectedAlbumID }) == false {
                selectedAlbumID = albums.first?.id ?? ""
            }
            persistSelectedAlbumID()
            statusMessage = "Connected to Lychee and loaded \(albums.count) albums."
            connectionState = .succeeded
        } catch {
            statusMessage = error.localizedDescription
            connectionState = .failed
        }
    }

    func refreshAlbums() async {
        albumState = .running

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
            statusMessage = albums.isEmpty ? "Connected, but no albums are available." : "Album list refreshed."
            albumState = .succeeded
        } catch {
            statusMessage = error.localizedDescription
            albumState = .failed
        }
    }

    func refreshPendingBundle() async {
        do {
            pendingBundle = try importStore.latestBundle()
            if let pendingBundle {
                statusMessage = "Ready to upload \(pendingBundle.photoCountDescription)."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func uploadPendingPhotos() async {
        guard let pendingBundle else {
            statusMessage = "No shared photos are waiting to upload."
            return
        }

        uploadState = .running
        uploader.reset()

        let client = makeClient()
        await uploader.upload(bundle: pendingBundle, albumID: selectedAlbumID, client: client)

        if uploader.results.contains(where: {
            if case .failed = $0.status { return true }
            return false
        }) {
            statusMessage = uploader.completedSummary
            uploadState = .failed
        } else {
            statusMessage = uploader.completedSummary
            uploadState = .succeeded
            do {
                try importStore.clear(bundleID: pendingBundle.id)
                self.pendingBundle = nil
                scheduleAutomaticTerminationIfNeeded()
            } catch {
                statusMessage += " Cleanup failed: \(error.localizedDescription)"
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
            statusMessage = error.localizedDescription
        }
    }

    private func scheduleAutomaticTerminationIfNeeded() {
        guard configuration.automaticallyCloseAfterUpload else {
            return
        }

        statusMessage = "\(uploader.completedSummary) Closing LycheeBridge…"

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
