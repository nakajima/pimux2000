import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct ProcessedImageResult: Sendable {
	let mimeType: String
	let base64Data: String
	let predictedAttachmentID: String
	let previewData: Data
}

enum OutgoingImageProcessor {
	private static let maxLongEdge: CGFloat = 2000
	private static let maxBase64Characters = 4 * 1024 * 1024
	private static let initialJPEGQuality: CGFloat = 0.85
	private static let minimumJPEGQuality: CGFloat = 0.4
	private static let jpegQualityStep: CGFloat = 0.15
	private static let thumbnailMaxEdge: CGFloat = 200

	static func process(_ data: Data) async throws -> ProcessedImageResult {
		try await Task.detached {
			try processSync(data)
		}.value
	}

	private static func processSync(_ data: Data) throws -> ProcessedImageResult {
		let sourceFormat = detectFormat(data)
		guard let cgImage = createCGImage(from: data) else {
			throw ProcessingError.unreadableImage
		}

		let scaled = downscaleIfNeeded(cgImage)
		let (encodedData, mimeType) = try encode(scaled, sourceFormat: sourceFormat)
		let base64 = encodedData.base64EncodedString()

		guard base64.count <= maxBase64Characters else {
			throw ProcessingError.tooLarge
		}

		let preview = generateThumbnail(scaled)
		let attachmentID = ImageAttachmentID.predict(mimeType: mimeType, base64Data: base64)

		return ProcessedImageResult(
			mimeType: mimeType,
			base64Data: base64,
			predictedAttachmentID: attachmentID,
			previewData: preview
		)
	}

	// MARK: - Format detection

	private enum SourceFormat {
		case png
		case other
	}

	private static func detectFormat(_ data: Data) -> SourceFormat {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil),
		      let utType = CGImageSourceGetType(source) as? String
		else {
			return .other
		}

		if utType == UTType.png.identifier {
			return .png
		}

		return .other
	}

	// MARK: - Decoding

	private static func createCGImage(from data: Data) -> CGImage? {
		let options: [CFString: Any] = [
			kCGImageSourceShouldCache: false,
		]
		guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
			return nil
		}
		return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
	}

	// MARK: - Downscale

	private static func downscaleIfNeeded(_ image: CGImage) -> CGImage {
		let width = CGFloat(image.width)
		let height = CGFloat(image.height)
		let longEdge = max(width, height)

		guard longEdge > maxLongEdge else { return image }

		let scale = maxLongEdge / longEdge
		let newWidth = Int((width * scale).rounded())
		let newHeight = Int((height * scale).rounded())

		return resizedCGImage(image, width: newWidth, height: newHeight) ?? image
	}

	private static func resizedCGImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
		guard let context = CGContext(
			data: nil,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
		) else {
			return nil
		}

		context.interpolationQuality = .high
		context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
		return context.makeImage()
	}

	// MARK: - Encoding

	private static func encode(_ image: CGImage, sourceFormat: SourceFormat) throws -> (Data, String) {
		let uiImage = UIImage(cgImage: image)

		if case .png = sourceFormat {
			if let pngData = uiImage.pngData() {
				let base64Count = pngData.count * 4 / 3 + 4
				if base64Count <= maxBase64Characters {
					return (pngData, "image/png")
				}
				// PNG too large, fall through to JPEG
			}
		}

		// JPEG with progressive quality reduction
		var quality = initialJPEGQuality
		while quality >= minimumJPEGQuality {
			if let jpegData = uiImage.jpegData(compressionQuality: quality) {
				let base64Count = jpegData.count * 4 / 3 + 4
				if base64Count <= maxBase64Characters {
					return (jpegData, "image/jpeg")
				}
			}
			quality -= jpegQualityStep
		}

		// Last resort: downscale further and try lowest quality
		let halfWidth = image.width / 2
		let halfHeight = image.height / 2
		guard halfWidth > 0, halfHeight > 0,
		      let smaller = resizedCGImage(image, width: halfWidth, height: halfHeight),
		      let jpegData = UIImage(cgImage: smaller).jpegData(compressionQuality: minimumJPEGQuality)
		else {
			throw ProcessingError.tooLarge
		}

		let base64Count = jpegData.count * 4 / 3 + 4
		guard base64Count <= maxBase64Characters else {
			throw ProcessingError.tooLarge
		}

		return (jpegData, "image/jpeg")
	}

	// MARK: - Thumbnail

	private static func generateThumbnail(_ image: CGImage) -> Data {
		let width = CGFloat(image.width)
		let height = CGFloat(image.height)
		let longEdge = max(width, height)

		let thumbnail: CGImage
		if longEdge > thumbnailMaxEdge {
			let scale = thumbnailMaxEdge / longEdge
			let newWidth = max(1, Int((width * scale).rounded()))
			let newHeight = max(1, Int((height * scale).rounded()))
			thumbnail = resizedCGImage(image, width: newWidth, height: newHeight) ?? image
		} else {
			thumbnail = image
		}

		return UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.7) ?? Data()
	}

	// MARK: - Errors

	enum ProcessingError: LocalizedError {
		case unreadableImage
		case tooLarge

		var errorDescription: String? {
			switch self {
			case .unreadableImage:
				"This image couldn't be read."
			case .tooLarge:
				"This image is too large to send."
			}
		}
	}
}
