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
    func makeProvider(configuration: LLMConfiguration) throws -> LLMMetadataProvider {
        switch configuration.providerKind {
        case .ollama:
            return try OllamaMetadataProvider(configuration: configuration)
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

        guard let suggestionData = rawSuggestion.data(using: .utf8) else {
            throw LLMProviderError.invalidResponse
        }

        do {
            let suggestion = try JSONDecoder().decode(LLMMetadataSuggestion.self, from: suggestionData)
            return LLMProviderResult(suggestion: suggestion, rawResponse: rawSuggestion)
        } catch {
            throw LLMProviderError.invalidResponse
        }
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
