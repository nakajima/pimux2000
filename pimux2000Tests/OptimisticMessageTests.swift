import Foundation
@testable import pimux2000
import Testing

struct OptimisticMessageTests {
	@Test
	func duplicateBodiesRequireNewOccurrenceAfterBaseline() {
		let pending = PendingLocalMessage(body: "hello", confirmedUserMessageBaseline: 1)

		let stillPending = pendingMessagesAwaitingConfirmation(
			[pending],
			confirmedMessages: [userMessage("hello")]
		)
		#expect(stillPending == [pending])

		let confirmed = pendingMessagesAwaitingConfirmation(
			[pending],
			confirmedMessages: [userMessage("hello"), userMessage("hello")]
		)
		#expect(confirmed.isEmpty)
	}

	@Test
	func confirmsPendingMessagesInSendOrder() {
		let first = PendingLocalMessage(body: "first", confirmedUserMessageBaseline: 2)
		let second = PendingLocalMessage(body: "second", confirmedUserMessageBaseline: 2)

		let afterFirst = pendingMessagesAwaitingConfirmation(
			[first, second],
			confirmedMessages: [userMessage("older-1"), userMessage("older-2"), userMessage("first")]
		)
		#expect(afterFirst == [second])

		let afterBoth = pendingMessagesAwaitingConfirmation(
			[first, second],
			confirmedMessages: [
				userMessage("older-1"),
				userMessage("older-2"),
				userMessage("first"),
				userMessage("second")
			]
		)
		#expect(afterBoth.isEmpty)
	}

	@Test
	func normalizesLineEndingsWhenReconciling() {
		let pending = PendingLocalMessage(body: "hello\r\nworld", confirmedUserMessageBaseline: 0)

		let remaining = pendingMessagesAwaitingConfirmation(
			[pending],
			confirmedMessages: [userMessage("hello\nworld")]
		)

		#expect(remaining.isEmpty)
		#expect(normalizedPendingMessageBody("hello\r\nworld") == "hello\nworld")
	}

	// MARK: - Image-aware reconciliation

	@Test
	func confirmsImageOnlyMessage() {
		let pending = pendingImageMessage(attachmentIDs: ["img-abc"])

		let stillPending = pendingMessagesAwaitingConfirmation(
			[pending],
			confirmedMessages: [userMessage("[Image]")]
		)
		#expect(stillPending == [pending])

		let confirmed = pendingMessagesAwaitingConfirmation(
			[pending],
			confirmedMessages: [userMessageWithImages(attachmentIDs: ["img-abc"])]
		)
		#expect(confirmed.isEmpty)
	}

	@Test
	func confirmsTextAndImageMessage() {
		let pending = pendingImageMessage("check this", attachmentIDs: ["img-abc"])

		let confirmed = pendingMessagesAwaitingConfirmation(
			[pending],
			confirmedMessages: [userMessageWithImages("check this", attachmentIDs: ["img-abc"])]
		)
		#expect(confirmed.isEmpty)
	}

	@Test
	func sameCaptionDifferentImagesDontFalseMatch() {
		let pending = pendingImageMessage("look at this", attachmentIDs: ["img-abc"])

		let stillPending = pendingMessagesAwaitingConfirmation(
			[pending],
			confirmedMessages: [userMessageWithImages("look at this", attachmentIDs: ["img-xyz"])]
		)
		#expect(stillPending == [pending])
	}

	@Test
	func confirmsMultipleImagesSentInOrder() {
		let first = pendingImageMessage(attachmentIDs: ["img-aaa"])
		let second = pendingImageMessage(attachmentIDs: ["img-bbb", "img-ccc"])

		let afterFirst = pendingMessagesAwaitingConfirmation(
			[first, second],
			confirmedMessages: [userMessageWithImages(attachmentIDs: ["img-aaa"])]
		)
		#expect(afterFirst == [second])

		let afterBoth = pendingMessagesAwaitingConfirmation(
			[first, second],
			confirmedMessages: [
				userMessageWithImages(attachmentIDs: ["img-aaa"]),
				userMessageWithImages(attachmentIDs: ["img-bbb", "img-ccc"]),
			]
		)
		#expect(afterBoth.isEmpty)
	}

	// MARK: - Helpers

	private func userMessage(_ body: String) -> PimuxTranscriptMessage {
		PimuxTranscriptMessage(createdAt: Date(), role: "user", body: body)
	}

	private func userMessageWithImages(_ body: String = "", attachmentIDs: [String]) -> PimuxTranscriptMessage {
		var blocks: [PimuxTranscriptMessageBlock] = []
		if !body.isEmpty {
			blocks.append(PimuxTranscriptMessageBlock(type: "text", text: body, toolCallName: nil))
		}
		for id in attachmentIDs {
			blocks.append(PimuxTranscriptMessageBlock(type: "image", text: nil, toolCallName: nil, mimeType: "image/png", attachmentId: id))
		}
		let displayBody = body.isEmpty ? "[Image]" : body
		return PimuxTranscriptMessage(createdAt: Date(), role: "user", body: displayBody, blocks: blocks)
	}

	private func pendingImageMessage(_ body: String = "", attachmentIDs: [String], baseline: Int = 0) -> PendingLocalMessage {
		let images = attachmentIDs.map { id -> ComposerImage in
			var image = ComposerImage(source: .library)
			image.predictedAttachmentID = id
			return image
		}
		return PendingLocalMessage(body: body, images: images, confirmedUserMessageBaseline: baseline)
	}
}
