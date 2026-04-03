import Foundation
@testable import pimux2000
import Testing

struct TranscriptMessageTests {
	@Test
	func confirmedMessageIDMatchesMessageInfo() {
		let info = MessageInfo(
			message: Message(id: 1, piSessionID: 1, role: .user, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(id: 1, messageID: 1, type: "text", text: "hello", toolCallName: nil, position: 0),
			]
		)
		let msg = TranscriptMessage.confirmed(info)
		#expect(msg.id == info.id)
	}

	@Test
	func pendingMessageIDIncludesPrefix() {
		let pending = PendingLocalMessage(body: "test", confirmedUserMessageBaseline: 0)
		let msg = TranscriptMessage.pending(pending)
		#expect(msg.id.hasPrefix("pending-"))
	}

	@Test
	func fingerprintChangesWhenContentChanges() {
		let info1 = MessageInfo(
			message: Message(id: 1, piSessionID: 1, role: .assistant, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(id: 1, messageID: 1, type: "text", text: "version 1", toolCallName: nil, position: 0),
			]
		)
		let info2 = MessageInfo(
			message: Message(id: 1, piSessionID: 1, role: .assistant, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(id: 1, messageID: 1, type: "text", text: "version 2", toolCallName: nil, position: 0),
			]
		)
		let fp1 = TranscriptMessage.confirmed(info1).fingerprint
		let fp2 = TranscriptMessage.confirmed(info2).fingerprint
		#expect(fp1 != fp2)
	}

	@Test
	func fingerprintStableForSameContent() {
		let info = MessageInfo(
			message: Message(id: 1, piSessionID: 1, role: .user, toolName: nil, position: 0, createdAt: Date()),
			contentBlocks: [
				MessageContentBlock(id: 1, messageID: 1, type: "text", text: "same", toolCallName: nil, position: 0),
			]
		)
		let fp1 = TranscriptMessage.confirmed(info).fingerprint
		let fp2 = TranscriptMessage.confirmed(info).fingerprint
		#expect(fp1 == fp2)
	}
}
