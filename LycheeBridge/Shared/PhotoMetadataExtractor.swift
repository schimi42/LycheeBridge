import Foundation
import ImageIO

enum PhotoMetadataExtractor {
    static func extract(from url: URL) -> ImportedPhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return ImportedPhotoMetadata(title: nil, tags: [], fields: [])
        }

        let fields = metadataFields(from: properties)
        let title = firstNonEmptyTitle(in: properties)
        let tags = metadataTags(in: properties)

        return ImportedPhotoMetadata(title: title, tags: tags, fields: fields)
    }

    private static func firstNonEmptyTitle(in properties: [String: Any]) -> String? {
        let iptc = dictionary(for: kCGImagePropertyIPTCDictionary, in: properties)
        let tiff = dictionary(for: kCGImagePropertyTIFFDictionary, in: properties)
        let png = dictionary(for: kCGImagePropertyPNGDictionary, in: properties)

        let candidates = [
            stringValue(for: kCGImagePropertyIPTCObjectName, in: iptc),
            stringValue(for: kCGImagePropertyIPTCHeadline, in: iptc),
            stringValue(for: kCGImagePropertyIPTCCaptionAbstract, in: iptc),
            stringValue(for: kCGImagePropertyTIFFImageDescription, in: tiff),
            stringValue(named: "Description", in: png),
            stringValue(named: "Title", in: properties)
        ]

        return candidates.compactMap { $0 }.first
    }

    private static func metadataTags(in properties: [String: Any]) -> [String] {
        let iptc = dictionary(for: kCGImagePropertyIPTCDictionary, in: properties)
        let keywords = stringArrayValue(for: kCGImagePropertyIPTCKeywords, in: iptc)
        let subject = stringArrayValue(named: "Subject", in: properties)

        return uniqueNormalizedValues(keywords + subject)
    }

    private static func metadataFields(from properties: [String: Any]) -> [ImportedPhotoMetadataField] {
        let interestingNames = [
            "caption",
            "description",
            "headline",
            "keyword",
            "object",
            "subject",
            "title"
        ]
        var fields: [ImportedPhotoMetadataField] = []
        collectFields(
            from: properties,
            source: "ImageIO",
            interestingNames: interestingNames,
            fields: &fields
        )
        return fields
    }

    private static func collectFields(
        from dictionary: [String: Any],
        source: String,
        interestingNames: [String],
        fields: inout [ImportedPhotoMetadataField]
    ) {
        for key in dictionary.keys.sorted() {
            guard let value = dictionary[key] else { continue }
            let nextSource = key.hasPrefix("{") ? key : source

            if let nested = value as? [String: Any] {
                collectFields(from: nested, source: nextSource, interestingNames: interestingNames, fields: &fields)
                continue
            }

            if let nested = value as? NSDictionary as? [String: Any] {
                collectFields(from: nested, source: nextSource, interestingNames: interestingNames, fields: &fields)
                continue
            }

            let lowercasedKey = key.lowercased()
            guard interestingNames.contains(where: { lowercasedKey.contains($0) }) else {
                continue
            }

            if let values = value as? [Any] {
                for string in values.compactMap(normalizedString) {
                    fields.append(ImportedPhotoMetadataField(source: source, name: key, value: string))
                }
            } else if let string = normalizedString(value) {
                fields.append(ImportedPhotoMetadataField(source: source, name: key, value: string))
            }
        }
    }

    private static func dictionary(for key: CFString, in properties: [String: Any]) -> [String: Any] {
        dictionary(named: key as String, in: properties)
    }

    private static func dictionary(named key: String, in properties: [String: Any]) -> [String: Any] {
        if let dictionary = properties[key] as? [String: Any] {
            return dictionary
        }

        if let dictionary = properties[key] as? NSDictionary as? [String: Any] {
            return dictionary
        }

        return [:]
    }

    private static func stringValue(for key: CFString, in dictionary: [String: Any]) -> String? {
        stringValue(named: key as String, in: dictionary)
    }

    private static func stringValue(named key: String, in dictionary: [String: Any]) -> String? {
        guard let value = dictionary[key] else {
            return nil
        }

        return normalizedString(value)
    }

    private static func stringArrayValue(for key: CFString, in dictionary: [String: Any]) -> [String] {
        stringArrayValue(named: key as String, in: dictionary)
    }

    private static func stringArrayValue(named key: String, in dictionary: [String: Any]) -> [String] {
        guard let value = dictionary[key] else {
            return []
        }

        if let array = value as? [Any] {
            return uniqueNormalizedValues(array.compactMap(normalizedString))
        }

        if let string = normalizedString(value) {
            return uniqueNormalizedValues(string.components(separatedBy: ","))
        }

        return []
    }

    private static func normalizedString(_ value: Any) -> String? {
        let string: String?
        if let value = value as? String {
            string = value
        } else if let value = value as? NSString {
            string = value as String
        } else {
            string = nil
        }

        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }

        return trimmed
    }

    private static func uniqueNormalizedValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }

            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }

        return result
    }
}
