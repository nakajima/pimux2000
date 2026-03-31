import SwiftUI

struct UserMessageView: View {
	let messageInfo: MessageInfo

	private var message: Message { messageInfo.message }

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "person.fill")
				.foregroundStyle(.blue)
			VStack(alignment: .leading, spacing: 6) {
				MessageHeader(icon: "person.fill", label: "You", color: .blue)

				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					if block.type == "text", let text = block.text, !text.isEmpty {
						MessageMarkdownView(text: text, role: .user, title: "You")
					}
				}
			}
		}
	}
}

#Preview {
	UserMessageView(
		messageInfo: MessageInfo(
			message: Message(piSessionID: 1, role: .user, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(messageID: 1, type: "text", text: "Hello, can you help me with this code?", toolCallName: nil, position: 0)
			]
		)
	)
	.padding()
}
