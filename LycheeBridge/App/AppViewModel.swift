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
    @Published var existingPhotoAlbumID: String = ""
    @Published var existingPhotoFilter: ExistingPhotoMetadataFilter = .missingTitleOrTags
    @Published var existingPhotoOverwriteExistingTitles = false
    @Published var existingPhotoTitleOverwriteOverrides: [String: Bool] = [:]
    @Published var existingPhotos: [LycheePhoto] = []
    @Published var existingPhotoResults: [ExistingPhotoMetadataResult] = []
    @Published var pendingBundle: ShareImportBundle?
    @Published var editableMetadata: [UUID: ImportedPhotoEditableMetadata] = [:]
    @Published var commonTags: [String] = []
    @Published var commonTagInput: String = ""
    @Published var connectionMessage: String = "Configure your Lychee server to begin."
    @Published var importMessage: String = "No pending photos."
    @Published var destinationMessage: String = "Load albums to choose a destination."
    @Published var tagMessage: String = "Load tags to inspect Lychee tag suggestions."
    @Published var uploadMessage: String = "Waiting for photos and a destination album."
    @Published var existingPhotoMessage: String = "Choose an album to scan existing photos."
    @Published var llmMessage: String = "Configure an LLM provider, then request suggestions for pending photos."
    @Published var connectionState: AsyncButtonState = .idle
    @Published var albumState: AsyncButtonState = .idle
    @Published var tagState: AsyncButtonState = .idle
    @Published var uploadState: AsyncButtonState = .idle
    @Published var existingPhotoState: AsyncButtonState = .idle
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
            self.existingPhotoAlbumID = loaded.0.selectedAlbumID
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

    var filteredExistingPhotos: [LycheePhoto] {
        switch existingPhotoFilter {
        case .missingTitleOrTags:
            return existingPhotos.filter(\.needsMetadata)
        case .all:
            return existingPhotos
        }
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

    func prepareExistingPhotoMetadataWindow() {
        if existingPhotoAlbumID.isEmpty {
            existingPhotoAlbumID = selectedAlbumID
        }
    }

    func existingPhotoShouldOverwriteTitle(for photo: LycheePhoto) -> Bool {
        existingPhotoTitleOverwriteOverrides[photo.id] ?? existingPhotoOverwriteExistingTitles
    }

    func existingPhotoShouldApplyTitle(for photo: LycheePhoto) -> Bool {
        photo.hasMeaningfulTitle == false || existingPhotoShouldOverwriteTitle(for: photo)
    }

    func setExistingPhotoTitleOverwrite(_ shouldOverwrite: Bool, for photoID: String) {
        existingPhotoTitleOverwriteOverrides[photoID] = shouldOverwrite
    }

    func loadExistingPhotosForMetadata() async {
        guard existingPhotoState.isRunning == false else { return }
        guard albums.contains(where: { $0.id == existingPhotoAlbumID }) else {
            existingPhotoMessage = "Choose an album before loading photos."
            existingPhotoState = .failed
            return
        }

        existingPhotoState = .running
        existingPhotoMessage = "Loading album photos..."
        existingPhotoResults = []
        existingPhotoTitleOverwriteOverrides = [:]

        do {
            let photos = try await makeClient().fetchPhotos(albumID: existingPhotoAlbumID)
            existingPhotos = photos
            let targetCount = filteredExistingPhotos.count
            existingPhotoMessage = photos.isEmpty
                ? "No photos found in this album."
                : "Loaded \(photos.count) photos. \(targetCount) match the current filter."
            existingPhotoState = .succeeded
        } catch {
            existingPhotoMessage = error.localizedDescription
            existingPhotoState = .failed
        }
    }

    func suggestMetadataForExistingPhotos() async {
        guard existingPhotoState.isRunning == false else { return }
        let targetPhotos = filteredExistingPhotos
        guard targetPhotos.isEmpty == false else {
            existingPhotoMessage = "No photos match the current filter."
            return
        }

        existingPhotoState = .running
        existingPhotoMessage = "Requesting LLM suggestions for \(targetPhotos.count) existing photos..."
        existingPhotoResults = targetPhotos.map {
            ExistingPhotoMetadataResult(id: $0.id, photo: $0, status: .pending, suggestion: nil, message: "Waiting")
        }

        let client = makeClient()
        var successCount = 0
        var lastError: Error?

        for photo in targetPhotos {
            updateExistingPhotoResult(photoID: photo.id, status: .preparing, message: "Preparing preview")

            do {
                let shouldApplyTitle = existingPhotoShouldApplyTitle(for: photo)
                let suggestion = try await suggestMetadataForExistingPhoto(photo, client: client, shouldApplyTitle: shouldApplyTitle)
                successCount += 1
                let titleMessage: String
                if shouldApplyTitle {
                    titleMessage = suggestion.normalizedTitle == nil ? "rename skipped: no title suggested" : "rename requested"
                } else {
                    titleMessage = "rename skipped: existing title kept"
                }
                updateExistingPhotoResult(photoID: photo.id, status: .applied, suggestion: suggestion, message: "Applied, \(titleMessage)")
            } catch {
                lastError = error
                updateExistingPhotoResult(photoID: photo.id, status: .failed(message: error.localizedDescription), message: error.localizedDescription)
                break
            }
        }

        if let lastError {
            existingPhotoMessage = "Updated \(successCount) of \(targetPhotos.count) photos. \(lastError.localizedDescription)"
            existingPhotoState = .failed
        } else {
            existingPhotoMessage = "Updated metadata for \(successCount) photos."
            existingPhotoState = .succeeded
        }
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

    private func suggestMetadataForExistingPhoto(
        _ photo: LycheePhoto,
        client: LycheeClient,
        shouldApplyTitle: Bool
    ) async throws -> LLMMetadataSuggestion {
        let previewData = try await client.downloadPreview(for: photo)
        let image = try LLMImagePreparer.prepare(sourcePhotoID: UUID(), data: previewData, options: llmConfiguration.imageOptions)
        var requestConfiguration = llmConfiguration
        requestConfiguration.shouldSuggestTitle = shouldApplyTitle
        var additionalContext = [
            "Current Lychee title: \(photo.title.isEmpty ? "None" : photo.title)",
            "Current Lychee tags: \(photo.normalizedTags.isEmpty ? "None" : photo.normalizedTags.joined(separator: ", "))"
        ]
        if shouldApplyTitle {
            additionalContext.append("A title will be applied to this Lychee photo. Return a non-empty title value.")
        } else {
            additionalContext.append("The current Lychee title will be kept. Return an empty title value.")
        }
        let request = LLMMetadataRequest(
            photoName: photo.displayTitle,
            image: image,
            configuration: requestConfiguration,
            additionalContext: additionalContext
        )
        let provider = try llmProviderFactory.makeProvider(configuration: llmConfiguration, credentials: llmCredentials)

        llmDiagnostic = LLMDiagnosticSnapshot(
            id: UUID(),
            createdAt: Date(),
            photoName: photo.displayTitle,
            preparedImage: image,
            prompt: request.prompt,
            response: "Waiting for LLM response...",
            suggestion: nil
        )

        updateExistingPhotoResult(photoID: photo.id, status: .suggesting, message: "Requesting suggestion")
        let result = try await provider.suggestMetadataWithDiagnostics(for: request)

        llmDiagnostic = LLMDiagnosticSnapshot(
            id: UUID(),
            createdAt: Date(),
            photoName: photo.displayTitle,
            preparedImage: image,
            prompt: request.prompt,
            response: result.rawResponse,
            suggestion: result.suggestion
        )

        updateExistingPhotoResult(photoID: photo.id, status: .applying, suggestion: result.suggestion, message: "Applying metadata")
        appendExistingPhotoTitleDecisionTrace(
            photo: photo,
            shouldApplyTitle: shouldApplyTitle,
            suggestedTitle: result.suggestion.normalizedTitle
        )

        if shouldApplyTitle {
            if let title = result.suggestion.normalizedTitle {
                try await client.renamePhoto(photoID: photo.id, title: title)
            } else {
                updateExistingPhotoResult(
                    photoID: photo.id,
                    status: .applying,
                    suggestion: result.suggestion,
                    message: "Applying metadata, no title suggested"
                )
            }
        }

        if llmConfiguration.shouldSuggestTags {
            let suggestedTags = result.suggestion.normalizedTags
            if suggestedTags.isEmpty == false {
                try await client.applyTags(photoID: photo.id, tags: suggestedTags)
                suggestedTags.forEach(addLocalTagSuggestion)
            }
        }

        applyExistingPhotoSuggestion(result.suggestion, toPhotoID: photo.id, shouldApplyTitle: shouldApplyTitle)
        return result.suggestion
    }

    private func updateExistingPhotoResult(
        photoID: String,
        status: ExistingPhotoMetadataResult.Status,
        suggestion: LLMMetadataSuggestion? = nil,
        message: String
    ) {
        guard let index = existingPhotoResults.firstIndex(where: { $0.id == photoID }) else {
            return
        }

        existingPhotoResults[index].status = status
        if let suggestion {
            existingPhotoResults[index].suggestion = suggestion
        }
        existingPhotoResults[index].message = message
    }

    private func applyExistingPhotoSuggestion(
        _ suggestion: LLMMetadataSuggestion,
        toPhotoID photoID: String,
        shouldApplyTitle: Bool
    ) {
        guard let index = existingPhotos.firstIndex(where: { $0.id == photoID }) else {
            return
        }

        let current = existingPhotos[index]
        existingPhotos[index] = LycheePhoto(
            id: current.id,
            albumID: current.albumID,
            title: shouldApplyTitle ? (suggestion.normalizedTitle ?? current.title) : current.title,
            tags: ImportedPhotoEditableMetadata.normalizedTags(current.tags + suggestion.normalizedTags),
            type: current.type,
            thumbURLString: current.thumbURLString,
            smallURLString: current.smallURLString,
            mediumURLString: current.mediumURLString,
            originalURLString: current.originalURLString
        )
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

    private func appendExistingPhotoTitleDecisionTrace(
        photo: LycheePhoto,
        shouldApplyTitle: Bool,
        suggestedTitle: String?
    ) {
        let reason: String
        if shouldApplyTitle == false {
            reason = "Skipped because the photo has a meaningful title and title replacement is disabled."
        } else if suggestedTitle == nil {
            reason = "Skipped because the LLM response did not contain a non-empty title."
        } else {
            reason = "Will call Photo::rename."
        }

        appendDebugTrace(LycheeDebugTrace(
            stage: "Photo::rename decision",
            requestURL: configuration.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines),
            method: "INTERNAL",
            requestHeaders: [:],
            requestBody: """
            {
              "photo_id" : "\(photo.id)",
              "current_title" : "\(photo.title)",
              "has_meaningful_title" : \(photo.hasMeaningfulTitle),
              "should_apply_title" : \(shouldApplyTitle),
              "suggested_title" : "\(suggestedTitle ?? "")"
            }
            """,
            responseStatus: nil,
            responseHeaders: [:],
            responseBody: reason,
            cookieDump: "Not a network request"
        ))
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
