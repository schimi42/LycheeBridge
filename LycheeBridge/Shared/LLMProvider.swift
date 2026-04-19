import Foundation

protocol LLMMetadataProvider {
    func suggestMetadata(for request: LLMMetadataRequest) async throws -> LLMMetadataSuggestion
    func suggestMetadataWithDiagnostics(for request: LLMMetadataRequest) async throws -> LLMProviderResult
}

extension LLMMetadataProvider {
    func suggestMetadata(for request: LLMMetadataRequest) async throws -> LLMMetadataSuggestion {
        try await suggestMetadataWithDiagnostics(for: request).suggestion
    }
}

struct LLMProviderFactory {
    func makeProvider(configuration: LLMConfiguration, credentials: LLMCredentials) throws -> LLMMetadataProvider {
        switch configuration.providerKind {
        case .ollama:
            return try OllamaMetadataProvider(configuration: configuration)
        case .openAI:
            return try OpenAIMetadataProvider(configuration: configuration, credentials: credentials)
        case .openWebUI, .openAICompatible, .gemini:
            throw LLMProviderError.unsupportedProvider
        }
    }
}

struct LLMProviderResult: Hashable {
    let suggestion: LLMMetadataSuggestion
    let rawResponse: String
}

struct OllamaMetadataProvider: LLMMetadataProvider {
    private let configuration: LLMConfiguration
    private let session: URLSession

    init(configuration: LLMConfiguration, session: URLSession = .shared) throws {
        guard configuration.endpointURL != nil else {
            throw LLMProviderError.invalidEndpoint
        }

        guard configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw LLMProviderError.missingModel
        }

        self.configuration = configuration
        self.session = session
    }

    func suggestMetadataWithDiagnostics(for request: LLMMetadataRequest) async throws -> LLMProviderResult {
        let urlRequest = try makeRequest(for: request)
        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode) == false {
            throw LLMProviderError.server(message: "Ollama returned HTTP \(httpResponse.statusCode).")
        }

        return try parseResponse(data)
    }

    private func makeRequest(for request: LLMMetadataRequest) throws -> URLRequest {
        guard let endpointURL = configuration.endpointURL else {
            throw LLMProviderError.invalidEndpoint
        }

        let modelName = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelName.isEmpty == false else {
            throw LLMProviderError.missingModel
        }

        let url = endpointURL.appendingPathComponent("api/generate")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(OllamaGenerateRequest(
            model: modelName,
            prompt: request.prompt,
            stream: false,
            format: "json",
            images: [request.image.base64EncodedString]
        ))

        return urlRequest
    }

    private func parseResponse(_ data: Data) throws -> LLMProviderResult {
        let response = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        let rawSuggestion = response.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawSuggestion.isEmpty == false else {
            throw LLMProviderError.emptyResponse
        }

        let suggestion = try LLMMetadataSuggestionParser.parse(rawSuggestion)
        return LLMProviderResult(suggestion: suggestion, rawResponse: rawSuggestion)
    }
}

struct OpenAIMetadataProvider: LLMMetadataProvider {
    private let configuration: LLMConfiguration
    private let credentials: LLMCredentials
    private let session: URLSession

    init(configuration: LLMConfiguration, credentials: LLMCredentials, session: URLSession = .shared) throws {
        guard configuration.openAIEndpointURL != nil else {
            throw LLMProviderError.invalidEndpoint
        }

        guard configuration.openAIModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw LLMProviderError.missingModel
        }

        guard credentials.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw LLMProviderError.missingAPIKey
        }

        self.configuration = configuration
        self.credentials = credentials
        self.session = session
    }

    func suggestMetadataWithDiagnostics(for request: LLMMetadataRequest) async throws -> LLMProviderResult {
        let urlRequest = try makeRequest(for: request)
        let (data, response) = try await session.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           (200..<300).contains(httpResponse.statusCode) == false {
            throw LLMProviderError.server(message: openAIErrorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        return try parseResponse(data)
    }

    private func makeRequest(for request: LLMMetadataRequest) throws -> URLRequest {
        guard let endpointURL = configuration.openAIEndpointURL else {
            throw LLMProviderError.invalidEndpoint
        }

        let modelName = configuration.openAIModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelName.isEmpty == false else {
            throw LLMProviderError.missingModel
        }

        let apiKey = credentials.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.isEmpty == false else {
            throw LLMProviderError.missingAPIKey
        }

        let url = endpointURL.appendingPathComponent("v1").appendingPathComponent("responses")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(OpenAIResponsesRequest(
            model: modelName,
            input: [
                OpenAIInputMessage(
                    role: "user",
                    content: [
                        .text(request.prompt),
                        .image(request.image.base64DataURLString)
                    ]
                )
            ],
            text: OpenAITextConfiguration.metadataSuggestion()
        ))

        return urlRequest
    }

    private func parseResponse(_ data: Data) throws -> LLMProviderResult {
        let rawSuggestion = try OpenAIResponseTextExtractor.outputText(from: data)
        guard rawSuggestion.isEmpty == false else {
            throw LLMProviderError.emptyResponse
        }

        let suggestion = try LLMMetadataSuggestionParser.parse(rawSuggestion)
        return LLMProviderResult(suggestion: suggestion, rawResponse: rawSuggestion)
    }

    private func openAIErrorMessage(from data: Data, statusCode: Int) -> String {
        let fallback = "OpenAI returned HTTP \(statusCode)."

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }

        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           message.isEmpty == false {
            return "OpenAI returned HTTP \(statusCode): \(message)"
        }

        return fallback
    }
}

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let format: String
    let images: [String]
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
}

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: [OpenAIInputMessage]
    let text: OpenAITextConfiguration
}

private struct OpenAIInputMessage: Encodable {
    let role: String
    let content: [OpenAIContentPart]
}

private enum OpenAIContentPart: Encodable {
    case text(String)
    case image(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
        case detail
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let imageURL):
            try container.encode("input_image", forKey: .type)
            try container.encode(imageURL, forKey: .imageURL)
            try container.encode("low", forKey: .detail)
        }
    }
}

private struct OpenAITextConfiguration: Encodable {
    let format: OpenAITextFormat

    static func metadataSuggestion() -> OpenAITextConfiguration {
        OpenAITextConfiguration(format: OpenAITextFormat(
            type: "json_schema",
            name: "lychee_metadata_suggestion",
            strict: true,
            schema: OpenAIJSONSchema(
                type: "object",
                additionalProperties: false,
                properties: [
                    "title": OpenAIJSONSchema(type: "string"),
                    "tags": OpenAIJSONSchema(type: "array", items: OpenAIJSONSchema(type: "string"))
                ],
                required: ["title", "tags"]
            )
        ))
    }
}

private struct OpenAITextFormat: Encodable {
    let type: String
    let name: String
    let strict: Bool
    let schema: OpenAIJSONSchema
}

private final class OpenAIJSONSchema: Encodable {
    let type: String
    var additionalProperties: Bool?
    var properties: [String: OpenAIJSONSchema]?
    var items: OpenAIJSONSchema?
    var required: [String]?

    init(
        type: String,
        additionalProperties: Bool? = nil,
        properties: [String: OpenAIJSONSchema]? = nil,
        items: OpenAIJSONSchema? = nil,
        required: [String]? = nil
    ) {
        self.type = type
        self.additionalProperties = additionalProperties
        self.properties = properties
        self.items = items
        self.required = required
    }
}

private enum OpenAIResponseTextExtractor {
    static func outputText(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.invalidResponse
        }

        if let outputText = object["output_text"] as? String {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let output = object["output"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse
        }

        let texts = output.flatMap { item -> [String] in
            guard let content = item["content"] as? [[String: Any]] else {
                return []
            }

            return content.compactMap { part in
                guard part["type"] as? String == "output_text" else {
                    return nil
                }
                return part["text"] as? String
            }
        }

        return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum LLMMetadataSuggestionParser {
    static func parse(_ rawSuggestion: String) throws -> LLMMetadataSuggestion {
        let cleaned = rawSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)

        for candidate in [cleaned, codeFenceStripped(cleaned), firstJSONObject(in: cleaned)].compactMap({ $0 }) {
            guard let data = candidate.data(using: .utf8) else {
                continue
            }

            if let suggestion = try? JSONDecoder().decode(LLMMetadataSuggestion.self, from: data) {
                return suggestion
            }
        }

        throw LLMProviderError.invalidResponse
    }

    private static func codeFenceStripped(_ value: String) -> String? {
        guard value.hasPrefix("```") else {
            return nil
        }

        var lines = value.components(separatedBy: .newlines)
        guard lines.isEmpty == false else {
            return nil
        }

        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }

        let stripped = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    private static func firstJSONObject(in value: String) -> String? {
        guard let start = value.firstIndex(of: "{"),
              let end = value.lastIndex(of: "}"),
              start <= end else {
            return nil
        }

        return String(value[start...end])
    }
}
