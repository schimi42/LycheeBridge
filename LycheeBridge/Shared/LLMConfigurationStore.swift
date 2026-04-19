import Foundation

struct LLMConfigurationStore {
    private let configurationFilename = "llm.configuration.json"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func load() throws -> LLMConfiguration {
        let configurationURL = try configurationURL()
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return LLMConfiguration()
        }

        let data = try Data(contentsOf: configurationURL)
        return try decoder.decode(LLMConfiguration.self, from: data)
    }

    func save(_ configuration: LLMConfiguration) throws {
        let data = try encoder.encode(configuration)
        try data.write(to: configurationURL(), options: .atomic)
    }

    private func configurationURL() throws -> URL {
        try SharedPaths.containerURL().appendingPathComponent(configurationFilename, isDirectory: false)
    }
}
