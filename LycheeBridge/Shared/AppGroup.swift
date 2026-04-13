import Foundation

enum AppGroup {
    static let identifier = "group.de.lumirio.LycheeBridge"
    static let incomingURLScheme = "lycheebridge"
    static let incomingURLHost = "import"
    static let importsDirectoryName = "IncomingBundles"
    static let configurationDomain = "LycheeConfiguration"
}

enum SharedPaths {
    static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else {
            throw SharedStoreError.missingSharedContainer
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func importsRootURL() throws -> URL {
        let root = try containerURL().appendingPathComponent(AppGroup.importsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

enum SharedStoreError: LocalizedError {
    case missingSharedContainer
    case bundleNotFound
    case invalidManifest
    case unsupportedItemProvider

    var errorDescription: String? {
        switch self {
        case .missingSharedContainer:
            return "The shared storage directory could not be located."
        case .bundleNotFound:
            return "The imported photo bundle could not be found."
        case .invalidManifest:
            return "The shared import manifest is invalid."
        case .unsupportedItemProvider:
            return "The shared item provider did not contain a supported image representation."
        }
    }
}
