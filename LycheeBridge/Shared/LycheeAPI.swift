import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct LycheeClient {
    private static let authenticationRegistry = LycheeAuthenticationRegistry()
    private static let loginThrottle = LycheeLoginThrottle()

    let configuration: LycheeConfiguration
    let credentials: LycheeCredentials
    let debugRecorder: (@Sendable (LycheeDebugTrace) -> Void)?

    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let sessionState = LycheeClientSessionState()

    init(
        configuration: LycheeConfiguration,
        credentials: LycheeCredentials,
        debugRecorder: (@Sendable (LycheeDebugTrace) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.debugRecorder = debugRecorder

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.httpCookieAcceptPolicy = .always
        sessionConfiguration.httpShouldSetCookies = true
        let cookieStorage = HTTPCookieStorage.shared
        sessionConfiguration.httpCookieStorage = cookieStorage
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 300
        self.cookieStorage = cookieStorage
        self.session = URLSession(configuration: sessionConfiguration)
    }

    func testConnection() async throws -> [LycheeAlbum] {
        try await loginIfNeeded()
        return try await fetchAlbums()
    }

    func fetchAlbums() async throws -> [LycheeAlbum] {
        let payload = try await performAuthenticatedRequest {
            try await performFirstSuccessfulRequest(
                candidatePaths: [
                    "api/v2/Albums",
                    "api/Albums"
                ],
                builder: { path in
                    try makeGETRequest(path: path)
                }
            )
        }
        return try AlbumResponseParser.parseAlbums(from: payload)
    }

    func fetchTags() async throws -> [LycheeTag] {
        let payload = try await performAuthenticatedRequest {
            try await performFirstSuccessfulRequest(
                candidatePaths: [
                    "api/v2/Tags",
                    "api/Tags"
                ],
                builder: { path in
                    try makeGETRequest(path: path)
                }
            )
        }
        return try TagResponseParser.parseTags(from: payload)
    }

    func upload(photo: ImportedPhoto, to albumID: String) async throws -> String? {
        let payload = try await performAuthenticatedRequest {
            try await performFirstSuccessfulRequest(
                candidatePaths: [
                    "api/v2/Photo",
                    "api/Photo"
                ],
                builder: { path in
                    try makeUploadRequest(path: path, photo: photo, albumID: albumID)
                }
            )
        }

        if let remoteID = UploadResponseParser.parseRemoteID(from: payload),
           remoteID.count == 24 {
            return remoteID
        }

        let uploadedFilename = UploadResponseParser.parseUploadedFilename(from: payload)
        let originalChecksum = try sha1Checksum(for: photo.fileURL)
        return try await resolveUploadedPhotoID(
            albumID: albumID,
            originalFilename: photo.originalFilename,
            uploadedFilename: uploadedFilename,
            originalChecksum: originalChecksum
        )
    }

    func renamePhoto(photoID: String, title: String) async throws {
        _ = try await performAuthenticatedRequest {
            try await performFirstSuccessfulRequest(
                candidatePaths: [
                    "api/v2/Photo::rename",
                    "api/Photo::rename"
                ],
                builder: { path in
                    try makeJSONRequest(path: path, method: "PATCH", payload: [
                        "photo_id": photoID,
                        "title": title
                    ])
                }
            )
        }
    }

    func applyTags(photoID: String, tags: [String], shallOverride: Bool = false) async throws {
        _ = try await performAuthenticatedRequest {
            try await performFirstSuccessfulRequest(
                candidatePaths: [
                    "api/v2/Photo::tags",
                    "api/Photo::tags"
                ],
                builder: { path in
                    try makeJSONRequest(path: path, method: "PATCH", payload: [
                        "shall_override": shallOverride,
                        "photo_ids": [photoID],
                        "tags": tags
                    ])
                }
            )
        }
    }

    private func loginIfNeeded() async throws {
        guard let baseURL = normalizedBaseURL else {
            throw LycheeClientError.invalidServerURL
        }

        let trimmedPassword = credentials.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedUsername.isEmpty == false, trimmedPassword.isEmpty == false else {
            throw LycheeClientError.missingCredentials
        }

        try await bootstrapSessionIfNeeded()

        let key = authenticationKey(baseURL: baseURL, username: trimmedUsername)
        let clientIsAuthenticated = await sessionState.isAuthenticated
        let processIsAuthenticated = await Self.authenticationRegistry.isAuthenticated(for: key)
        if clientIsAuthenticated || (hasReusableCookies(for: baseURL) && processIsAuthenticated) {
            await sessionState.markAuthenticated()
            return
        }

        try await Self.loginThrottle.prepareAttempt(for: key)

        let payload = try await performFirstSuccessfulRequest(
            candidatePaths: [
                "api/v2/Auth::login",
                "api/Auth::login",
                "api/v2/Session::login",
                "api/Session::login"
            ],
            builder: { path in
                if path.contains("Auth::login") {
                    return try makeJSONRequest(path: path, payload: [
                        "username": trimmedUsername,
                        "password": trimmedPassword
                    ])
                }

                return try makeFormRequest(path: path, form: [
                    "username": trimmedUsername,
                    "password": trimmedPassword
                ])
            }
        )

        if let apiError = UploadResponseParser.parseErrorMessage(from: payload) {
            throw LycheeClientError.server(message: apiError)
        }

        await sessionState.markAuthenticated()
        await Self.authenticationRegistry.markAuthenticated(for: key)
    }

    private func performAuthenticatedRequest(_ operation: () async throws -> Data) async throws -> Data {
        try await loginIfNeeded()

        do {
            return try await operation()
        } catch let error as LycheeClientError where error.requiresAuthenticationRefresh {
            if let key = currentAuthenticationKey {
                await Self.authenticationRegistry.invalidate(for: key)
            }
            await sessionState.markUnauthenticated()

            try await loginIfNeeded()
            return try await operation()
        }
    }

    private func resolveUploadedPhotoID(
        albumID: String,
        originalFilename: String,
        uploadedFilename: String?,
        originalChecksum: String
    ) async throws -> String? {
        let payload = try await performAuthenticatedRequest {
            try await performFirstSuccessfulRequest(
                candidatePaths: [
                    "api/v2/Album::photos",
                    "api/Album::photos"
                ],
                builder: { path in
                    try makeGETRequest(path: path, queryItems: [
                        URLQueryItem(name: "album_id", value: albumID),
                        URLQueryItem(name: "page", value: "1"),
                        URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))
                    ])
                }
            )
        }

        return UploadResponseParser.parsePhotoID(
            from: payload,
            matching: uploadedFilename,
            originalFilename: originalFilename,
            originalChecksum: originalChecksum
        )
    }

    private func sha1Checksum(for url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeFormRequest(path: String, form: [String: String]) throws -> URLRequest {
        guard let baseURL = normalizedBaseURL else {
            throw LycheeClientError.invalidServerURL
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyDefaultHeaders(to: &request, contentType: "application/x-www-form-urlencoded; charset=utf-8")
        let encoded = form
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
        request.httpBody = encoded.data(using: .utf8) ?? Data()
        return request
    }

    private func makeJSONRequest(path: String, payload: [String: String]) throws -> URLRequest {
        try makeJSONRequest(path: path, method: "POST", payload: payload)
    }

    private func makeJSONRequest(path: String, method: String, payload: [String: Any]) throws -> URLRequest {
        guard let baseURL = normalizedBaseURL else {
            throw LycheeClientError.invalidServerURL
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyDefaultHeaders(to: &request, contentType: "application/json")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        return request
    }

    private func makeGETRequest(path: String) throws -> URLRequest {
        try makeGETRequest(path: path, queryItems: [])
    }

    private func makeGETRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard let baseURL = normalizedBaseURL else {
            throw LycheeClientError.invalidServerURL
        }

        var url = baseURL.appendingPathComponent(path)
        if queryItems.isEmpty == false {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems
            if let componentURL = components?.url {
                url = componentURL
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        applyDefaultHeaders(to: &request, contentType: "application/json")
        return request
    }

    private func makeUploadRequest(path: String, photo: ImportedPhoto, albumID: String) throws -> URLRequest {
        guard let baseURL = normalizedBaseURL else {
            throw LycheeClientError.invalidServerURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyDefaultHeaders(to: &request, contentType: "multipart/form-data; boundary=\(boundary)")

        let fileData = try Data(contentsOf: photo.fileURL)
        var body = Data()

        func appendField(name: String, value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        appendField(name: "album_id", value: albumID)
        appendField(name: "file_name", value: photo.originalFilename)
        appendField(name: "uuid_name", value: "")
        appendField(name: "extension", value: "")
        appendField(name: "chunk_number", value: "1")
        appendField(name: "total_chunks", value: "1")

        let filename = photo.originalFilename
        let mimeType = photo.mimeType.isEmpty ? inferredMimeType(for: photo.fileURL) : photo.mimeType
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    private var normalizedBaseURL: URL? {
        guard let url = configuration.serverURL else {
            return nil
        }

        if url.path.isEmpty {
            return url.appending(path: "")
        }

        return url
    }

    private func bootstrapSessionIfNeeded() async throws {
        guard await sessionState.needsBootstrap else {
            return
        }

        guard let baseURL = normalizedBaseURL else {
            throw LycheeClientError.invalidServerURL
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let origin = originString {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        }
        _ = try await performDataRequest(request, validateAPIError: false)
        recordDebugTrace(stage: "bootstrap", request: request, responseStatus: 200, responseBody: "Bootstrap completed", extra: cookieDebugDump())
        await sessionState.markBootstrapped()
    }

    private func applyDefaultHeaders(to request: inout URLRequest, contentType: String) {
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache, no-store, must-revalidate, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if let origin = originString {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        }
        applyCSRFHeaders(to: &request)
        applyCookieHeader(to: &request)
    }

    private func applyCSRFHeaders(to request: inout URLRequest) {
        guard let xsrfToken = xsrfToken else {
            return
        }

        request.setValue(xsrfToken, forHTTPHeaderField: "X-XSRF-TOKEN")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    }

    private func applyCookieHeader(to request: inout URLRequest) {
        guard let baseURL = normalizedBaseURL,
              let cookies = cookieStorage.cookies(for: baseURL),
              cookies.isEmpty == false else {
            return
        }

        let header = HTTPCookie.requestHeaderFields(with: cookies)
        for (field, value) in header {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    private var xsrfToken: String? {
        guard let baseURL = normalizedBaseURL,
              let cookies = cookieStorage.cookies(for: baseURL) else {
            return nil
        }

        for cookie in cookies {
            if cookie.name.caseInsensitiveCompare("XSRF-TOKEN") == .orderedSame {
                return cookie.value.removingPercentEncoding ?? cookie.value
            }
        }

        return nil
    }

    private var originString: String? {
        guard let baseURL = normalizedBaseURL,
              let scheme = baseURL.scheme,
              let host = baseURL.host else {
            return nil
        }

        if let port = baseURL.port {
            return "\(scheme)://\(host):\(port)"
        }

        return "\(scheme)://\(host)"
    }

    private var currentAuthenticationKey: String? {
        guard let baseURL = normalizedBaseURL else {
            return nil
        }

        let trimmedUsername = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedUsername.isEmpty == false else {
            return nil
        }

        return authenticationKey(baseURL: baseURL, username: trimmedUsername)
    }

    private func authenticationKey(baseURL: URL, username: String) -> String {
        "\(baseURL.absoluteString)|\(username)"
    }

    private func hasReusableCookies(for baseURL: URL) -> Bool {
        guard let cookies = cookieStorage.cookies(for: baseURL) else {
            return false
        }

        return cookies.contains { cookie in
            cookie.isExpired == false && cookie.name.caseInsensitiveCompare("XSRF-TOKEN") != .orderedSame
        }
    }

    private func performFirstSuccessfulRequest(
        candidatePaths: [String],
        builder: (String) throws -> URLRequest
    ) async throws -> Data {
        var lastError: Error?

        for path in candidatePaths {
            do {
                let request = try builder(path)
                let data = try await performDataRequest(request)
                return data
            } catch let error as LycheeClientError {
                lastError = error
                if error.isSessionExpiry {
                    continue
                }
                if case .httpError(statusCode: 404, _) = error {
                    continue
                }
                throw error
            } catch {
                lastError = error
            }
        }

        throw (lastError as? LycheeClientError) ?? LycheeClientError.invalidResponse
    }

    private func performDataRequest(_ request: URLRequest, validateAPIError: Bool = true) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LycheeClientError.invalidResponse
            }

            let headerFields: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) { partialResult, pair in
                guard let keyString = pair.key as? String else { return }
                if let valueString = pair.value as? String {
                    partialResult[keyString] = valueString
                } else {
                    partialResult[keyString] = String(describing: pair.value)
                }
            }

            if let url = request.url {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                if cookies.isEmpty == false {
                    cookieStorage.setCookies(cookies, for: url, mainDocumentURL: normalizedBaseURL)
                }
            }

            let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8 body: \(data.count) bytes>"
            recordDebugTrace(
                stage: request.url?.lastPathComponent ?? "request",
                request: request,
                responseStatus: httpResponse.statusCode,
                responseHeaders: headerFields,
                responseBody: responseText,
                extra: cookieDebugDump()
            )

            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LycheeClientError.httpError(statusCode: httpResponse.statusCode, message: message)
            }

            if validateAPIError, data.isEmpty == false {
                if let apiError = UploadResponseParser.parseErrorMessage(from: data) {
                    throw LycheeClientError.server(message: apiError)
                }
            }

            return data
        } catch let error as LycheeClientError {
            throw error
        } catch {
            recordDebugTrace(
                stage: request.url?.lastPathComponent ?? "request",
                request: request,
                responseStatus: nil,
                responseHeaders: [:],
                responseBody: error.localizedDescription,
                extra: cookieDebugDump()
            )
            throw LycheeClientError.network(error.localizedDescription)
        }
    }

    private func recordDebugTrace(
        stage: String,
        request: URLRequest,
        responseStatus: Int?,
        responseHeaders: [String: String] = [:],
        responseBody: String,
        extra: String
    ) {
        guard let debugRecorder else { return }

        let trace = LycheeDebugTrace(
            stage: stage,
            requestURL: request.url?.absoluteString ?? "<missing>",
            method: request.httpMethod ?? "GET",
            requestHeaders: LycheeDebugRedactor.redactedHeaders(request.allHTTPHeaderFields ?? [:]),
            requestBody: LycheeDebugRedactor.bodyDescription(for: request),
            responseStatus: responseStatus,
            responseHeaders: LycheeDebugRedactor.redactedHeaders(responseHeaders),
            responseBody: LycheeDebugRedactor.responseBodyDescription(responseBody, contentType: responseHeaders.contentType),
            cookieDump: extra
        )
        debugRecorder(trace)
    }

    private func cookieDebugDump() -> String {
        guard let baseURL = normalizedBaseURL,
              let cookies = cookieStorage.cookies(for: baseURL),
              cookies.isEmpty == false else {
            return "No cookies stored"
        }

        return cookies
            .map { cookie in
                "\(cookie.name)=<redacted>; domain=\(cookie.domain); path=\(cookie.path)"
            }
            .joined(separator: "\n")
    }

    private func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? text
    }

    private func inferredMimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }

        return "application/octet-stream"
    }
}

enum LycheeClientError: LocalizedError {
    case invalidServerURL
    case missingCredentials
    case invalidResponse
    case network(String)
    case httpError(statusCode: Int, message: String?)
    case server(message: String)
    case loginRateLimited(retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid Lychee server URL."
        case .missingCredentials:
            return "Enter a Lychee username and password first."
        case .invalidResponse:
            return "The Lychee server returned an invalid response."
        case let .network(message):
            return "Network error: \(message)"
        case let .httpError(statusCode, message):
            if let message, message.isEmpty == false {
                return "Lychee returned HTTP \(statusCode): \(message)"
            }
            return "Lychee returned HTTP \(statusCode)."
        case let .server(message):
            return message
        case let .loginRateLimited(retryAfter):
            let seconds = max(Int(ceil(retryAfter)), 1)
            return "Lychee login was attempted recently. Try again in \(seconds) seconds to avoid the server login rate limit."
        }
    }
}

private extension LycheeClientError {
    var isSessionExpiry: Bool {
        switch self {
        case let .server(message):
            return message.localizedCaseInsensitiveContains("session expired")
        case let .httpError(statusCode, _):
            return statusCode == 401 || statusCode == 419
        default:
            return false
        }
    }

    var requiresAuthenticationRefresh: Bool {
        isSessionExpiry
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }
}

private extension HTTPCookie {
    var isExpired: Bool {
        guard let expiresDate else {
            return false
        }

        return expiresDate <= Date()
    }
}

private actor LycheeClientSessionState {
    private var didBootstrap = false
    private var didAuthenticate = false

    var needsBootstrap: Bool {
        didBootstrap == false
    }

    var isAuthenticated: Bool {
        didAuthenticate
    }

    func markBootstrapped() {
        didBootstrap = true
    }

    func markAuthenticated() {
        didAuthenticate = true
    }

    func markUnauthenticated() {
        didAuthenticate = false
    }
}

private actor LycheeAuthenticationRegistry {
    private var authenticatedKeys: Set<String> = []

    func isAuthenticated(for key: String) -> Bool {
        authenticatedKeys.contains(key)
    }

    func markAuthenticated(for key: String) {
        authenticatedKeys.insert(key)
    }

    func invalidate(for key: String) {
        authenticatedKeys.remove(key)
    }
}

private actor LycheeLoginThrottle {
    private let minimumInterval: TimeInterval = 6 * 60
    private var lastAttempts: [String: Date] = [:]

    func prepareAttempt(for key: String) throws {
        let now = Date()
        if let lastAttempt = lastAttempts[key] {
            let elapsed = now.timeIntervalSince(lastAttempt)
            if elapsed < minimumInterval {
                throw LycheeClientError.loginRateLimited(retryAfter: minimumInterval - elapsed)
            }
        }

        lastAttempts[key] = now
    }
}
