import Foundation

enum LLMProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case ollama
    case openWebUI
    case openAICompatible
    case gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama:
            return "Ollama"
        case .openWebUI:
            return "OpenWebUI"
        case .openAICompatible:
            return "OpenAI Compatible"
        case .gemini:
            return "Gemini"
        }
    }
}

struct LLMConfiguration: Codable, Hashable {
    static let defaultPrompt = """
    You help prepare photos for a Lychee photo gallery.
    Suggest a concise title and relevant tags for the image.
    Prefer tags from the provided tag list when they fit.
    Return only JSON with this shape:
    {"title":"Short title","tags":["tag one","tag two"]}
    """

    static let defaultPreferredTags = [
        "Architecture",
        "Beach",
        "City",
        "Family",
        "Flowers",
        "Landscape",
        "Nature",
        "People",
        "Portrait",
        "Travel"
    ]

    var providerKind: LLMProviderKind = .ollama
    var endpointURLString: String = "http://localhost:11434"
    var modelName: String = "llava"
    var prompt: String = Self.defaultPrompt
    var preferredTags: [String] = Self.defaultPreferredTags
    var shouldSuggestTitle: Bool = true
    var shouldSuggestTags: Bool = true
    var imageOptions: LLMImagePreparer.Options = LLMImagePreparer.defaultOptions

    var endpointURL: URL? {
        URL(string: endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var normalizedPreferredTags: [String] {
        ImportedPhotoEditableMetadata.normalizedTags(preferredTags)
    }

    var normalizedPrompt: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultPrompt : trimmed
    }
}

struct LLMMetadataRequest: Hashable {
    let photo: ImportedPhoto
    let image: PreparedLLMImage
    let configuration: LLMConfiguration

    var prompt: String {
        var parts = [
            configuration.normalizedPrompt
        ]

        let preferredTags = configuration.normalizedPreferredTags
        if preferredTags.isEmpty == false {
            parts.append("Preferred tags: \(preferredTags.joined(separator: ", "))")
        }

        parts.append("Suggest title: \(configuration.shouldSuggestTitle ? "yes" : "no")")
        parts.append("Suggest tags: \(configuration.shouldSuggestTags ? "yes" : "no")")

        return parts.joined(separator: "\n\n")
    }
}

struct LLMMetadataSuggestion: Codable, Hashable {
    var title: String?
    var tags: [String]

    var normalizedTitle: String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedTags: [String] {
        ImportedPhotoEditableMetadata.normalizedTags(tags)
    }
}

struct LLMDiagnosticSnapshot: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let photoName: String
    let preparedImage: PreparedLLMImage?
    let prompt: String
    let response: String
    let suggestion: LLMMetadataSuggestion?
}

enum LLMProviderError: LocalizedError {
    case unsupportedProvider
    case invalidEndpoint
    case missingModel
    case emptyResponse
    case invalidResponse
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "This LLM provider is not implemented yet."
        case .invalidEndpoint:
            return "The LLM endpoint URL is invalid."
        case .missingModel:
            return "Choose an LLM model before requesting suggestions."
        case .emptyResponse:
            return "The LLM returned an empty response."
        case .invalidResponse:
            return "The LLM response could not be parsed."
        case .server(let message):
            return message
        }
    }
}
