import SwiftUI

struct BashExecutionMessageView: View {
	let messageInfo: MessageInfo

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "terminal.fill")
				.foregroundStyle(.teal)
			VStack(alignment: .leading, spacing: 6) {
				MessageHeader(icon: "terminal.fill", label: "Bash", color: .teal)

				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					if block.type == "text", let text = block.text, !text.isEmpty {
						MessageMarkdownView(text: text, role: .bashExecution, title: "Bash")
					}
				}
			}
		}
	}
}

#Preview {
	BashExecutionMessageView(
		messageInfo: MessageInfo(
			message: Message(piSessionID: 1, role: .bashExecution, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(messageID: 1, type: "text", text: "$ echo hello\nhello", toolCallName: nil, position: 0)
			]
		)
	)
	.padding()
}
