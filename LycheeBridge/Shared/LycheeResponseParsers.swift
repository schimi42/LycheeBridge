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

enum TagResponseParser {
    static func parseTags(from data: Data) throws -> [LycheeTag] {
        let json = try JSONSerialization.jsonObject(with: data)
        var tags: [LycheeTag] = []

        if let dictionary = json as? [String: Any] {
            if let tagArray = dictionary["tags"] as? [Any] {
                collectTags(from: tagArray, into: &tags)
            } else {
                collectTag(from: dictionary, into: &tags)
            }
        } else if let array = json as? [Any] {
            collectTags(from: array, into: &tags)
        } else {
            throw SharedStoreError.invalidManifest
        }

        let unique = Dictionary(grouping: tags, by: { $0.name.lowercased() }).compactMap { _, group in group.first }
        return unique.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func collectTags(from array: [Any], into tags: inout [LycheeTag]) {
        for entry in array {
            if let dictionary = entry as? [String: Any] {
                collectTag(from: dictionary, into: &tags)
            } else if let string = entry as? String {
                appendTag(id: string, name: string, into: &tags)
            } else if let number = entry as? NSNumber {
                appendTag(id: number.stringValue, name: number.stringValue, into: &tags)
            }
        }
    }

    private static func collectTag(from dictionary: [String: Any], into tags: inout [LycheeTag]) {
        guard let name = stringValue(for: ["name", "tag", "title"], in: dictionary) else {
            return
        }

        let id = stringValue(for: ["id", "tag_id", "tagID"], in: dictionary) ?? name
        appendTag(id: id, name: name, into: &tags)
    }

    private static func appendTag(id: String, name: String, into tags: inout [LycheeTag]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else {
            return
        }

        tags.append(LycheeTag(id: id, name: trimmedName))
    }

    private static func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let string = dictionary[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    return trimmed
                }
            }
            if let number = dictionary[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }
}

enum AlbumPhotoResponseParser {
    static func parsePhotos(from data: Data) throws -> [LycheePhoto] {
        let json = try JSONSerialization.jsonObject(with: data)
        var photos: [LycheePhoto] = []

        collectPhotos(from: json, into: &photos)

        let unique = Dictionary(grouping: photos, by: \.id).compactMap { _, group in group.first }
        return unique.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    static func parsePagination(from data: Data) -> (currentPage: Int, lastPage: Int)? {
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let currentPage = intValue(for: ["current_page", "currentPage"], in: dictionary),
              let lastPage = intValue(for: ["last_page", "lastPage"], in: dictionary) else {
            return nil
        }

        return (currentPage, lastPage)
    }

    private static func collectPhotos(from value: Any, into photos: inout [LycheePhoto]) {
        if let dictionary = value as? [String: Any] {
            if let photo = makePhoto(from: dictionary) {
                photos.append(photo)
            }

            for key in ["photos", "data"] {
                if let array = dictionary[key] as? [Any] {
                    collectPhotos(from: array, into: &photos)
                }
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectPhotos(from: item, into: &photos)
            }
        }
    }

    private static func makePhoto(from dictionary: [String: Any]) -> LycheePhoto? {
        guard let id = stringValue(for: ["id", "photo_id", "photoID"], in: dictionary),
              id.count == 24 else {
            return nil
        }

        let albumID = stringValue(for: ["album_id", "albumID"], in: dictionary) ?? ""
        let title = stringValue(for: ["title"], in: dictionary) ?? ""
        let tags = stringArrayValue(for: "tags", in: dictionary)
        let type = stringValue(for: ["type"], in: dictionary) ?? ""
        let variants = dictionary["size_variants"] as? [String: Any]

        return LycheePhoto(
            id: id,
            albumID: albumID,
            title: title,
            tags: tags,
            type: type,
            thumbURLString: variantURL(named: "thumb", in: variants),
            smallURLString: variantURL(named: "small", in: variants),
            mediumURLString: variantURL(named: "medium", in: variants),
            originalURLString: variantURL(named: "original", in: variants)
        )
    }

    private static func variantURL(named name: String, in variants: [String: Any]?) -> String? {
        guard let variant = variants?[name] as? [String: Any] else {
            return nil
        }

        return stringValue(for: ["url"], in: variant)
    }

    private static func stringArrayValue(for key: String, in dictionary: [String: Any]) -> [String] {
        guard let values = dictionary[key] as? [Any] else {
            return []
        }

        return values.compactMap { value in
            if let string = value as? String {
                return string
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            return nil
        }
    }

    private static func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let string = dictionary[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    return trimmed
                }
            }
            if let number = dictionary[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func intValue(for keys: [String], in dictionary: [String: Any]) -> Int? {
        for key in keys {
            if let number = dictionary[key] as? NSNumber {
                return number.intValue
            }
            if let string = dictionary[key] as? String,
               let int = Int(string) {
                return int
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
            for key in ["id", "photoID", "photo_id", "uuid_name", "uuidName"] {
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

    static func parseUploadedFilename(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let dictionary = json as? [String: Any] else {
            return nil
        }

        return stringValue(for: ["uuid_name", "uuidName", "file_name", "fileName"], in: dictionary)
    }

    static func parsePhotoID(
        from data: Data,
        matching uploadedFilename: String?,
        originalFilename: String,
        originalChecksum: String
    ) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        var photos: [[String: Any]] = []
        collectPhotoDictionaries(from: json, into: &photos)

        let normalizedChecksum = originalChecksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedChecksum.isEmpty == false,
           let id = uniquePhotoID(
            in: photos,
            where: { photo in
                checksumValues(in: photo).contains(normalizedChecksum)
            }
           ) {
            return id
        }

        let uploadedFilename = uploadedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uploadedFilename, uploadedFilename.isEmpty == false {
            if let id = uniquePhotoID(
                in: photos,
                where: { containsString(uploadedFilename, in: $0) }
            ) {
                return id
            }
        }

        return uniquePhotoID(in: photos) { photo in
            let candidateValues = stringValues(in: photo)
            return candidateValues.contains {
                $0.caseInsensitiveCompare(originalFilename) == .orderedSame
                    || $0.localizedCaseInsensitiveContains(originalFilename)
            }
        }
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

    private static func collectPhotoDictionaries(from value: Any, into photos: inout [[String: Any]]) {
        if let dictionary = value as? [String: Any] {
            if stringValue(for: ["id", "photo_id", "photoID"], in: dictionary).map(isPhotoID) == true {
                photos.append(dictionary)
            }

            for value in dictionary.values {
                collectPhotoDictionaries(from: value, into: &photos)
            }
        } else if let array = value as? [Any] {
            for value in array {
                collectPhotoDictionaries(from: value, into: &photos)
            }
        }
    }

    private static func containsString(_ needle: String, in value: Any) -> Bool {
        if let string = value as? String {
            return string.localizedCaseInsensitiveContains(needle)
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { containsString(needle, in: $0) }
        }

        if let array = value as? [Any] {
            return array.contains { containsString(needle, in: $0) }
        }

        return false
    }

    private static func stringValues(in value: Any) -> [String] {
        if let string = value as? String {
            return [string]
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap(stringValues)
        }

        if let array = value as? [Any] {
            return array.flatMap(stringValues)
        }

        return []
    }

    private static func checksumValues(in dictionary: [String: Any]) -> Set<String> {
        Set(
            ["checksum", "original_checksum"]
                .compactMap { stringValue(for: [$0], in: dictionary)?.lowercased() }
        )
    }

    private static func uniquePhotoID(in photos: [[String: Any]], where matches: ([String: Any]) -> Bool) -> String? {
        let ids = photos.compactMap { photo -> String? in
            guard matches(photo),
                  let id = stringValue(for: ["id", "photo_id", "photoID"], in: photo),
                  isPhotoID(id) else {
                return nil
            }

            return id
        }

        let uniqueIDs = Array(Set(ids))
        return uniqueIDs.count == 1 ? uniqueIDs[0] : nil
    }

    private static func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let string = dictionary[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false {
                    return trimmed
                }
            }
            if let number = dictionary[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func isPhotoID(_ value: String) -> Bool {
        value.count == 24 && value.range(of: #"^[A-Za-z0-9+/_=-]{24}$"#, options: .regularExpression) != nil
    }
}
