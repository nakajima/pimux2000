import Nuke
import NukeUI
import QuickLook
import SwiftUI

struct TranscriptImageView: View {
	let url: URL
	let sessionID: String
	let mimeType: String?
	let attachmentID: String?

	@State private var cachedFileURL: URL?
	@State private var quickLookURL: URL?
	@State private var isPreviewLoading = false

	private var attachment: PimuxImageLoading.TranscriptAttachment {
		.init(sourceURL: url, sessionID: sessionID, attachmentID: attachmentID, mimeType: mimeType)
	}

	private var imageRequest: ImageRequest {
		attachment.imageRequest(cachedFileURL: cachedFileURL)
	}

	var body: some View {
		LazyImage(request: imageRequest) { state in
			if let image = state.image {
				imageContent(image)
			} else if state.error != nil {
				placeholder(label: "Couldn't load image", systemImage: "exclamationmark.triangle")
			} else {
				placeholder(label: "Loading image…", systemImage: "photo")
			}
		}
		.pipeline(PimuxImageLoading.sharedPipeline)
		.quickLookPreview($quickLookURL)
		.task(id: attachment.cacheTaskID) {
			await cacheAttachmentIfNeeded()
		}
		.onDisappear { cleanupTempFile() }
	}

	private func imageContent(_ image: Image) -> some View {
		image
			.resizable()
			.scaledToFit()
			.frame(
				maxWidth: PimuxImageLoading.transcriptImageSize.width,
				maxHeight: PimuxImageLoading.transcriptImageSize.height,
				alignment: .leading
			)
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.overlay(alignment: .center) {
				if isPreviewLoading {
					ProgressView()
						.padding(8)
						.background(.thinMaterial, in: Circle())
				}
			}
			.onTapGesture {
				Task { await openQuickLook() }
			}
	}

	private func openQuickLook() async {
		guard !isPreviewLoading else { return }
		isPreviewLoading = true
		defer { isPreviewLoading = false }

		do {
			cleanupTempFile()
			quickLookURL = try await attachment.makeQuickLookPreviewURL(cachedFileURL: cachedFileURL)
		} catch {
			print("Failed to download image for QuickLook preview: \(error)")
		}
	}

	private func cleanupTempFile() {
		if let url = quickLookURL {
			try? FileManager.default.removeItem(at: url)
			quickLookURL = nil
		}
	}

	private func cacheAttachmentIfNeeded() async {
		do {
			cachedFileURL = try await attachment.cacheIfNeeded()
		} catch {
			print("Failed to cache image attachment: \(error)")
		}
	}

	@ViewBuilder
	private func placeholder(label: String, systemImage: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Label(label, systemImage: systemImage)
				.font(chatFont(style: .callout))
				.foregroundStyle(.secondary)

			if let mimeType, !mimeType.isEmpty {
				Text(verbatim: mimeType)
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			if let attachmentID, !attachmentID.isEmpty {
				Text(verbatim: attachmentID)
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
		.padding(.vertical, 8)
		.padding(.horizontal, 10)
		.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
	}
}

#Preview("Transcript image") {
	let sessionID = "preview"
	let attachmentID = "preview-img"
	let _ = PreviewAttachmentFixture.installImageAttachment(sessionID: sessionID, attachmentID: attachmentID)

	TranscriptImageView(
		url: URL(string: "https://example.com/sessions/\(sessionID)/attachments/\(attachmentID)")!,
		sessionID: sessionID,
		mimeType: "image/png",
		attachmentID: attachmentID
	)
	.padding()
}
