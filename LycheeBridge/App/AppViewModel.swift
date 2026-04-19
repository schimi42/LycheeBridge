import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var configuration: LycheeConfiguration
    @Published var llmConfiguration: LLMConfiguration
    @Published var llmCredentials: LLMCredentials
    @Published var credentials: LycheeCredentials
    @Published var albums: [LycheeAlbum] = []
    @Published var tags: [LycheeTag] = []
    @Published var selectedAlbumID: String = ""
    @Published var pendingBundle: ShareImportBundle?
    @Published var editableMetadata: [UUID: ImportedPhotoEditableMetadata] = [:]
    @Published var commonTags: [String] = []
    @Published var commonTagInput: String = ""
    @Published var connectionMessage: String = "Configure your Lychee server to begin."
    @Published var importMessage: String = "No pending photos."
    @Published var destinationMessage: String = "Load albums to choose a destination."
    @Published var tagMessage: String = "Load tags to inspect Lychee tag suggestions."
    @Published var uploadMessage: String = "Waiting for photos and a destination album."
    @Published var llmMessage: String = "Configure an LLM provider, then request suggestions for pending photos."
    @Published var connectionState: AsyncButtonState = .idle
    @Published var albumState: AsyncButtonState = .idle
    @Published var tagState: AsyncButtonState = .idle
    @Published var uploadState: AsyncButtonState = .idle
    @Published var llmState: AsyncButtonState = .idle
    @Published var debugLog: String = "No debug trace yet."
    @Published var llmDiagnostic: LLMDiagnosticSnapshot?

    let uploader = UploadCoordinator()

    private let configurationStore = LycheeConfigurationStore()
    private let llmConfigurationStore = LLMConfigurationStore()
    private let importStore = SharedImportStore()
    private let llmProviderFactory = LLMProviderFactory()

    init() {
        let loadedLLMConfiguration: LLMConfiguration
        let loadedLLMCredentials: LLMCredentials
        do {
            let loaded = try llmConfigurationStore.load()
            loadedLLMConfiguration = loaded.0
            loadedLLMCredentials = loaded.1
        } catch {
            loadedLLMConfiguration = LLMConfiguration()
            loadedLLMCredentials = LLMCredentials()
            self.llmMessage = error.localizedDescription
        }
        self.llmConfiguration = loadedLLMConfiguration
        self.llmCredentials = loadedLLMCredentials

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

    var canSuggestMetadata: Bool {
        pendingBundle != nil && llmState.isRunning == false
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
            await refreshTags()
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
                setPendingBundle(bundle)
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

    func saveLLMConfiguration() {
        do {
            try llmConfigurationStore.save(configuration: llmConfiguration, credentials: llmCredentials)
            llmMessage = "Saved LLM settings."
            llmState = .succeeded
        } catch {
            llmMessage = error.localizedDescription
            llmState = .failed
        }
    }

    func resetLLMPrompt() {
        llmConfiguration.prompt = LLMConfiguration.defaultPrompt
        saveLLMConfiguration()
    }

    func resetLLMPreferredTags() {
        llmConfiguration.preferredTags = LLMConfiguration.defaultPreferredTags
        saveLLMConfiguration()
    }

    func addLycheeTagsToLLMPreferredTags() {
        let lycheeTagNames = tags.map(\.name)
        llmConfiguration.preferredTags = ImportedPhotoEditableMetadata.normalizedTags(
            llmConfiguration.preferredTags + lycheeTagNames
        )
        saveLLMConfiguration()
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

    func refreshTags() async {
        tagState = .running
        tagMessage = "Loading tags…"

        do {
            let client = makeClient()
            let tags = try await client.fetchTags()
            self.tags = tags
            tagMessage = tags.isEmpty ? "Connected, but no tags are defined yet." : "Loaded \(tags.count) tags."
            tagState = .succeeded
        } catch {
            tagMessage = error.localizedDescription
            tagState = .failed
        }
    }

    func addLocalTagSuggestion(_ name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false,
              tags.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) == false else {
            return
        }

        tags.append(LycheeTag(id: trimmedName, name: trimmedName))
        tags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func suggestMetadata(for item: ImportedPhoto) async {
        guard llmState.isRunning == false else { return }

        llmState = .running
        llmMessage = "Requesting LLM suggestions for \(item.displayName)..."

        do {
            try await suggestMetadataForItem(item)
            llmMessage = "Applied LLM suggestions for \(item.displayName)."
            llmState = .succeeded
        } catch {
            llmMessage = error.localizedDescription
            llmState = .failed
        }
    }

    func suggestMetadataForAllPendingPhotos() async {
        guard llmState.isRunning == false else { return }
        guard let items = pendingBundle?.items, items.isEmpty == false else {
            llmMessage = "No pending photos to suggest metadata for."
            return
        }

        llmState = .running
        llmMessage = "Requesting LLM suggestions for \(items.count) photos..."

        var successCount = 0
        var lastError: Error?

        for item in items {
            do {
                try await suggestMetadataForItem(item)
                successCount += 1
            } catch {
                lastError = error
                break
            }
        }

        if let lastError {
            llmMessage = "Suggested metadata for \(successCount) of \(items.count) photos. \(lastError.localizedDescription)"
            llmState = .failed
        } else {
            llmMessage = "Applied LLM suggestions for \(successCount) photos."
            llmState = .succeeded
        }
    }

    func refreshPendingBundle() async {
        do {
            setPendingBundle(try importStore.latestBundle())
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
            setPendingBundle(nil)
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
        await uploader.upload(
            bundle: pendingBundle,
            albumID: selectedAlbumID,
            client: client,
            editableMetadata: editableMetadata,
            commonTags: commonTags
        )

        let hasUploadFailures = uploader.results.contains {
            if case .failed = $0.status { return true }
            return false
        }
        let hasMetadataFailures = uploader.results.contains {
            if case .failed = $0.titleStatus { return true }
            if case .failed = $0.tagStatus { return true }
            return false
        }

        if hasUploadFailures {
            uploadMessage = uploader.completedSummary
            uploadState = .failed
        } else if hasMetadataFailures {
            uploadMessage = "\(uploader.completedSummary) Some metadata updates failed."
            uploadState = .failed
        } else {
            uploadMessage = uploader.completedSummary
            uploadState = .succeeded
            do {
                try importStore.clear(bundleID: pendingBundle.id)
                setPendingBundle(nil)
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

    private func suggestMetadataForItem(_ item: ImportedPhoto) async throws {
        let image = try LLMImagePreparer.prepare(photo: item, options: llmConfiguration.imageOptions)
        let request = LLMMetadataRequest(photo: item, image: image, configuration: llmConfiguration)
        let provider = try llmProviderFactory.makeProvider(configuration: llmConfiguration, credentials: llmCredentials)
        llmDiagnostic = LLMDiagnosticSnapshot(
            id: UUID(),
            createdAt: Date(),
            photoName: item.displayName,
            preparedImage: image,
            prompt: request.prompt,
            response: "Waiting for LLM response...",
            suggestion: nil
        )

        do {
            let result = try await provider.suggestMetadataWithDiagnostics(for: request)
            applySuggestion(result.suggestion, to: item)
            llmDiagnostic = LLMDiagnosticSnapshot(
                id: UUID(),
                createdAt: Date(),
                photoName: item.displayName,
                preparedImage: image,
                prompt: request.prompt,
                response: result.rawResponse,
                suggestion: result.suggestion
            )
        } catch {
            llmDiagnostic = LLMDiagnosticSnapshot(
                id: UUID(),
                createdAt: Date(),
                photoName: item.displayName,
                preparedImage: image,
                prompt: request.prompt,
                response: error.localizedDescription,
                suggestion: nil
            )
            throw error
        }
    }

    private func applySuggestion(_ suggestion: LLMMetadataSuggestion, to item: ImportedPhoto) {
        var metadata = editableMetadata[item.id] ?? ImportedPhotoEditableMetadata()

        if llmConfiguration.shouldSuggestTitle,
           let title = suggestion.normalizedTitle {
            metadata.manualTitle = title
        }

        if llmConfiguration.shouldSuggestTags {
            let suggestedTags = suggestion.normalizedTags
            metadata.manualTags = ImportedPhotoEditableMetadata.normalizedTags(metadata.manualTags + suggestedTags)
            suggestedTags.forEach(addLocalTagSuggestion)
        }

        editableMetadata[item.id] = metadata
    }

    private func setPendingBundle(_ bundle: ShareImportBundle?) {
        pendingBundle = bundle

        guard let bundle else {
            editableMetadata = [:]
            commonTags = []
            commonTagInput = ""
            return
        }

        let validIDs = Set(bundle.items.map(\.id))
        var nextMetadata = editableMetadata.filter { validIDs.contains($0.key) }

        for item in bundle.items where nextMetadata[item.id] == nil {
            nextMetadata[item.id] = ImportedPhotoEditableMetadata(
                manualTitle: item.metadata?.title ?? "",
                manualTags: item.metadata?.tags ?? []
            )
        }

        editableMetadata = nextMetadata
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
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
