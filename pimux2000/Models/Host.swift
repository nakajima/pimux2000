import Foundation
import GRDB

struct Host: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
	static let databaseTableName = "hosts"

	var id: Int64?
	var location: String
	var createdAt: Date
	var updatedAt: Date

	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}

	var displayName: String {
		location
	}
}
