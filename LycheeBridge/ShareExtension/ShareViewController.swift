import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    private var statusModel = ShareImportStatusModel()
    private var didStartImport = false
    private let importStore = SharedImportStore()

    override func loadView() {
        let rootView = ShareImportStatusView(model: statusModel)
        view = NSHostingView(rootView: rootView)
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard didStartImport == false else { return }
        didStartImport = true

        Task {
            await importAttachments()
        }
    }

    @MainActor
    private func importAttachments() async {
        statusModel.message = "Preparing photos from Apple Photos…"

        do {
            let files = try await collectPendingFiles()
            statusModel.message = "Imported \(files.count == 1 ? "1 photo" : "\(files.count) photos"). Opening LycheeBridge…"
            let bundle = try importStore.createBundle(items: files, sourceApplication: "Finder")
            try openHostApp(bundleID: bundle.id)
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        } catch {
            statusModel.message = error.localizedDescription
        }
    }

    private func collectPendingFiles() async throws -> [PendingImportedFile] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            throw SharedStoreError.unsupportedItemProvider
        }

        var pendingFiles: [PendingImportedFile] = []

        for item in items {
            for provider in item.attachments ?? [] {
                if let imported = try await importFile(from: provider) {
                    pendingFiles.append(imported)
                }
            }
        }

        guard pendingFiles.isEmpty == false else {
            throw SharedStoreError.unsupportedItemProvider
        }

        return pendingFiles
    }

    @MainActor
    private func importFile(from provider: NSItemProvider) async throws -> PendingImportedFile? {
        let supportedTypes = [
            UTType.image.identifier,
            UTType.jpeg.identifier,
            UTType.png.identifier,
            UTType.heic.identifier,
            UTType.tiff.identifier
        ]

        guard let typeIdentifier = supportedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) ??
                provider.registeredTypeIdentifiers.first else {
            return nil
        }

        if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            let type = UTType(typeIdentifier) ?? .image
            let originalSourceURL = try? await provider.loadOriginalFileURL()
            let importedURL = try await provider.loadBridgeFileRepresentation(
                forTypeIdentifier: typeIdentifier,
                preferredSourceURL: originalSourceURL
            )
            let originalFilename = preferredFilename(
                for: provider,
                originalSourceURL: originalSourceURL,
                importedURL: importedURL,
                type: type
            )
            return PendingImportedFile(
                sourceURL: importedURL,
                displayName: originalFilename,
                originalFilename: originalFilename,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                typeIdentifier: typeIdentifier
            )
        }

        return nil
    }

    private func preferredFilename(for provider: NSItemProvider, originalSourceURL: URL?, importedURL: URL, type: UTType) -> String {
        if let originalSourceURL {
            let originalName = originalSourceURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            if originalName.isEmpty == false,
               originalName.hasPrefix(".com.apple.Foundation.NSItemProvider.") == false {
                return originalName
            }
        }

        let fallback = importedURL.lastPathComponent

        guard let suggestedName = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              suggestedName.isEmpty == false,
              suggestedName.hasPrefix(".com.apple.Foundation.NSItemProvider.") == false else {
            return fallback
        }

        if URL(fileURLWithPath: suggestedName).pathExtension.isEmpty == false {
            return suggestedName
        }

        let ext = importedURL.pathExtension.isEmpty == false
            ? importedURL.pathExtension
            : (type.preferredFilenameExtension ?? "")

        guard ext.isEmpty == false else {
            return suggestedName
        }

        return "\(suggestedName).\(ext)"
    }

    private func openHostApp(bundleID: UUID) throws {
        var components = URLComponents()
        components.scheme = AppGroup.incomingURLScheme
        components.host = AppGroup.incomingURLHost
        components.queryItems = [
            URLQueryItem(name: "id", value: bundleID.uuidString)
        ]

        guard let url = components.url else {
            throw ShareImportError.invalidOpenURL
        }

        let opened = NSWorkspace.shared.open(url)
        guard opened else {
            throw ShareImportError.openHostApplicationFailed
        }
    }
}

private enum ShareImportError: LocalizedError {
    case invalidOpenURL
    case openHostApplicationFailed

    var errorDescription: String? {
        switch self {
        case .invalidOpenURL:
            return "Could not prepare the handoff URL for LycheeBridge."
        case .openHostApplicationFailed:
            return "The share extension could not launch LycheeBridge."
        }
    }
}

@MainActor
private extension NSItemProvider {
    func loadOriginalFileURL() async throws -> URL? {
        let fileURLType = UTType.fileURL.identifier
        guard hasItemConformingToTypeIdentifier(fileURLType) else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            _ = self.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }

                if let string = item as? String,
                   let url = URL(string: string) {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    func loadBridgeFileRepresentation(forTypeIdentifier typeIdentifier: String, preferredSourceURL: URL?) async throws -> URL {
        if let preferredSourceURL {
            return preferredSourceURL
        }

        return try await loadBridgeCopiedFileRepresentation(forTypeIdentifier: typeIdentifier)
    }

    private func loadBridgeCopiedFileRepresentation(forTypeIdentifier typeIdentifier: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = self.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url else {
                    continuation.resume(throwing: SharedStoreError.unsupportedItemProvider)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}

@MainActor
final class ShareImportStatusModel: ObservableObject {
    @Published var message = "Waiting for shared photos…"
}

struct ShareImportStatusView: View {
    @ObservedObject var model: ShareImportStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LycheeBridge")
                .font(.title2.bold())

            Text(model.message)
                .foregroundStyle(.secondary)

            ProgressView()
                .controlSize(.large)
        }
        .padding(24)
        .frame(width: 420, height: 180, alignment: .topLeading)
    }
}
