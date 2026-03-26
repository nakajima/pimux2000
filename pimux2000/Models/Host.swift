import Foundation
import GRDB
import GRDBQuery
import SwiftUI

struct Host: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
	static let databaseTableName = "hosts"

	var id: Int64?
	var sshTarget: String
	var createdAt: Date
	var updatedAt: Date

	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}
}
