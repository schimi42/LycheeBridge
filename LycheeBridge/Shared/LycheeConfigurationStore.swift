import Foundation

struct LycheeConfigurationStore {
    private let keychain = KeychainStore()
    private let configurationFilename = "lychee.configuration.json"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    func load() throws -> (LycheeConfiguration, LycheeCredentials) {
        let configuration: LycheeConfiguration
        let configurationURL = try configurationURL()
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            let data = try Data(contentsOf: configurationURL)
            configuration = try decoder.decode(LycheeConfiguration.self, from: data)
        } else {
            configuration = LycheeConfiguration()
        }

        let credentials = LycheeCredentials(password: try keychain.loadPassword())
        return (configuration, credentials)
    }

    func save(configuration: LycheeConfiguration, credentials: LycheeCredentials) throws {
        let data = try encoder.encode(configuration)
        try data.write(to: configurationURL(), options: .atomic)
        try keychain.save(password: credentials.password)
    }

    private func configurationURL() throws -> URL {
        try SharedPaths.containerURL().appendingPathComponent(configurationFilename, isDirectory: false)
    }
}
