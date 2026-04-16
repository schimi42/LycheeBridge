import Foundation

struct ImportedPhoto: Codable, Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let originalFilename: String
    let mimeType: String
    let typeIdentifier: String
    let fileSize: Int64
    let fileURL: URL
    let metadata: ImportedPhotoMetadata?
}

struct ImportedPhotoMetadata: Codable, Hashable {
    let title: String?
    let tags: [String]
    let fields: [ImportedPhotoMetadataField]

    var hasTransferableMetadata: Bool {
        title?.isEmpty == false || tags.isEmpty == false
    }
}

struct ImportedPhotoMetadataField: Codable, Hashable, Identifiable {
    var id: String { "\(source).\(name).\(value)" }

    let source: String
    let name: String
    let value: String
}

struct ShareImportBundle: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let sourceApplication: String?
    let items: [ImportedPhoto]

    var photoCountDescription: String {
        let count = items.count
        return count == 1 ? "1 photo" : "\(count) photos"
    }
}

struct LycheeConfiguration: Codable, Hashable {
    var serverURLString: String = ""
    var username: String = ""
    var authMode: AuthMode = .sessionLogin
    var lastSuccessfulConnection: Date?
    var selectedAlbumID: String = ""
    var automaticallyCloseAfterUpload: Bool = false

    enum AuthMode: String, Codable, CaseIterable, Identifiable {
        case sessionLogin

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sessionLogin:
                return "Session Login"
            }
        }
    }

    var serverURL: URL? {
        URL(string: serverURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct LycheeCredentials: Hashable {
    var password: String = ""
}

struct LycheeAlbum: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let parentID: String?
    let path: String?

    var displayTitle: String {
        guard let path, path.isEmpty == false else { return title }
        return path
    }
}

struct UploadResult: Identifiable, Hashable {
    enum Status: Hashable {
        case pending
        case uploading
        case succeeded(remoteID: String?)
        case failed(message: String)
    }

    let id: UUID
    let itemName: String
    let destinationAlbumID: String
    let startedAt: Date
    var completedAt: Date?
    var status: Status
    var serverResponseSummary: String?
}
