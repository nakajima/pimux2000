import SwiftUI

struct BranchSummaryMessageView: View {
	let messageInfo: MessageInfo

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: "arrow.triangle.branch")
				.foregroundStyle(.green)
			VStack(alignment: .leading, spacing: 6) {
				MessageHeader(icon: "arrow.triangle.branch", label: "Branch Summary", color: .green)

				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					if let text = block.text, !text.isEmpty {
						MessageMarkdownView(text: text, role: .branchSummary, title: "Branch Summary")
					}
				}
			}
		}
	}
}

#Preview {
	BranchSummaryMessageView(
		messageInfo: MessageInfo(
			message: Message(piSessionID: 1, role: .branchSummary, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(messageID: 1, type: "text", text: "Created branch `preview-message-fixtures` from `main` and staged the updated transcript preview data.", toolCallName: nil, position: 0),
			]
		)
	)
	.padding()
}
