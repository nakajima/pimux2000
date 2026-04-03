import Nuke
import SwiftUI

enum PimuxImageLoading {
	static let transcriptImageSize = CGSize(width: 320, height: 240)
	static let inlineThumbnailSize = CGSize(width: 60, height: 60)

	static let sharedPipeline: ImagePipeline = makeSharedPipeline()

	static func configureSharedPipeline() {
		ImagePipeline.shared = sharedPipeline
	}

	static func transcriptImageRequest(url: URL) -> ImageRequest {
		ImageRequest(
			url: url,
			processors: [
				ImageProcessors.Resize(size: transcriptImageSize, contentMode: .aspectFit),
			]
		)
	}

	static func inlineDataImageRequest(
		id: String,
		data: Data,
		size: CGSize = inlineThumbnailSize,
		contentMode: ContentMode = .fill
	) -> ImageRequest {
		ImageRequest(
			id: "inline-data-\(id)",
			data: { data },
			processors: [
				ImageProcessors.Resize(
					size: size,
					contentMode: contentMode == .fill ? .aspectFill : .aspectFit,
					crop: contentMode == .fill
				),
			],
			options: [.disableDiskCache]
		)
	}

	private static func makeSharedPipeline() -> ImagePipeline {
		var configuration = ImagePipeline.Configuration.withURLCache
		configuration.isUsingPrepareForDisplay = true
		return ImagePipeline(configuration: configuration)
	}
}

extension PimuxImageLoading {
	struct TranscriptAttachment: Sendable {
		let sourceURL: URL
		let sessionID: String
		let attachmentID: String?
		let mimeType: String?

		var existingCachedFileURL: URL? {
			guard let attachmentID, !attachmentID.isEmpty else { return nil }
			return AttachmentStore.existingFileURL(
				sessionID: sessionID,
				attachmentID: attachmentID,
				mimeType: mimeType
			)
		}

		var cacheTaskID: String {
			"\(sessionID)|\(attachmentID ?? "no-attachment")|\(sourceURL.absoluteString)"
		}

		func imageRequest(cachedFileURL: URL? = nil) -> ImageRequest {
			PimuxImageLoading.transcriptImageRequest(
				url: cachedFileURL ?? existingCachedFileURL ?? sourceURL
			)
		}

		func cacheIfNeeded() async throws -> URL? {
			guard !sourceURL.isFileURL,
			      let attachmentID,
			      !attachmentID.isEmpty
			else {
				return existingCachedFileURL
			}

			if let existingCachedFileURL {
				return existingCachedFileURL
			}

			let data = try await fetchRemoteData()
			guard !Task.isCancelled else { return nil }
			return try AttachmentStore.store(
				data: data,
				sessionID: sessionID,
				attachmentID: attachmentID,
				mimeType: mimeType
			)
		}

		func makeQuickLookPreviewURL(cachedFileURL: URL? = nil) async throws -> URL {
			let data = try await imageData(cachedFileURL: cachedFileURL)
			let tempURL = FileManager.default.temporaryDirectory
				.appendingPathComponent("pimux-preview-\(UUID().uuidString)")
				.appendingPathExtension(AttachmentStore.fileExtension(for: mimeType))
			try data.write(to: tempURL)
			return tempURL
		}

		private func imageData(cachedFileURL: URL?) async throws -> Data {
			if let cachedFileURL = cachedFileURL ?? existingCachedFileURL {
				return try await Self.readData(from: cachedFileURL)
			}

			if sourceURL.isFileURL {
				return try await Self.readData(from: sourceURL)
			}

			let data = try await fetchRemoteData()
			if let attachmentID, !attachmentID.isEmpty {
				_ = try? AttachmentStore.store(
					data: data,
					sessionID: sessionID,
					attachmentID: attachmentID,
					mimeType: mimeType
				)
			}
			return data
		}

		private func fetchRemoteData() async throws -> Data {
			let (data, _) = try await PimuxImageLoading.sharedPipeline.data(for: ImageRequest(url: sourceURL))
			return data
		}

		private static func readData(from url: URL) async throws -> Data {
			try await Task.detached(priority: .userInitiated) {
				try Data(contentsOf: url)
			}.value
		}
	}
}
