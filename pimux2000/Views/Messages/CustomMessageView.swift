import SwiftUI

struct CustomMessageView: View {
	let messageInfo: MessageInfo

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "square.stack.3d.up.fill")
				.foregroundStyle(.indigo)
			VStack(alignment: .leading, spacing: 6) {
				MessageHeader(icon: "square.stack.3d.up.fill", label: "Custom", color: .indigo)

				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					if let text = block.text, !text.isEmpty {
						MessageMarkdownView(text: text, role: .custom, title: "Custom")
					}
				}
			}
		}
	}
}

#Preview {
	CustomMessageView(
		messageInfo: MessageInfo(
			message: Message(piSessionID: 1, role: .custom, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(messageID: 1, type: "other", text: "Custom extension note: the live stream briefly detached.", toolCallName: nil, position: 0)
			]
		)
	)
	.padding()
}
