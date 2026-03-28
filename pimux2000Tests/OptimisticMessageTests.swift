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

	private func userMessage(_ body: String) -> PimuxTranscriptMessage {
		PimuxTranscriptMessage(createdAt: Date(), role: "user", body: body)
	}
}
