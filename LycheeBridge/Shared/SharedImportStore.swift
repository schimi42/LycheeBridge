import Foundation

struct SharedImportStore {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func createBundle(items: [PendingImportedFile], sourceApplication: String?) throws -> ShareImportBundle {
        let bundleID = UUID()
        let bundleDirectory = try bundleDirectoryURL(for: bundleID)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        let importedItems = try items.map { item -> ImportedPhoto in
            let destinationName = uniqueFilename(from: item.originalFilename, in: bundleDirectory)
            let destinationURL = bundleDirectory.appendingPathComponent(destinationName, isDirectory: false)
            try copyItemToSharedBundle(from: item.sourceURL, to: destinationURL)

            let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let fileSize = attributes[.size] as? NSNumber

            return ImportedPhoto(
                id: UUID(),
                displayName: item.displayName,
                originalFilename: item.originalFilename,
                mimeType: item.mimeType,
                typeIdentifier: item.typeIdentifier,
                fileSize: fileSize?.int64Value ?? 0,
                fileURL: destinationURL
            )
        }

        let bundle = ShareImportBundle(id: bundleID, createdAt: Date(), sourceApplication: sourceApplication, items: importedItems)
        try save(bundle: bundle)
        return bundle
    }

    func save(bundle: ShareImportBundle) throws {
        let manifestURL = try manifestURL(for: bundle.id)
        let data = try encoder.encode(bundle)
        try data.write(to: manifestURL, options: .atomic)
        try saveLatestBundleID(bundle.id)
    }

    func latestBundle() throws -> ShareImportBundle? {
        let latestBundleURL = try latestBundlePointerURL()
        guard FileManager.default.fileExists(atPath: latestBundleURL.path) else {
            return nil
        }

        let rawID = try String(contentsOf: latestBundleURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawID.isEmpty == false,
              let bundleID = UUID(uuidString: rawID) else {
            return nil
        }

        return try bundle(withID: bundleID)
    }

    func bundle(withID id: UUID) throws -> ShareImportBundle {
        let manifestURL = try manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SharedStoreError.bundleNotFound
        }

        let data = try Data(contentsOf: manifestURL)
        return try decoder.decode(ShareImportBundle.self, from: data)
    }

    func clear(bundleID: UUID) throws {
        let bundleDirectory = try bundleDirectoryURL(for: bundleID)
        if FileManager.default.fileExists(atPath: bundleDirectory.path) {
            try FileManager.default.removeItem(at: bundleDirectory)
        }

        let latestBundleURL = try latestBundlePointerURL()
        if FileManager.default.fileExists(atPath: latestBundleURL.path) {
            let rawID = try String(contentsOf: latestBundleURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawID == bundleID.uuidString {
                try FileManager.default.removeItem(at: latestBundleURL)
            }
        }
    }

    private func saveLatestBundleID(_ bundleID: UUID) throws {
        try bundleID.uuidString.write(to: latestBundlePointerURL(), atomically: true, encoding: .utf8)
    }

    private func bundleDirectoryURL(for bundleID: UUID) throws -> URL {
        try SharedPaths.importsRootURL().appendingPathComponent(bundleID.uuidString, isDirectory: true)
    }

    private func manifestURL(for bundleID: UUID) throws -> URL {
        try bundleDirectoryURL(for: bundleID).appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func latestBundlePointerURL() throws -> URL {
        try SharedPaths.containerURL().appendingPathComponent("latestBundleID.txt", isDirectory: false)
    }

    private func uniqueFilename(from original: String, in directory: URL) -> String {
        let ext = URL(fileURLWithPath: original).pathExtension
        let base = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        var counter = 0

        while true {
            let suffix = counter == 0 ? "" : "-\(counter)"
            let candidate = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) == false {
                return candidate
            }
            counter += 1
        }
    }

    private func copyItemToSharedBundle(from sourceURL: URL, to destinationURL: URL) throws {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}

struct PendingImportedFile {
    let sourceURL: URL
    let displayName: String
    let originalFilename: String
    let mimeType: String
    let typeIdentifier: String
}
