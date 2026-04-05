import Foundation
import GRDB
import GRDBQuery

struct MessageInfo: Identifiable {
	let message: Message
	let contentBlocks: [MessageContentBlock]
	let contentFingerprint: UInt64
	var id: String {
		if let serverID = message.serverMessageID {
			return "\(message.piSessionID)-\(serverID)"
		}
		return "\(message.piSessionID)-p\(message.position)"
	}

	init(message: Message, contentBlocks: [MessageContentBlock]) {
		self.message = message
		self.contentBlocks = contentBlocks
		self.contentFingerprint = Self.makeContentFingerprint(message: message, contentBlocks: contentBlocks)
	}

	private static func makeContentFingerprint(message: Message, contentBlocks: [MessageContentBlock]) -> UInt64 {
		TranscriptFingerprint.make { fingerprint in
			fingerprint.combine(message.role.rawString)
			fingerprint.combine(message.toolName)
			fingerprint.combine(message.position)
			for block in contentBlocks {
				fingerprint.combine(block.position)
				fingerprint.combine(block.type)
				fingerprint.combine(block.text)
				fingerprint.combine(block.toolCallName)
				fingerprint.combine(block.mimeType)
				fingerprint.combine(block.attachmentID)
			}
		}
	}
}

struct MessagesRequest: ValueObservationQueryable {
	static var defaultValue: [MessageInfo] { [] }

	let sessionID: String

	func fetch(_ db: Database) throws -> [MessageInfo] {
		guard let currentSession = try PiSession
			.filter(Column("sessionID") == sessionID)
			.fetchOne(db),
			let piSessionID = currentSession.id else { return [] }

		let messages = try Message
			.filter(Column("piSessionID") == piSessionID)
			.order(Column("position").asc)
			.fetchAll(db)

		let messageIDs = messages.compactMap(\.id)
		guard !messageIDs.isEmpty else { return [] }

		let blocks = try MessageContentBlock
			.filter(messageIDs.contains(Column("messageID")))
			.order(Column("position").asc)
			.fetchAll(db)

		let blocksByMessage = Dictionary(grouping: blocks, by: \.messageID)
		let messageInfos = messages.map { message in
			MessageInfo(
				message: message,
				contentBlocks: blocksByMessage[message.id ?? -1] ?? []
			)
		}
		return deduplicatedMessages(messageInfos)
	}

	private func deduplicatedMessages(_ messages: [MessageInfo]) -> [MessageInfo] {
		guard messages.count > 1 else { return messages }

		var deduplicatedByID: [String: MessageInfo] = [:]
		deduplicatedByID.reserveCapacity(messages.count)

		for message in messages {
			guard let existing = deduplicatedByID[message.id] else {
				deduplicatedByID[message.id] = message
				continue
			}

			let existingRowID = existing.message.id ?? -1
			let candidateRowID = message.message.id ?? -1
			if message.message.position > existing.message.position
				|| (message.message.position == existing.message.position && candidateRowID > existingRowID)
			{
				deduplicatedByID[message.id] = message
			}
		}

		let deduplicatedMessages = deduplicatedByID.values.sorted { lhs, rhs in
			if lhs.message.position != rhs.message.position {
				return lhs.message.position < rhs.message.position
			}
			return (lhs.message.id ?? -1) < (rhs.message.id ?? -1)
		}

		if deduplicatedMessages.count != messages.count {
			print("Deduplicated \(messages.count - deduplicatedMessages.count) duplicate message(s) while fetching transcript for \(sessionID)")
		}

		return deduplicatedMessages
	}
}
