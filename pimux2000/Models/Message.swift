import Foundation
import GRDB

nonisolated struct Message: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable, Sendable {
	static let databaseTableName = "messages"
	static let contentBlocks = hasMany(MessageContentBlock.self)

	var id: Int64?
	var piSessionID: Int64
	var serverMessageID: String?
	var role: Role
	var toolName: String?
	var position: Int
	var createdAt: Date

	nonisolated init(id: Int64? = nil, piSessionID: Int64, serverMessageID: String? = nil, role: Role, toolName: String?, position: Int, createdAt: Date) {
		self.id = id
		self.piSessionID = piSessionID
		self.serverMessageID = serverMessageID
		self.role = role
		self.toolName = toolName
		self.position = position
		self.createdAt = createdAt
	}

	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}
}

// MARK: - Role

extension Message {
	enum Role: Sendable {
		case user
		case assistant
		case toolResult
		case bashExecution
		case custom
		case branchSummary
		case compactionSummary
		case other(String)

		nonisolated init(_ rawString: String) {
			switch rawString {
			case "user": self = .user
			case "assistant": self = .assistant
			case "toolResult": self = .toolResult
			case "bashExecution": self = .bashExecution
			case "custom": self = .custom
			case "branchSummary": self = .branchSummary
			case "compactionSummary": self = .compactionSummary
			default: self = .other(rawString)
			}
		}

		nonisolated var rawString: String {
			switch self {
			case .user: "user"
			case .assistant: "assistant"
			case .toolResult: "toolResult"
			case .bashExecution: "bashExecution"
			case .custom: "custom"
			case .branchSummary: "branchSummary"
			case .compactionSummary: "compactionSummary"
			case let .other(value): value
			}
		}
	}
}

nonisolated extension Message.Role: Equatable {
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.rawString == rhs.rawString
	}
}

nonisolated extension Message.Role: Hashable {
	func hash(into hasher: inout Hasher) {
		hasher.combine(rawString)
	}
}

nonisolated extension Message.Role: Codable {
	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		try self.init(container.decode(String.self))
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawString)
	}
}

nonisolated extension Message.Role: DatabaseValueConvertible {
	var databaseValue: DatabaseValue {
		rawString.databaseValue
	}

	static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Message.Role? {
		guard let string = String.fromDatabaseValue(dbValue) else { return nil }
		return Message.Role(string)
	}
}
