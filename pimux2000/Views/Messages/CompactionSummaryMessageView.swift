import SwiftUI

struct CompactionSummaryMessageView: View {
	let messageInfo: MessageInfo

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "archivebox.fill")
				.foregroundStyle(.brown)
			VStack(alignment: .leading, spacing: 6) {
				MessageHeader(icon: "archivebox.fill", label: "Summary", color: .brown)

				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					if let text = block.text, !text.isEmpty {
						MessageMarkdownView(text: text, role: .compactionSummary, title: "Summary")
					}
				}
			}
		}
	}
}

#Preview {
	CompactionSummaryMessageView(
		messageInfo: MessageInfo(
			message: Message(piSessionID: 1, role: .compactionSummary, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(messageID: 1, type: "text", text: "Earlier setup discussion was compacted into a shorter summary.", toolCallName: nil, position: 0)
			]
		)
	)
	.padding()
}
