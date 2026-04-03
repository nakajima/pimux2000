import SwiftUI

struct OtherMessageView: View {
	let messageInfo: MessageInfo
	let roleValue: String

	private var message: Message { messageInfo.message }

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "ellipsis.circle")
				.foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 6) {
				MessageHeader(icon: "ellipsis.circle", label: roleValue, color: .secondary)

				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					if let text = block.text, !text.isEmpty {
						MessageMarkdownView(text: text, role: .other(roleValue), title: roleValue)
					}
				}
			}
		}
	}
}

#Preview {
	OtherMessageView(
		messageInfo: MessageInfo(
			message: Message(piSessionID: 1, role: .other("systemNote"), toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(messageID: 1, type: "text", text: "Unknown roles render with fallback styling.", toolCallName: nil, position: 0),
			]
		),
		roleValue: "systemNote"
	)
	.padding()
}
