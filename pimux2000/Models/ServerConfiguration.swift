import Foundation
import GRDB
import GRDBQuery

struct ServerConfiguration: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {
	static let databaseTableName = "serverConfigurations"

	var id: Int64?
	var serverURL: String
	var createdAt: Date
	var updatedAt: Date

	mutating func didInsert(_ inserted: InsertionSuccess) {
		id = inserted.rowID
	}
}

struct CurrentServerConfigurationRequest: ValueObservationQueryable {
	static var defaultValue: ServerConfiguration? { nil }

	func fetch(_ db: Database) throws -> ServerConfiguration? {
		try ServerConfiguration
			.order(Column("updatedAt").desc)
			.fetchOne(db)
	}
}
