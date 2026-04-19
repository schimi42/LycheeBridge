import Foundation

enum LLMProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case ollama
    case openAI
    case openWebUI
    case openAICompatible
    case gemini

    static let selectableCases: [LLMProviderKind] = [.ollama, .openAI]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ollama:
            return "Ollama"
        case .openAI:
            return "OpenAI"
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
    var openAIEndpointURLString: String = "https://api.openai.com"
    var openAIModelName: String = "gpt-4.1-mini"
    var prompt: String = Self.defaultPrompt
    var preferredTags: [String] = Self.defaultPreferredTags
    var shouldSuggestTitle: Bool = true
    var shouldSuggestTags: Bool = true
    var imageOptions: LLMImagePreparer.Options = LLMImagePreparer.defaultOptions

    var endpointURL: URL? {
        URL(string: endpointURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var openAIEndpointURL: URL? {
        URL(string: openAIEndpointURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var normalizedPreferredTags: [String] {
        ImportedPhotoEditableMetadata.normalizedTags(preferredTags)
    }

    var normalizedPrompt: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultPrompt : trimmed
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case providerKind
        case endpointURLString
        case modelName
        case openAIEndpointURLString
        case openAIModelName
        case prompt
        case preferredTags
        case shouldSuggestTitle
        case shouldSuggestTags
        case imageOptions
    }

    init(from decoder: Decoder) throws {
        let defaults = LLMConfiguration()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        providerKind = try container.decodeIfPresent(LLMProviderKind.self, forKey: .providerKind) ?? defaults.providerKind
        endpointURLString = try container.decodeIfPresent(String.self, forKey: .endpointURLString) ?? defaults.endpointURLString
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? defaults.modelName
        openAIEndpointURLString = try container.decodeIfPresent(String.self, forKey: .openAIEndpointURLString) ?? defaults.openAIEndpointURLString
        openAIModelName = try container.decodeIfPresent(String.self, forKey: .openAIModelName) ?? defaults.openAIModelName
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? defaults.prompt
        preferredTags = try container.decodeIfPresent([String].self, forKey: .preferredTags) ?? defaults.preferredTags
        shouldSuggestTitle = try container.decodeIfPresent(Bool.self, forKey: .shouldSuggestTitle) ?? defaults.shouldSuggestTitle
        shouldSuggestTags = try container.decodeIfPresent(Bool.self, forKey: .shouldSuggestTags) ?? defaults.shouldSuggestTags
        imageOptions = try container.decodeIfPresent(LLMImagePreparer.Options.self, forKey: .imageOptions) ?? defaults.imageOptions
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerKind, forKey: .providerKind)
        try container.encode(endpointURLString, forKey: .endpointURLString)
        try container.encode(modelName, forKey: .modelName)
        try container.encode(openAIEndpointURLString, forKey: .openAIEndpointURLString)
        try container.encode(openAIModelName, forKey: .openAIModelName)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(preferredTags, forKey: .preferredTags)
        try container.encode(shouldSuggestTitle, forKey: .shouldSuggestTitle)
        try container.encode(shouldSuggestTags, forKey: .shouldSuggestTags)
        try container.encode(imageOptions, forKey: .imageOptions)
    }
}

struct LLMCredentials: Hashable {
    var openAIAPIKey: String = ""
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
    case missingAPIKey
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
        case .missingAPIKey:
            return "Enter an OpenAI API key before requesting suggestions."
        case .emptyResponse:
            return "The LLM returned an empty response."
        case .invalidResponse:
            return "The LLM response could not be parsed."
        case .server(let message):
            return message
        }
    }
}
