import Foundation

struct PendingLocalMessage: Identifiable, Equatable {
	let id: UUID
	let body: String
	let normalizedBody: String
	let confirmedUserMessageBaseline: Int

	init(id: UUID = UUID(), body: String, confirmedUserMessageBaseline: Int) {
		self.id = id
		self.body = body
		self.normalizedBody = normalizedPendingMessageBody(body)
		self.confirmedUserMessageBaseline = confirmedUserMessageBaseline
	}
}

func pendingMessagesAwaitingConfirmation(
	_ pendingMessages: [PendingLocalMessage],
	confirmedMessages: [PimuxTranscriptMessage]
) -> [PendingLocalMessage] {
	let confirmedUserBodies = confirmedMessages
		.filter { Message.Role($0.role) == .user }
		.map { normalizedPendingMessageBody($0.body) }

	var nextConfirmedSearchStart = 0
	var remainingPendingMessages: [PendingLocalMessage] = []

	for pendingMessage in pendingMessages {
		let searchStart = max(nextConfirmedSearchStart, pendingMessage.confirmedUserMessageBaseline)
		guard searchStart < confirmedUserBodies.count else {
			remainingPendingMessages.append(pendingMessage)
			continue
		}

		if let matchIndex = confirmedUserBodies[searchStart...].firstIndex(of: pendingMessage.normalizedBody) {
			nextConfirmedSearchStart = matchIndex + 1
		} else {
			remainingPendingMessages.append(pendingMessage)
		}
	}

	return remainingPendingMessages
}

func normalizedPendingMessageBody(_ text: String) -> String {
	text
		.replacingOccurrences(of: "\r\n", with: "\n")
		.replacingOccurrences(of: "\r", with: "\n")
		.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
}
