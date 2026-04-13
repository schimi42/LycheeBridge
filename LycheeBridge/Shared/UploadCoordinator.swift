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

    func upload(bundle: ShareImportBundle, albumID: String, client: LycheeClient) async {
        isUploading = true
        completedSummary = ""
        results = bundle.items.map {
            UploadResult(
                id: $0.id,
                itemName: $0.displayName,
                destinationAlbumID: albumID,
                startedAt: Date(),
                completedAt: nil,
                status: .pending,
                serverResponseSummary: nil
            )
        }

        var successCount = 0

        for item in bundle.items {
            updateStatus(for: item.id, status: .uploading, completedAt: nil, response: nil)

            do {
                let remoteID = try await uploadWithRetry(item: item, albumID: albumID, client: client, retries: 2)
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

    private func updateStatus(for id: UUID, status: UploadResult.Status, completedAt: Date?, response: String?) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].status = status
        results[index].completedAt = completedAt
        results[index].serverResponseSummary = response
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
