import SwiftUI

struct UserMessageView: View {
	@Environment(\.pimuxServerClient) private var pimuxServerClient

	let messageInfo: MessageInfo
	let sessionID: String

	private var message: Message { messageInfo.message }

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "person.fill")
				.foregroundStyle(.blue)
			VStack(alignment: .leading, spacing: 6) {
				MessageHeader(icon: "person.fill", label: "You", color: .blue)

				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					switch block.type {
					case "text":
						if let text = block.text, !text.isEmpty {
							MessageMarkdownView(text: text, role: .user, title: "You")
						}
					case "image":
						if let url = attachmentURL(for: block) {
							TranscriptImageView(
								url: url,
								sessionID: sessionID,
								mimeType: block.mimeType,
								attachmentID: block.attachmentID
							)
						}
					default:
						EmptyView()
					}
				}
			}
		}
	}

	private func attachmentURL(for block: MessageContentBlock) -> URL? {
		guard block.type == "image",
		      let attachmentID = block.attachmentID,
		      !attachmentID.isEmpty
		else {
			return nil
		}

		if let cachedURL = AttachmentStore.existingFileURL(
			sessionID: sessionID,
			attachmentID: attachmentID,
			mimeType: block.mimeType
		) {
			return cachedURL
		}

		guard let pimuxServerClient else { return nil }
		return pimuxServerClient.attachmentURL(sessionID: sessionID, attachmentID: attachmentID)
	}
}

#Preview {
	UserMessageView(
		messageInfo: MessageInfo(
			message: Message(piSessionID: 1, role: .user, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(messageID: 1, type: "text", text: "Hello, can you help me with this code?", toolCallName: nil, position: 0),
			]
		),
		sessionID: "preview"
	)
	.padding()
}
