import Foundation

enum AlbumResponseParser {
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

enum UploadResponseParser {
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
