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
			fingerprint.combine(message.toolCallID)
			fingerprint.combine(message.position)
			for block in contentBlocks {
				fingerprint.combine(block.position)
				fingerprint.combine(block.type)
				fingerprint.combine(block.text)
				fingerprint.combine(block.toolCallName)
				fingerprint.combine(block.toolCallID)
				fingerprint.combine(block.mimeType)
				fingerprint.combine(block.attachmentID)
			}
		}
	}
}

struct MessagesRequest: ValueObservationQueryable {
	static let queryableOptions = QueryableOptions.async
	static var defaultValue: [MessageInfo] { [] }

	var sessionID: String
	var latestMessageCount: Int? = nil
	var oldestIncludedPosition: Int? = nil

	func fetch(_ db: Database) throws -> [MessageInfo] {
		guard let currentSession = try PiSession
			.filter(Column("sessionID") == sessionID)
			.fetchOne(db),
			let piSessionID = currentSession.id else { return [] }

		let baseRequest = Message
			.filter(Column("piSessionID") == piSessionID)

		let messages: [Message]
		if let oldestIncludedPosition {
			messages = try baseRequest
				.filter(Column("position") >= oldestIncludedPosition)
				.order(Column("position").asc)
				.fetchAll(db)
		} else if let latestMessageCount {
			messages = try Array(
				baseRequest
					.order(Column("position").desc)
					.limit(latestMessageCount)
					.fetchAll(db)
					.reversed()
			)
		} else {
			messages = try baseRequest
				.order(Column("position").asc)
				.fetchAll(db)
		}

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

struct SessionMessageStats: Equatable {
	let totalCount: Int
	let confirmedUserMessageCount: Int
}

struct SessionMessageStatsRequest: ValueObservationQueryable {
	static var defaultValue: SessionMessageStats {
		SessionMessageStats(totalCount: 0, confirmedUserMessageCount: 0)
	}

	let sessionID: String

	func fetch(_ db: Database) throws -> SessionMessageStats {
		guard let currentSession = try PiSession
			.filter(Column("sessionID") == sessionID)
			.fetchOne(db),
			let piSessionID = currentSession.id else {
			return SessionMessageStats(totalCount: 0, confirmedUserMessageCount: 0)
		}

		let totalCount = try Message
			.filter(Column("piSessionID") == piSessionID)
			.fetchCount(db)
		let confirmedUserMessageCount = try Message
			.filter(Column("piSessionID") == piSessionID)
			.filter(Column("role") == Message.Role.user)
			.fetchCount(db)

		return SessionMessageStats(
			totalCount: totalCount,
			confirmedUserMessageCount: confirmedUserMessageCount
		)
	}
}
