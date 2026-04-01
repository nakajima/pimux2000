import Nuke
import NukeUI
import SwiftUI

struct InlineDataImageView: View {
	let id: String
	let data: Data
	var size = PimuxImageLoading.inlineThumbnailSize
	var cornerRadius: CGFloat = 8
	var contentMode: ContentMode = .fill

	private var imageRequest: ImageRequest {
		PimuxImageLoading.inlineDataImageRequest(
			id: id,
			data: data,
			size: size,
			contentMode: contentMode
		)
	}

	var body: some View {
		LazyImage(request: imageRequest) { state in
			if let image = state.image {
				image
					.resizable()
					.aspectRatio(contentMode: contentMode)
					.frame(width: size.width, height: size.height)
					.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
			} else if state.error != nil {
				placeholder(systemImage: "exclamationmark.triangle")
			} else {
				placeholder(systemImage: "photo")
			}
		}
		.pipeline(PimuxImageLoading.sharedPipeline)
	}

	private func placeholder(systemImage: String) -> some View {
		RoundedRectangle(cornerRadius: cornerRadius)
			.fill(.quaternary)
			.frame(width: size.width, height: size.height)
			.overlay {
				Image(systemName: systemImage)
					.foregroundStyle(.secondary)
			}
	}
}

#Preview {
	let imageURL = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.deletingLastPathComponent()
		.appendingPathComponent("Preview Content", isDirectory: true)
		.appendingPathComponent("preview-image.png")
	let imageData = (try? Data(contentsOf: imageURL)) ?? Data()

	InlineDataImageView(id: "preview", data: imageData)
		.padding()
}
