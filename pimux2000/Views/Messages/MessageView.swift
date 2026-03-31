import SwiftUI
import UIKit

// MARK: - PendingLocalMessageView

struct PendingLocalMessageView: View {
	let message: PendingLocalMessage

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "clock.fill")
				Text("You")
					.font(.caption)
					.fontWeight(.semibold)
					.textCase(.uppercase)
				Text("· Pending")
					.font(.caption)
			}
			.foregroundStyle(.secondary)

			if !message.previewImages.isEmpty {
				PendingImageStrip(images: message.previewImages)
					.opacity(0.55)
			}

			if !message.body.isEmpty {
				MessageMarkdownView(text: message.body, role: .user, title: "You")
					.opacity(0.55)
			}
		}
	}
}

private struct PendingImageStrip: View {
	let images: [PendingImagePreview]

	var body: some View {
		HStack(spacing: 6) {
			ForEach(images) { preview in
				if let uiImage = UIImage(data: preview.previewData) {
					Image(uiImage: uiImage)
						.resizable()
						.scaledToFill()
						.frame(width: 60, height: 60)
						.clipShape(RoundedRectangle(cornerRadius: 8))
				}
			}
		}
	}
}

// MARK: - Preview

#Preview("Pending message") {
	VStack(alignment: .leading, spacing: 16) {
		PendingLocalMessageView(
			message: PendingLocalMessage(
				body: "This message hasn't been confirmed yet.",
				images: [],
				confirmedUserMessageBaseline: 0
			)
		)
	}
	.padding()
}
