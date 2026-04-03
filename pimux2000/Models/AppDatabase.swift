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
				t.column("location", .text).notNull().unique()
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
				t.column("sessionFile", .text)
				t.column("model", .text).notNull()
				t.column("lastMessage", .text)
				t.column("lastMessageAt", .datetime)
				t.column("lastMessageRole", .text)
				t.column("lastReadMessageAt", .datetime)
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
				t.column("mimeType", .text)
				t.column("attachmentID", .text)
				t.column("position", .integer).notNull()
			}
		}

		migrator.registerMigration("migrateHostsToLocations") { db in
			let columnNames = try Self.columnNames(in: "hosts", db: db)
			if columnNames.contains("sshTarget") && !columnNames.contains("location") {
				try db.execute(sql: "ALTER TABLE hosts ADD COLUMN location TEXT NOT NULL DEFAULT ''")
				try db.execute(sql: "UPDATE hosts SET location = sshTarget WHERE location = ''")
				try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS hosts_on_location ON hosts(location)")
			}
		}

		migrator.registerMigration("createServerConfigurations") { db in
			try db.create(table: "serverConfigurations") { t in
				t.autoIncrementedPrimaryKey("id")
				t.column("serverURL", .text).notNull()
				t.column("createdAt", .datetime).notNull()
				t.column("updatedAt", .datetime).notNull()
			}
		}

		migrator.registerMigration("addPiSessionReadStatus") { db in
			let columnNames = try Self.columnNames(in: "piSessions", db: db)
			guard !columnNames.contains("lastReadMessageAt") else { return }

			try db.execute(sql: "ALTER TABLE piSessions ADD COLUMN lastReadMessageAt DATETIME")
			try db.execute(sql: "UPDATE piSessions SET lastReadMessageAt = lastMessageAt")
		}

		migrator.registerMigration("addPiSessionHostConnected") { db in
			let columnNames = try Self.columnNames(in: "piSessions", db: db)
			if columnNames.contains("hostConnected") {
				try db.execute(sql: "ALTER TABLE piSessions RENAME COLUMN hostConnected TO isCliActive")
			} else if !columnNames.contains("isCliActive") {
				try db.execute(sql: "ALTER TABLE piSessions ADD COLUMN isCliActive BOOLEAN NOT NULL DEFAULT 0")
			}
		}

		migrator.registerMigration("addPiSessionContextUsage") { db in
			let columnNames = try Self.columnNames(in: "piSessions", db: db)
			if !columnNames.contains("contextTokensUsed") {
				try db.execute(sql: "ALTER TABLE piSessions ADD COLUMN contextTokensUsed INTEGER")
			}
			if !columnNames.contains("contextTokensMax") {
				try db.execute(sql: "ALTER TABLE piSessions ADD COLUMN contextTokensMax INTEGER")
			}
		}

		migrator.registerMigration("addMessageContentBlockAttachments") { db in
			let columnNames = try Self.columnNames(in: "messageContentBlocks", db: db)
			if !columnNames.contains("mimeType") {
				try db.execute(sql: "ALTER TABLE messageContentBlocks ADD COLUMN mimeType TEXT")
			}
			if !columnNames.contains("attachmentID") {
				try db.execute(sql: "ALTER TABLE messageContentBlocks ADD COLUMN attachmentID TEXT")
			}
		}

		migrator.registerMigration("addPiSessionSupportsImages") { db in
			let columnNames = try Self.columnNames(in: "piSessions", db: db)
			if !columnNames.contains("supportsImages") {
				try db.execute(sql: "ALTER TABLE piSessions ADD COLUMN supportsImages BOOLEAN")
			}
		}

		migrator.registerMigration("addPiSessionCwd") { db in
			let columnNames = try Self.columnNames(in: "piSessions", db: db)
			if !columnNames.contains("cwd") {
				try db.execute(sql: "ALTER TABLE piSessions ADD COLUMN cwd TEXT")
			}
		}

		migrator.registerMigration("addPiSessionLastUserMessageAt") { db in
			let columnNames = try Self.columnNames(in: "piSessions", db: db)
			guard !columnNames.contains("lastUserMessageAt") else { return }

			try db.execute(sql: "ALTER TABLE piSessions ADD COLUMN lastUserMessageAt DATETIME")
			try db.execute(sql: "UPDATE piSessions SET lastUserMessageAt = lastMessageAt WHERE lastUserMessageAt IS NULL")
		}

		migrator.registerMigration("addMessageServerID") { db in
			let columnNames = try Self.columnNames(in: "messages", db: db)
			if !columnNames.contains("serverMessageID") {
				try db.execute(sql: "ALTER TABLE messages ADD COLUMN serverMessageID INTEGER")
			}
		}

		return migrator
	}

	// MARK: - Writes

	func saveServerConfiguration(serverURL rawValue: String) throws {
		let normalized = try PimuxServerClient.normalizedBaseURLString(from: rawValue)
		try dbQueue.write { db in
			let now = Date()
			let existing = try ServerConfiguration
				.order(Column("updatedAt").desc)
				.fetchOne(db)

			if existing?.serverURL != normalized {
				try Self.clearSyncedData(in: db)
			}

			_ = try ServerConfiguration.deleteAll(db)

			var configuration = ServerConfiguration(
				id: nil,
				serverURL: normalized,
				createdAt: existing?.createdAt ?? now,
				updatedAt: now
			)
			try configuration.insert(db)
		}
	}

	func updateSessionActivity(sessionID: String, active: Bool, attached: Bool) throws {
		try dbQueue.write { db in
			guard var session = try PiSession
				.filter(Column("sessionID") == sessionID)
				.fetchOne(db) else { return }
			let isLive = active && attached
			guard session.isCliActive != isLive else { return }
			session.isCliActive = isLive
			try session.update(db)
		}
	}

	func markSessionRead(sessionID: String, through lastReadMessageAt: Date) throws {
		try dbQueue.write { db in
			guard var session = try PiSession
				.filter(Column("sessionID") == sessionID)
				.fetchOne(db) else { return }

			guard session.lastReadMessageAt.map({ $0 < lastReadMessageAt }) ?? true else { return }
			session.lastReadMessageAt = lastReadMessageAt
			try session.update(db)
		}
	}

	// MARK: - Factory

	static func preview() -> AppDatabase {
		try! AppDatabase(dbQueue: DatabaseQueue())
	}

	private static func clearSyncedData(in db: Database) throws {
		_ = try MessageContentBlock.deleteAll(db)
		_ = try Message.deleteAll(db)
		_ = try PiSession.deleteAll(db)
		_ = try Host.deleteAll(db)
		try? AttachmentStore.removeAll()
	}

	private nonisolated static func columnNames(in table: String, db: Database) throws -> Set<String> {
		try Set(
			Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
				.compactMap { row in row["name"] as String? }
		)
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
