import SwiftUI

// MARK: - PendingLocalMessageView

struct PendingLocalMessageView: View {
	let message: PendingLocalMessage

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "person.fill")
				.foregroundStyle(.blue)
			VStack(alignment: .leading, spacing: 6) {
				HStack(spacing: 6) {
					MessageHeader(icon: "person.fill", label: "You", color: .blue)
					Text("· Pending")
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				if !message.previewImages.isEmpty {
					PendingImageStrip(images: message.previewImages)
				}

				if !message.body.isEmpty {
					MessageMarkdownView(text: message.body, role: .user, title: "You")
				}
			}
		}
		.opacity(0.55)
	}
}

private struct PendingImageStrip: View {
	let images: [PendingImagePreview]

	var body: some View {
		HStack(spacing: 6) {
			ForEach(images) { preview in
				InlineDataImageView(id: preview.id.uuidString, data: preview.previewData)
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
