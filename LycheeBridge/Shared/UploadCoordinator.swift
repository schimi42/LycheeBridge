import Foundation

@MainActor
final class UploadCoordinator: ObservableObject {
    @Published private(set) var results: [UploadResult] = []
    @Published private(set) var isUploading = false
    @Published private(set) var completedSummary = ""

    func reset() {
        results = []
        isUploading = false
        completedSummary = ""
    }

    func upload(
        bundle: ShareImportBundle,
        albumID: String,
        client: LycheeClient,
        editableMetadata: [UUID: ImportedPhotoEditableMetadata],
        commonTags: [String]
    ) async {
        isUploading = true
        completedSummary = ""
        results = bundle.items.map {
            let metadata = metadataRequest(for: $0, editableMetadata: editableMetadata, commonTags: commonTags)
            return UploadResult(
                id: $0.id,
                itemName: $0.displayName,
                destinationAlbumID: albumID,
                startedAt: Date(),
                completedAt: nil,
                status: .pending,
                titleStatus: metadata.title == nil ? .notRequested : .pending,
                tagStatus: metadata.tags.isEmpty ? .notRequested : .pending,
                serverResponseSummary: nil
            )
        }

        var successCount = 0

        for item in bundle.items {
            updateStatus(for: item.id, status: .uploading, completedAt: nil, response: nil)

            do {
                let remoteID = try await uploadWithRetry(item: item, albumID: albumID, client: client, retries: 2)
                let metadata = metadataRequest(for: item, editableMetadata: editableMetadata, commonTags: commonTags)
                if let remoteID {
                    await applyMetadata(metadata, photoID: remoteID, itemID: item.id, client: client)
                } else {
                    markPendingMetadataSkipped(for: item.id, message: "Lychee did not return a photo id.")
                }
                successCount += 1
                updateStatus(
                    for: item.id,
                    status: .succeeded(remoteID: remoteID),
                    completedAt: Date(),
                    response: remoteID.map { "Uploaded as \($0)" } ?? "Uploaded"
                )
            } catch {
                updateStatus(
                    for: item.id,
                    status: .failed(message: error.localizedDescription),
                    completedAt: Date(),
                    response: error.localizedDescription
                )
            }
        }

        isUploading = false
        let total = bundle.items.count
        completedSummary = successCount == total
            ? "Uploaded all \(total) photos."
            : "Uploaded \(successCount) of \(total) photos."
    }

    private func uploadWithRetry(item: ImportedPhoto, albumID: String, client: LycheeClient, retries: Int) async throws -> String? {
        do {
            return try await client.upload(photo: item, to: albumID)
        } catch let error as LycheeClientError {
            if retries > 0, error.isTransient {
                return try await uploadWithRetry(item: item, albumID: albumID, client: client, retries: retries - 1)
            }
            throw error
        } catch {
            throw error
        }
    }

    private func metadataRequest(
        for item: ImportedPhoto,
        editableMetadata: [UUID: ImportedPhotoEditableMetadata],
        commonTags: [String]
    ) -> (title: String?, tags: [String]) {
        let itemMetadata = editableMetadata[item.id] ?? ImportedPhotoEditableMetadata()
        let tags = ImportedPhotoEditableMetadata.normalizedTags(itemMetadata.normalizedTags + commonTags)
        return (itemMetadata.normalizedTitle, tags)
    }

    private func applyMetadata(
        _ metadata: (title: String?, tags: [String]),
        photoID: String,
        itemID: UUID,
        client: LycheeClient
    ) async {
        if let title = metadata.title {
            updateTitleStatus(for: itemID, status: .applying)
            do {
                try await client.renamePhoto(photoID: photoID, title: title)
                updateTitleStatus(for: itemID, status: .applied)
            } catch {
                updateTitleStatus(for: itemID, status: .failed(message: error.localizedDescription))
            }
        }

        if metadata.tags.isEmpty == false {
            updateTagStatus(for: itemID, status: .applying)
            do {
                try await client.applyTags(photoID: photoID, tags: metadata.tags)
                updateTagStatus(for: itemID, status: .applied)
            } catch {
                updateTagStatus(for: itemID, status: .failed(message: error.localizedDescription))
            }
        }
    }

    private func markPendingMetadataSkipped(for id: UUID, message: String) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        if case .pending = results[index].titleStatus {
            results[index].titleStatus = .skipped(message: message)
        }
        if case .pending = results[index].tagStatus {
            results[index].tagStatus = .skipped(message: message)
        }
    }

    private func updateStatus(for id: UUID, status: UploadResult.Status, completedAt: Date?, response: String?) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].status = status
        results[index].completedAt = completedAt
        results[index].serverResponseSummary = response
    }

    private func updateTitleStatus(for id: UUID, status: MetadataOperationStatus) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].titleStatus = status
    }

    private func updateTagStatus(for id: UUID, status: MetadataOperationStatus) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].tagStatus = status
    }
}

private extension LycheeClientError {
    var isTransient: Bool {
        switch self {
        case .network:
            return true
        case let .httpError(statusCode, _):
            return statusCode >= 500
        default:
            return false
        }
    }
}
