import Foundation

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

enum LycheeDebugRedactor {
    static func redactedHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { partialResult, pair in
            partialResult[pair.key] = isSensitiveDebugKey(pair.key) ? "<redacted>" : limitedDebugText(pair.value)
        }
    }

    static func bodyDescription(for request: URLRequest) -> String {
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

    static func responseBodyDescription(_ body: String, contentType: String?) -> String {
        if contentType?.localizedCaseInsensitiveContains("application/json") == true,
           let data = body.data(using: .utf8) {
            return redactedJSONBodyDescription(data)
        }

        return limitedDebugText(body)
    }

    private static func redactedJSONBodyDescription(_ body: Data) -> String {
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

    private static func redactedFormBodyDescription(_ body: Data) -> String {
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

    private static func redactedJSONValue(_ value: Any) -> Any {
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

    private static func isSensitiveDebugKey(_ key: String) -> Bool {
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

    private static func limitedDebugText(_ text: String, limit: Int = 12_000) -> String {
        guard text.count > limit else {
            return text
        }

        return String(text.prefix(limit)) + "\n<truncated: \(text.count - limit) characters hidden>"
    }
}

extension Dictionary where Key == String, Value == String {
    var contentType: String? {
        first { key, _ in
            key.localizedCaseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value
    }
}
