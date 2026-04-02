import Foundation
import GRDB

struct Message: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable, Sendable {
	static nonisolated let databaseTableName = "messages"
	static nonisolated let contentBlocks = hasMany(MessageContentBlock.self)

	var id: Int64?
	var piSessionID: Int64
	var serverMessageID: Int?
	var role: Role
	var toolName: String?
	var position: Int
	var createdAt: Date

	nonisolated init(id: Int64? = nil, piSessionID: Int64, serverMessageID: Int? = nil, role: Role, toolName: String?, position: Int, createdAt: Date) {
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
			case .other(let value): value
			}
		}
	}
}

extension Message.Role: nonisolated Equatable {
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.rawString == rhs.rawString
	}
}

extension Message.Role: nonisolated Hashable {
	func hash(into hasher: inout Hasher) {
		hasher.combine(rawString)
	}
}

extension Message.Role: Codable {
	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		self.init(try container.decode(String.self))
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawString)
	}
}

extension Message.Role: DatabaseValueConvertible {
	var databaseValue: DatabaseValue {
		rawString.databaseValue
	}

	static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Message.Role? {
		guard let string = String.fromDatabaseValue(dbValue) else { return nil }
		return Message.Role(string)
	}
}
