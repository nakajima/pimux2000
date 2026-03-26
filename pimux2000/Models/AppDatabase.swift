import Foundation
import GRDB
import SwiftUI

struct AppDatabase {
	let dbQueue: DatabaseQueue

	init(dbQueue: DatabaseQueue) throws {
		self.dbQueue = dbQueue
		try Self.migrator.migrate(dbQueue)
	}

	// MARK: - Schema

	static var migrator: DatabaseMigrator {
		var migrator = DatabaseMigrator()

		#if DEBUG
		migrator.eraseDatabaseOnSchemaChange = true
		#endif

		migrator.registerMigration("createHosts") { db in
			try db.create(table: "hosts") { t in
				t.autoIncrementedPrimaryKey("id")
				t.column("sshTarget", .text).notNull().unique()
				t.column("createdAt", .datetime).notNull()
				t.column("updatedAt", .datetime).notNull()
			}
		}

		migrator.registerMigration("createPiSessions") { db in
			try db.create(table: "piSessions") { t in
				t.autoIncrementedPrimaryKey("id")
				t.column("hostID", .integer).notNull()
					.references("hosts", onDelete: .cascade)
				t.column("summary", .text).notNull()
				t.column("sessionID", .text).notNull().unique()
				t.column("model", .text).notNull()
				t.column("lastMessage", .text)
				t.column("lastMessageAt", .datetime)
				t.column("lastMessageRole", .text)
				t.column("startedAt", .datetime).notNull()
				t.column("lastSeenAt", .datetime).notNull()
			}
		}

		migrator.registerMigration("createMessages") { db in
			try db.create(table: "messages") { t in
				t.autoIncrementedPrimaryKey("id")
				t.column("piSessionID", .integer).notNull()
					.references("piSessions", onDelete: .cascade)
				t.column("role", .text).notNull()
				t.column("toolName", .text)
				t.column("position", .integer).notNull()
				t.column("createdAt", .datetime).notNull()
			}
		}

		migrator.registerMigration("createMessageContentBlocks") { db in
			try db.create(table: "messageContentBlocks") { t in
				t.autoIncrementedPrimaryKey("id")
				t.column("messageID", .integer).notNull()
					.references("messages", onDelete: .cascade)
				t.column("type", .text).notNull()
				t.column("text", .text)
				t.column("toolCallName", .text)
				t.column("position", .integer).notNull()
			}
		}

		return migrator
	}

	// MARK: - Writes

	func addHost(sshTarget: String) throws {
		let trimmed = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
		try dbQueue.write { db in
			let now = Date()
			if var existing = try Host.filter(Column("sshTarget") == trimmed).fetchOne(db) {
				existing.updatedAt = now
				try existing.update(db)
			} else {
				var host = Host(id: nil, sshTarget: trimmed, createdAt: now, updatedAt: now)
				try host.insert(db)
			}
		}
	}

	func deleteHosts(ids: [Int64]) throws {
		try dbQueue.write { db in
			_ = try Host.filter(ids: ids).deleteAll(db)
		}
	}

	// MARK: - Factory

	static func preview() -> AppDatabase {
		try! AppDatabase(dbQueue: DatabaseQueue())
	}
}

// MARK: - Environment

private struct AppDatabaseKey: EnvironmentKey {
	static let defaultValue: AppDatabase? = nil
}

extension EnvironmentValues {
	var appDatabase: AppDatabase? {
		get { self[AppDatabaseKey.self] }
		set { self[AppDatabaseKey.self] = newValue }
	}
}
