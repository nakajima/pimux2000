import SwiftUI

struct ToolResultMessageView: View {
	let messageInfo: MessageInfo

	private var message: Message { messageInfo.message }

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "wrench.fill")
				.foregroundStyle(.orange)
			VStack(alignment: .leading, spacing: 6) {
				MessageHeader(icon: "wrench.fill", label: "Tool Result", color: .orange, toolName: message.toolName)

				VStack {
					ForEach(messageInfo.contentBlocks, id: \.position) { block in
						if block.type == "text", let text = block.text, !text.isEmpty {
							Text(verbatim: text)
								.font(.caption)
								.fontDesign(.monospaced)
						}
					}
				}
				
			}
		}
	}

	private var messageTitle: String {
		if let toolName = message.toolName {
			return "Tool Result · \(toolName)"
		}
		return "Tool Result"
	}
}

#Preview {
	ToolResultMessageView(
		messageInfo: MessageInfo(
			message: Message(piSessionID: 1, role: .toolResult, toolName: "read", position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(messageID: 1, type: "text", text: "File contents returned successfully.", toolCallName: nil, position: 0)
			]
		)
	)
	.padding()
}
