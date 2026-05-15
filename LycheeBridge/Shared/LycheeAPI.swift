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

    func fetchPhotos(albumID: String) async throws -> [LycheePhoto] {
        var page = 1
        var photos: [LycheePhoto] = []
        var lastPage = 1

        repeat {
            let payload = try await fetchPhotoPage(albumID: albumID, page: page)
            photos.append(contentsOf: try AlbumPhotoResponseParser.parsePhotos(from: payload))

            if let pagination = AlbumPhotoResponseParser.parsePagination(from: payload) {
                lastPage = pagination.lastPage
                page = pagination.currentPage + 1
            } else {
                lastPage = page
                page += 1
            }
        } while page <= lastPage

        let unique = Dictionary(grouping: photos, by: \.id).compactMap { _, group in group.first }
        return unique.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    func downloadPreview(for photo: LycheePhoto) async throws -> Data {
        guard let url = photo.llmPreviewURL else {
            throw LycheeClientError.invalidResponse
        }

        return try await performAuthenticatedRequest {
            let request = try makeBinaryGETRequest(url: url)
            return try await performBinaryDataRequest(request)
        }
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

    private func fetchPhotoPage(albumID: String, page: Int) async throws -> Data {
        try await performAuthenticatedRequest {
            try await performFirstSuccessfulRequest(
                candidatePaths: [
                    "api/v2/Album::photos",
                    "api/Album::photos"
                ],
                builder: { path in
                    try makeGETRequest(path: path, queryItems: [
                        URLQueryItem(name: "album_id", value: albumID),
                        URLQueryItem(name: "page", value: String(page)),
                        URLQueryItem(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1000)))
                    ])
                }
            )
        }
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

    private func makeBinaryGETRequest(url: URL) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let origin = originString {
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        }
        applyCookieHeader(to: &request)
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

    private func performBinaryDataRequest(_ request: URLRequest) async throws -> Data {
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

            recordDebugTrace(
                stage: "photo preview",
                request: request,
                responseStatus: httpResponse.statusCode,
                responseHeaders: headerFields,
                responseBody: "<binary image: \(data.count) bytes>",
                extra: cookieDebugDump()
            )

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw LycheeClientError.httpError(statusCode: httpResponse.statusCode, message: nil)
            }

            return data
        } catch let error as LycheeClientError {
            throw error
        } catch {
            recordDebugTrace(
                stage: "photo preview",
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

struct PixelfedClient {
    let configuration: PixelfedConfiguration
    let credentials: PixelfedCredentials
    let debugRecorder: (@Sendable (LycheeDebugTrace) -> Void)?

    private let session: URLSession

    init(
        configuration: PixelfedConfiguration,
        credentials: PixelfedCredentials,
        debugRecorder: (@Sendable (LycheeDebugTrace) -> Void)? = nil
    ) throws {
        self.configuration = configuration
        self.credentials = credentials
        self.debugRecorder = debugRecorder

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: sessionConfiguration)
    }

    func verifyCredentials() async throws -> String {
        let payload = try await performRequest(
            try makeRequest(
                path: "api/v1/accounts/verify_credentials",
                method: "GET"
            )
        )

        guard
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            throw PixelfedClientError.invalidResponse
        }

        let username = (object["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let acct = (object["acct"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (object["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let displayName, displayName.isEmpty == false {
            return displayName
        }
        if let username, username.isEmpty == false {
            return username
        }
        if let acct, acct.isEmpty == false {
            return acct
        }

        throw PixelfedClientError.invalidResponse
    }

    func uploadMedia(photo: ImportedPhoto) async throws -> String {
        let request = try makeMediaUploadRequest(photo: photo)
        let payload = try await performRequest(request)

        guard
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            throw PixelfedClientError.invalidResponse
        }

        if let id = object["id"] as? String, id.isEmpty == false {
            return id
        }

        if let id = object["id"] as? NSNumber {
            return id.stringValue
        }

        throw PixelfedClientError.invalidResponse
    }

    func createStatus(caption: String, mediaIDs: [String], visibility: PixelfedConfiguration.Visibility) async throws -> String? {
        var form: [(String, String)] = [
            ("visibility", visibility.rawValue)
        ]

        if caption.isEmpty == false {
            form.append(("status", caption))
        }

        mediaIDs.forEach { form.append(("media_ids[]", $0)) }

        var request = try makeFormRequest(path: "api/v1/statuses", method: "POST", form: form)
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        let payload = try await performRequest(request)

        guard
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            throw PixelfedClientError.invalidResponse
        }

        if let id = object["id"] as? String, id.isEmpty == false {
            return id
        }

        if let id = object["id"] as? NSNumber {
            return id.stringValue
        }

        return nil
    }

    private var normalizedBaseURL: URL? {
        configuration.instanceURL
    }

    private var bearerToken: String? {
        let trimmed = credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let baseURL = normalizedBaseURL else {
            throw PixelfedClientError.invalidServerURL
        }
        guard let token = bearerToken else {
            throw PixelfedClientError.missingAccessToken
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeFormRequest(path: String, method: String, form: [(String, String)]) throws -> URLRequest {
        var request = try makeRequest(path: path, method: method)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let encoded = form.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
        request.httpBody = encoded.data(using: .utf8) ?? Data()
        return request
    }

    private func makeMediaUploadRequest(photo: ImportedPhoto) throws -> URLRequest {
        var request = try makeRequest(path: "api/v1/media", method: "POST")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: photo.fileURL)
        var body = Data()
        let mimeType = photo.mimeType.isEmpty ? inferredMimeType(for: photo.fileURL) : photo.mimeType

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(photo.originalFilename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")

        request.httpBody = body
        return request
    }

    private func performRequest(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PixelfedClientError.invalidResponse
            }

            let headerFields: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) { partialResult, pair in
                guard let keyString = pair.key as? String else { return }
                if let valueString = pair.value as? String {
                    partialResult[keyString] = valueString
                } else {
                    partialResult[keyString] = String(describing: pair.value)
                }
            }

            let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8 body: \(data.count) bytes>"
            recordDebugTrace(
                stage: pixelfedStageName(for: request.url),
                request: request,
                responseStatus: httpResponse.statusCode,
                responseHeaders: headerFields,
                responseBody: responseText
            )

            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PixelfedClientError.httpError(statusCode: httpResponse.statusCode, message: message)
            }

            return data
        } catch let error as PixelfedClientError {
            throw error
        } catch {
            recordDebugTrace(
                stage: pixelfedStageName(for: request.url),
                request: request,
                responseStatus: nil,
                responseHeaders: [:],
                responseBody: error.localizedDescription
            )
            throw PixelfedClientError.network(error.localizedDescription)
        }
    }

    private func recordDebugTrace(
        stage: String,
        request: URLRequest,
        responseStatus: Int?,
        responseHeaders: [String: String],
        responseBody: String
    ) {
        guard let debugRecorder else { return }

        debugRecorder(LycheeDebugTrace(
            stage: stage,
            requestURL: request.url?.absoluteString ?? "<missing>",
            method: request.httpMethod ?? "GET",
            requestHeaders: LycheeDebugRedactor.redactedHeaders(request.allHTTPHeaderFields ?? [:]),
            requestBody: LycheeDebugRedactor.bodyDescription(for: request),
            responseStatus: responseStatus,
            responseHeaders: LycheeDebugRedactor.redactedHeaders(responseHeaders),
            responseBody: LycheeDebugRedactor.responseBodyDescription(responseBody, contentType: responseHeaders.contentType),
            cookieDump: "No cookies stored"
        ))
    }

    private func pixelfedStageName(for url: URL?) -> String {
        let path = url?.path ?? ""
        if path.contains("/api/v1/accounts/verify_credentials") {
            return "Pixelfed::verify_credentials"
        }
        if path.contains("/api/v1/media") {
            return "Pixelfed::media"
        }
        if path.contains("/api/v1/statuses") {
            return "Pixelfed::statuses"
        }
        return "Pixelfed"
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

enum PixelfedClientError: LocalizedError {
    case invalidServerURL
    case missingAccessToken
    case invalidResponse
    case network(String)
    case httpError(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid Pixelfed instance URL."
        case .missingAccessToken:
            return "Enter a Pixelfed access token first."
        case .invalidResponse:
            return "Pixelfed returned an invalid response."
        case let .network(message):
            return "Pixelfed network error: \(message)"
        case let .httpError(statusCode, message):
            if let message, message.isEmpty == false {
                return "Pixelfed returned HTTP \(statusCode): \(message)"
            }
            return "Pixelfed returned HTTP \(statusCode)."
        }
    }
}

extension PixelfedClient {
    struct OAuthRegistration {
        let instanceURL: URL
        let clientID: String
        let clientSecret: String
    }

    static func registerOAuthApplication(
        instanceURL: URL?,
        redirectURI: URL,
        debugRecorder: (@Sendable (LycheeDebugTrace) -> Void)? = nil
    ) async throws -> OAuthRegistration {
        guard let instanceURL else {
            throw PixelfedClientError.invalidServerURL
        }

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: sessionConfiguration)

        var request = URLRequest(url: instanceURL.appendingPathComponent("api/v1/apps"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            ("client_name", "LycheeBridge"),
            ("redirect_uris", redirectURI.absoluteString),
            ("scopes", "read write"),
            ("website", "https://github.com/")
        ]
        .map { key, value in
            "\(percentEncodeStatic(key))=\(percentEncodeStatic(value))"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()

        let payload = try await performOAuthRequest(
            session: session,
            request: request,
            stage: "Pixelfed::apps",
            debugRecorder: debugRecorder
        )

        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let clientID = object["client_id"] as? String,
              let clientSecret = object["client_secret"] as? String,
              clientID.isEmpty == false,
              clientSecret.isEmpty == false else {
            throw PixelfedClientError.invalidResponse
        }

        return OAuthRegistration(
            instanceURL: instanceURL,
            clientID: clientID,
            clientSecret: clientSecret
        )
    }

    static func makeAuthorizationURL(
        instanceURL: URL,
        clientID: String,
        redirectURI: URL,
        state: String
    ) throws -> URL {
        var components = URLComponents(url: instanceURL.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "read write"),
            URLQueryItem(name: "state", value: state)
        ]

        guard let url = components?.url else {
            throw PixelfedClientError.invalidServerURL
        }

        return url
    }

    static func exchangeAuthorizationCode(
        transaction: PixelfedPendingOAuthTransaction,
        code: String,
        debugRecorder: (@Sendable (LycheeDebugTrace) -> Void)? = nil
    ) async throws -> String {
        guard let instanceURL = transaction.instanceURL else {
            throw PixelfedClientError.invalidServerURL
        }

        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: sessionConfiguration)

        var request = URLRequest(url: instanceURL.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            ("grant_type", "authorization_code"),
            ("client_id", transaction.clientID),
            ("client_secret", transaction.clientSecret),
            ("redirect_uri", transaction.redirectURIString),
            ("code", code)
        ]
        .map { key, value in
            "\(percentEncodeStatic(key))=\(percentEncodeStatic(value))"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()

        let payload = try await performOAuthRequest(
            session: session,
            request: request,
            stage: "Pixelfed::oauth_token",
            debugRecorder: debugRecorder
        )

        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              accessToken.isEmpty == false else {
            throw PixelfedClientError.invalidResponse
        }

        return accessToken
    }

    private static func performOAuthRequest(
        session: URLSession,
        request: URLRequest,
        stage: String,
        debugRecorder: (@Sendable (LycheeDebugTrace) -> Void)?
    ) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PixelfedClientError.invalidResponse
            }

            let responseHeaders: [String: String] = httpResponse.allHeaderFields.reduce(into: [:]) { partialResult, pair in
                guard let keyString = pair.key as? String else { return }
                partialResult[keyString] = String(describing: pair.value)
            }

            if let debugRecorder {
                let responseText = String(data: data, encoding: .utf8) ?? "<non-utf8 body: \(data.count) bytes>"
                debugRecorder(LycheeDebugTrace(
                    stage: stage,
                    requestURL: request.url?.absoluteString ?? "<missing>",
                    method: request.httpMethod ?? "GET",
                    requestHeaders: LycheeDebugRedactor.redactedHeaders(request.allHTTPHeaderFields ?? [:]),
                    requestBody: LycheeDebugRedactor.bodyDescription(for: request),
                    responseStatus: httpResponse.statusCode,
                    responseHeaders: LycheeDebugRedactor.redactedHeaders(responseHeaders),
                    responseBody: LycheeDebugRedactor.responseBodyDescription(responseText, contentType: responseHeaders.contentType),
                    cookieDump: "No cookies stored"
                ))
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PixelfedClientError.httpError(statusCode: httpResponse.statusCode, message: message)
            }

            return data
        } catch let error as PixelfedClientError {
            throw error
        } catch {
            if let debugRecorder {
                debugRecorder(LycheeDebugTrace(
                    stage: stage,
                    requestURL: request.url?.absoluteString ?? "<missing>",
                    method: request.httpMethod ?? "GET",
                    requestHeaders: LycheeDebugRedactor.redactedHeaders(request.allHTTPHeaderFields ?? [:]),
                    requestBody: LycheeDebugRedactor.bodyDescription(for: request),
                    responseStatus: nil,
                    responseHeaders: [:],
                    responseBody: error.localizedDescription,
                    cookieDump: "No cookies stored"
                ))
            }
            throw PixelfedClientError.network(error.localizedDescription)
        }
    }

    private static func percentEncodeStatic(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? text
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
