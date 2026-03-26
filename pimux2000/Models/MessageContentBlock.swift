import Foundation
import GRDB

struct MessageContentBlock: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable, Sendable {
	static nonisolated let databaseTableName = "messageContentBlocks"

	var id: Int64?
	var messageID: Int64
	var type: String
	var text: String?
	var toolCallName: String?
	var position: Int

	nonisolated init(id: Int64? = nil, messageID: Int64, type: String, text: String?, toolCallName: String?, position: Int) {
		self.id = id
		self.messageID = messageID
		self.type = type
		self.text = text
		self.toolCallName = toolCallName
		self.position = position
	}

	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}
}
