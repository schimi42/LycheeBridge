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

struct ImportedPhotoEditableMetadata: Codable, Hashable {
    var manualTitle: String = ""
    var manualTags: [String] = []

    var normalizedTitle: String? {
        let trimmed = manualTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedTags: [String] {
        Self.normalizedTags(manualTags)
    }

    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }

            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }

        return result
    }
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

struct LycheeTag: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct LycheePhoto: Identifiable, Hashable {
    let id: String
    let albumID: String
    let title: String
    let tags: [String]
    let type: String
    let thumbURLString: String?
    let smallURLString: String?
    let mediumURLString: String?
    let originalURLString: String?

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }

    var normalizedTags: [String] {
        ImportedPhotoEditableMetadata.normalizedTags(tags)
    }

    var hasTitle: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var hasMeaningfulTitle: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return false
        }

        return Self.filenameLikeTitlePattern.firstMatch(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed)
        ) == nil
    }

    var needsMetadata: Bool {
        hasMeaningfulTitle == false || normalizedTags.isEmpty
    }

    var llmPreviewURL: URL? {
        [mediumURLString, smallURLString, thumbURLString, originalURLString]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false }
            .flatMap(URL.init(string:))
    }

    private static let filenameLikeTitlePattern = try! NSRegularExpression(
        pattern: #"(?i)\.(jpe?g|heic|png|gif|tiff?|webp|mov|mp4)$"#
    )
}

enum ExistingPhotoMetadataFilter: String, CaseIterable, Identifiable, Hashable {
    case missingTitleOrTags
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missingTitleOrTags:
            return "Missing title or tags"
        case .all:
            return "All photos"
        }
    }
}

struct ExistingPhotoMetadataResult: Identifiable, Hashable {
    enum Status: Hashable {
        case pending
        case preparing
        case suggesting
        case applying
        case applied
        case failed(message: String)
    }

    let id: String
    let photo: LycheePhoto
    var status: Status
    var suggestion: LLMMetadataSuggestion?
    var message: String
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
    var titleStatus: MetadataOperationStatus
    var tagStatus: MetadataOperationStatus
    var serverResponseSummary: String?
}

enum MetadataOperationStatus: Hashable {
    case notRequested
    case pending
    case applying
    case applied
    case skipped(message: String)
    case failed(message: String)
}
