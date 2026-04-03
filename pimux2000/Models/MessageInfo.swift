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
		return messages.map { message in
			MessageInfo(
				message: message,
				contentBlocks: blocksByMessage[message.id ?? -1] ?? []
			)
		}
	}
}
