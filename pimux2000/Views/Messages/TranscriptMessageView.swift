import SwiftUI

struct TranscriptMessageView: View {
	let messageInfo: MessageInfo
	let sessionID: String
	let serverURL: String?

	var body: some View {
		switch messageInfo.message.role {
		case .user:
			UserMessageView(messageInfo: messageInfo)
		case .assistant:
			AssistantMessageView(messageInfo: messageInfo, sessionID: sessionID, serverURL: serverURL)
		case .toolResult:
			ToolResultMessageView(messageInfo: messageInfo)
		case .bashExecution:
			BashExecutionMessageView(messageInfo: messageInfo)
		case .custom:
			CustomMessageView(messageInfo: messageInfo)
		case .branchSummary:
			BranchSummaryMessageView(messageInfo: messageInfo)
		case .compactionSummary:
			CompactionSummaryMessageView(messageInfo: messageInfo)
		case let .other(value):
			OtherMessageView(messageInfo: messageInfo, roleValue: value)
		}
	}
}

#Preview("All roles") {
	ScrollView {
		VStack(alignment: .leading, spacing: 16) {
			TranscriptMessageView(
				messageInfo: MessageInfo(
					message: Message(piSessionID: 1, role: .user, toolName: nil, position: 0, createdAt: Date()),
					contentBlocks: [
						MessageContentBlock(messageID: 1, type: "text", text: "Hello, can you help me?", toolCallName: nil, position: 0),
					]
				),
				sessionID: "preview",
				serverURL: nil
			)
			TranscriptMessageView(
				messageInfo: MessageInfo(
					message: Message(piSessionID: 1, role: .assistant, toolName: nil, position: 1, createdAt: Date()),
					contentBlocks: [
						MessageContentBlock(messageID: 2, type: "text", text: "Of course! What do you need help with?", toolCallName: nil, position: 0),
					]
				),
				sessionID: "preview",
				serverURL: nil
			)
			TranscriptMessageView(
				messageInfo: MessageInfo(
					message: Message(piSessionID: 1, role: .toolResult, toolName: "read", position: 2, createdAt: Date()),
					contentBlocks: [
						MessageContentBlock(messageID: 3, type: "text", text: "File contents returned successfully.", toolCallName: nil, position: 0),
					]
				),
				sessionID: "preview",
				serverURL: nil
			)
			TranscriptMessageView(
				messageInfo: MessageInfo(
					message: Message(piSessionID: 1, role: .bashExecution, toolName: nil, position: 3, createdAt: Date()),
					contentBlocks: [
						MessageContentBlock(messageID: 4, type: "text", text: "$ echo hello\nhello", toolCallName: nil, position: 0),
					]
				),
				sessionID: "preview",
				serverURL: nil
			)
		}
		.padding()
	}
}
