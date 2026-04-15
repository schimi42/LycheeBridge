import Foundation
import UniformTypeIdentifiers

struct LycheeClient {
    let configuration: LycheeConfiguration
    let credentials: LycheeCredentials
    let debugRecorder: (@Sendable (LycheeDebugTrace) -> Void)?

    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage

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
        try await loginIfNeeded()
        let payload = try await performFirstSuccessfulRequest(
            candidatePaths: [
                "api/v2/Albums",
                "api/Albums"
            ],
            builder: { path in
                try makeGETRequest(path: path)
            }
        )
        return try AlbumResponseParser.parseAlbums(from: payload)
    }

    func upload(photo: ImportedPhoto, to albumID: String) async throws -> String? {
        try await loginIfNeeded()
        let payload = try await performFirstSuccessfulRequest(
            candidatePaths: [
                "api/v2/Photo",
                "api/Photo"
            ],
            builder: { path in
                try makeUploadRequest(path: path, photo: photo, albumID: albumID)
            }
        )
        return UploadResponseParser.parseRemoteID(from: payload)
    }

    private func loginIfNeeded() async throws {
        guard let _ = normalizedBaseURL else {
            throw LycheeClientError.invalidServerURL
        }

        let trimmedPassword = credentials.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedUsername.isEmpty == false, trimmedPassword.isEmpty == false else {
            throw LycheeClientError.missingCredentials
        }

        try await bootstrapSession()

        if configuration.hasReusableAuthentication {
            return
        }

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
        guard let baseURL = normalizedBaseURL else {
            throw LycheeClientError.invalidServerURL
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyDefaultHeaders(to: &request, contentType: "application/json")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        return request
    }

    private func makeGETRequest(path: String) throws -> URLRequest {
        guard let baseURL = normalizedBaseURL else {
            throw LycheeClientError.invalidServerURL
        }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
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

    private func bootstrapSession() async throws {
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
            requestHeaders: redactedHeaders(request.allHTTPHeaderFields ?? [:]),
            requestBody: debugBodyDescription(for: request),
            responseStatus: responseStatus,
            responseHeaders: redactedHeaders(responseHeaders),
            responseBody: redactedBodyDescription(responseBody, contentType: responseHeaders.contentType),
            cookieDump: extra
        )
        debugRecorder(trace)
    }

    private func debugBodyDescription(for request: URLRequest) -> String {
        guard let body = request.httpBody else {
            return "<empty>"
        }

        let contentType = request.value(forHTTPHeaderField: "Content-Type")
        if contentType?.localizedCaseInsensitiveContains("multipart/form-data") == true {
            return "<multipart body: \(body.count) bytes>"
        }

        if contentType?.localizedCaseInsensitiveContains("application/json") == true {
            return redactedJSONBodyDescription(body)
        }

        if contentType?.localizedCaseInsensitiveContains("application/x-www-form-urlencoded") == true {
            return redactedFormBodyDescription(body)
        }

        guard let text = String(data: body, encoding: .utf8) else {
            return "<\(body.count) bytes>"
        }

        return limitedDebugText(text)
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

    private func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { partialResult, pair in
            partialResult[pair.key] = isSensitiveDebugKey(pair.key) ? "<redacted>" : limitedDebugText(pair.value)
        }
    }

    private func redactedBodyDescription(_ body: String, contentType: String?) -> String {
        if contentType?.localizedCaseInsensitiveContains("application/json") == true,
           let data = body.data(using: .utf8) {
            return redactedJSONBodyDescription(data)
        }

        return limitedDebugText(body)
    }

    private func redactedJSONBodyDescription(_ body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            let fallback = String(data: body, encoding: .utf8) ?? "<non-utf8 body: \(body.count) bytes>"
            return limitedDebugText(fallback)
        }

        let redacted = redactedJSONValue(json)
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return limitedDebugText(String(describing: redacted))
        }

        return limitedDebugText(text)
    }

    private func redactedFormBodyDescription(_ body: Data) -> String {
        guard let text = String(data: body, encoding: .utf8), text.isEmpty == false else {
            return "<empty>"
        }

        let redactedPairs = text.split(separator: "&").map { pair -> String in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawKey = parts.first.map(String.init) ?? ""
            let key = rawKey.removingPercentEncoding ?? rawKey
            let value = parts.count > 1 ? String(parts[1]) : ""

            if isSensitiveDebugKey(key) {
                return "\(rawKey)=<redacted>"
            }

            return value.isEmpty ? rawKey : "\(rawKey)=\(value)"
        }

        return limitedDebugText(redactedPairs.joined(separator: "&"))
    }

    private func redactedJSONValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { partialResult, pair in
                partialResult[pair.key] = isSensitiveDebugKey(pair.key) ? "<redacted>" : redactedJSONValue(pair.value)
            }
        }

        if let array = value as? [Any] {
            return array.map(redactedJSONValue)
        }

        return value
    }

    private func isSensitiveDebugKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "cookie" ||
            normalized == "set-cookie" ||
            normalized == "authorization" ||
            normalized == "proxy-authorization" ||
            normalized == "x-xsrf-token" ||
            normalized == "x-csrf-token" ||
            normalized.contains("password") ||
            normalized.contains("passwd") ||
            normalized.contains("secret") ||
            normalized.contains("token") ||
            normalized.contains("cookie") ||
            normalized.contains("csrf") ||
            normalized.contains("xsrf")
    }

    private func limitedDebugText(_ text: String, limit: Int = 12_000) -> String {
        guard text.count > limit else {
            return text
        }

        return String(text.prefix(limit)) + "\n<truncated: \(text.count - limit) characters hidden>"
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

struct LycheeDebugTrace: Sendable {
    let stage: String
    let requestURL: String
    let method: String
    let requestHeaders: [String: String]
    let requestBody: String
    let responseStatus: Int?
    let responseHeaders: [String: String]
    let responseBody: String
    let cookieDump: String

    var formatted: String {
        let headerLines = requestHeaders
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0): \($1)" }
            .joined(separator: "\n")
        let responseHeaderLines = responseHeaders
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0): \($1)" }
            .joined(separator: "\n")

        let statusText = responseStatus.map(String.init) ?? "<none>"

        return """
        [\(stage)]
        URL: \(requestURL)
        Method: \(method)
        Headers:
        \(headerLines.isEmpty ? "<none>" : headerLines)

        Body:
        \(requestBody)

        Response Status: \(statusText)
        Response Headers:
        \(responseHeaderLines.isEmpty ? "<none>" : responseHeaderLines)

        Response Body:
        \(responseBody)

        Cookies:
        \(cookieDump)
        """
    }
}

enum LycheeClientError: LocalizedError {
    case invalidServerURL
    case missingCredentials
    case invalidResponse
    case network(String)
    case httpError(statusCode: Int, message: String?)
    case server(message: String)

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
        }
    }
}

private extension LycheeClientError {
    var isSessionExpiry: Bool {
        switch self {
        case let .server(message):
            return message.localizedCaseInsensitiveContains("session expired")
        default:
            return false
        }
    }
}

private enum AlbumResponseParser {
    static func parseAlbums(from data: Data) throws -> [LycheeAlbum] {
        let json = try JSONSerialization.jsonObject(with: data)
        var albums: [LycheeAlbum] = []

        if let dictionary = json as? [String: Any] {
            collectAlbums(from: dictionary, into: &albums, parentPath: nil)
        } else if let array = json as? [[String: Any]] {
            for entry in array {
                collectAlbums(from: entry, into: &albums, parentPath: nil)
            }
        } else {
            throw SharedStoreError.invalidManifest
        }

        let unique = Dictionary(grouping: albums, by: \.id).compactMap { _, group in group.first }
        return unique.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private static func collectAlbums(from dictionary: [String: Any], into albums: inout [LycheeAlbum], parentPath: String?) {
        if let album = makeAlbum(from: dictionary, parentPath: parentPath) {
            albums.append(album)
        }

        for key in ["albums", "children", "smart_albums", "shared", "shared_albums", "pinned_albums", "tag_albums", "nested"] {
            if let childArray = dictionary[key] as? [[String: Any]] {
                for child in childArray {
                    let nextParentPath = makeAlbum(from: dictionary, parentPath: parentPath)?.displayTitle ?? parentPath
                    collectAlbums(from: child, into: &albums, parentPath: nextParentPath)
                }
            }
        }
    }

    private static func makeAlbum(from dictionary: [String: Any], parentPath: String?) -> LycheeAlbum? {
        let id = stringValue(for: ["id", "albumID"], in: dictionary)
        let title = stringValue(for: ["title"], in: dictionary)

        guard let id, let title else {
            return nil
        }

        let parentID = stringValue(for: ["parent_id", "parentID"], in: dictionary)
        let path = parentPath.map { "\($0) / \(title)" } ?? title
        return LycheeAlbum(id: id, title: title, parentID: parentID, path: path)
    }

    private static func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let string = dictionary[key] as? String, string.isEmpty == false {
                return string
            }
            if let number = dictionary[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }
}

private enum UploadResponseParser {
    static func parseRemoteID(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            let plain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return plain?.isEmpty == false ? plain : nil
        }

        if let string = json as? String, string.isEmpty == false {
            return string
        }

        if let dictionary = json as? [String: Any] {
            for key in ["id", "photoID", "photo_id"] {
                if let value = dictionary[key] as? String, value.isEmpty == false {
                    return value
                }
                if let value = dictionary[key] as? NSNumber {
                    return value.stringValue
                }
            }
        }

        return nil
    }

    static func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let dictionary = json as? [String: Any] else {
            return nil
        }

        if let status = dictionary["status"] as? String,
           status.lowercased() == "error",
           let message = dictionary["message"] as? String {
            return message
        }

        if let message = dictionary["error"] as? String, message.isEmpty == false {
            return message
        }

        return nil
    }
}

private extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }
}

private extension Dictionary where Key == String, Value == String {
    var contentType: String? {
        first { key, _ in
            key.localizedCaseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value
    }
}
