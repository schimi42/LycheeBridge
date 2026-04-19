import Foundation

struct LLMConfigurationStore {
    private let configurationFilename = "llm.configuration.json"
    private let keychainStore = KeychainStore()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func load() throws -> (LLMConfiguration, LLMCredentials) {
        let configurationURL = try configurationURL()
        let credentials = LLMCredentials(openAIAPIKey: try keychainStore.loadOpenAIAPIKey())

        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return (LLMConfiguration(), credentials)
        }

        let data = try Data(contentsOf: configurationURL)
        return (try decoder.decode(LLMConfiguration.self, from: data), credentials)
    }

    func save(configuration: LLMConfiguration, credentials: LLMCredentials) throws {
        let data = try encoder.encode(configuration)
        try data.write(to: configurationURL(), options: .atomic)
        try keychainStore.saveOpenAIAPIKey(credentials.openAIAPIKey)
    }

    private func configurationURL() throws -> URL {
        try SharedPaths.containerURL().appendingPathComponent(configurationFilename, isDirectory: false)
    }
}
