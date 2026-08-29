import Foundation
import UIKit

/// Stages photo bytes in app-owned temporary storage for the existing attachment pipeline.
actor FoundationAttachmentPhotoStager: AttachmentPhotoStaging {
    private static let maxDimension: CGFloat = 2048
    private static let preferredMaxBytes = 6 * 1024 * 1024
    private static let jpegQualities: [CGFloat] = [0.78, 0.68, 0.56]

    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let now: @Sendable () -> Date
    private let identifier: @Sendable () -> UUID

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        now: @escaping @Sendable () -> Date = { Date() },
        identifier: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.now = now
        self.identifier = identifier
    }

    func stage(_ data: Data) async throws -> AttachmentSelection {
        try Task.checkCancellation()
        let filename = "cmux-remote-image-\(timestamp())-\(identifier().uuidString.lowercased()).jpg"
        let prepared = try await Self.preparedImage(data, filename: filename)
        let url = temporaryDirectory.appendingPathComponent(prepared.filename)
        try prepared.data.write(to: url, options: .atomic)
        return AttachmentSelection(url: url, declaredMIMEType: prepared.mimeType)
    }

    func remove(_ selection: AttachmentSelection) async {
        try? fileManager.removeItem(at: selection.url)
    }

    @MainActor
    private static func preparedImage(
        _ data: Data,
        filename: String
    ) throws -> (data: Data, filename: String, mimeType: String) {
        guard !data.isEmpty, let image = UIImage(data: data) else {
            throw AttachmentPhotoStagingError.invalidImage
        }
        let preparedImage = downscaled(image, maxDimension: maxDimension)
        var fallbackJPEG: Data?
        for quality in jpegQualities {
            guard let jpeg = preparedImage.jpegData(compressionQuality: quality), !jpeg.isEmpty else { continue }
            fallbackJPEG = jpeg
            if jpeg.count <= preferredMaxBytes {
                return (jpeg, filename, "image/jpeg")
            }
        }
        guard let fallbackJPEG else { throw AttachmentPhotoStagingError.encodingFailed }
        return (fallbackJPEG, filename, "image/jpeg")
    }

    @MainActor
    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > maxDimension, longestSide > 0 else { return image }
        let scale = maxDimension / longestSide
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now())
    }
}
