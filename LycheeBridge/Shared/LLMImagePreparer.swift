import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedLLMImage: Hashable {
    let sourcePhotoID: UUID
    let mimeType: String
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int

    var byteCount: Int {
        data.count
    }

    var base64EncodedString: String {
        data.base64EncodedString()
    }

    var base64DataURLString: String {
        "data:\(mimeType);base64,\(base64EncodedString)"
    }
}

enum LLMImagePreparationError: LocalizedError {
    case invalidOptions
    case unsupportedImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "The LLM preview image options are invalid."
        case .unsupportedImage:
            return "The selected photo could not be prepared for LLM analysis."
        case .encodingFailed:
            return "The LLM preview image could not be encoded."
        }
    }
}

enum LLMImagePreparer {
    struct Options: Codable, Hashable {
        var maxPixelDimension: Int = 768
        var jpegQuality: Double = 0.75

        func validated() throws -> Options {
            guard maxPixelDimension > 0,
                  jpegQuality > 0,
                  jpegQuality <= 1 else {
                throw LLMImagePreparationError.invalidOptions
            }

            return self
        }
    }

    static let defaultOptions = Options()

    static func prepare(photo: ImportedPhoto, options: Options = defaultOptions) throws -> PreparedLLMImage {
        try prepare(sourcePhotoID: photo.id, fileURL: photo.fileURL, options: options)
    }

    static func prepare(sourcePhotoID: UUID, fileURL: URL, options: Options = defaultOptions) throws -> PreparedLLMImage {
        let options = try options.validated()
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
            throw LLMImagePreparationError.unsupportedImage
        }

        return try prepare(sourcePhotoID: sourcePhotoID, imageSource: source, options: options)
    }

    static func prepare(sourcePhotoID: UUID, data: Data, options: Options = defaultOptions) throws -> PreparedLLMImage {
        let options = try options.validated()
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw LLMImagePreparationError.unsupportedImage
        }

        return try prepare(sourcePhotoID: sourcePhotoID, imageSource: source, options: options)
    }

    private static func prepare(sourcePhotoID: UUID, imageSource source: CGImageSource, options: Options) throws -> PreparedLLMImage {
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: options.maxPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw LLMImagePreparationError.unsupportedImage
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw LLMImagePreparationError.encodingFailed
        }

        let destinationProperties = [
            kCGImageDestinationLossyCompressionQuality: options.jpegQuality
        ] as CFDictionary

        CGImageDestinationAddImage(destination, thumbnail, destinationProperties)

        guard CGImageDestinationFinalize(destination) else {
            throw LLMImagePreparationError.encodingFailed
        }

        return PreparedLLMImage(
            sourcePhotoID: sourcePhotoID,
            mimeType: "image/jpeg",
            data: data as Data,
            pixelWidth: thumbnail.width,
            pixelHeight: thumbnail.height
        )
    }
}
