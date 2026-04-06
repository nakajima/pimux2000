import Foundation
import GRDB

enum UITestFixtures {
	private typealias FixtureBlock = (type: String, text: String?, toolCallName: String?, mimeType: String?, attachmentID: String?)

	static func install(in appDatabase: AppDatabase) throws {
		try appDatabase.saveServerURL("http://fixture.local:3000")

		try appDatabase.dbQueue.write { db in
			try installDefaultFixtures(in: db)
		}
	}

	static func installScreenshotScenario(_ scenario: ScreenshotScenario, in appDatabase: AppDatabase) throws {
		try appDatabase.saveServerURL("http://fixture.local:3000")

		try appDatabase.dbQueue.write { db in
			switch scenario {
			case .overview:
				try installOverviewScreenshotFixtures(in: db)
			case .transcript, .slashCommands:
				try installTranscriptScreenshotFixtures(in: db)
			}
		}
	}

	private static let referenceDate: Date = {
		var components = DateComponents()
		components.calendar = Calendar(identifier: .gregorian)
		components.timeZone = TimeZone(secondsFromGMT: 0)
		components.year = 2026
		components.month = 4
		components.day = 2
		components.hour = 9
		components.minute = 41
		components.second = 0
		return components.date!
	}()

	private static func installDefaultFixtures(in db: Database) throws {
		let now = referenceDate
		let hostID = try insertHost(in: db, location: "demo@fixture", at: now)

		let shellSessionID = try insertSession(
			in: db,
			hostID: hostID,
			summary: "Shell session health",
			sessionID: "fixture-shell-session",
			cwd: "/Users/demo/apps/pimux2000",
			lastUserMessageAt: now.addingTimeInterval(-60),
			lastMessage: "Everything looks healthy from the fixture transcript.",
			lastMessageAt: now,
			lastMessageRole: "assistant",
			lastReadMessageAt: now,
			isCliActive: true,
			startedAt: now.addingTimeInterval(-600),
			lastSeenAt: now,
			supportsImages: true
		)

		try insertMessage(
			in: db,
			sessionID: shellSessionID,
			role: .user,
			position: 0,
			createdAt: now.addingTimeInterval(-60),
			blocks: [
				(type: "text", text: "Run the health check against the fixture shell.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: shellSessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-30),
			blocks: [
				(type: "text", text: "Everything looks healthy from the fixture transcript.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		_ = try insertSession(
			in: db,
			hostID: hostID,
			summary: "Watching logs",
			sessionID: "fixture-logs-session",
			cwd: "/Users/demo/apps/pimux-server",
			lastUserMessageAt: now.addingTimeInterval(-180),
			lastMessage: "Tailing the latest relay output.",
			lastMessageAt: now.addingTimeInterval(-120),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-120),
			isCliActive: false,
			startedAt: now.addingTimeInterval(-1200),
			lastSeenAt: now.addingTimeInterval(-120)
		)
	}

	private static func installOverviewScreenshotFixtures(in db: Database) throws {
		let now = referenceDate
		let localHostID = try insertHost(in: db, location: "demo@fixture-mac", at: now)
		let remoteHostID = try insertHost(in: db, location: "ci@fixture-linux", at: now)

		let primarySessionID = try insertSession(
			in: db,
			hostID: localHostID,
			summary: "Ship screenshot workflow",
			sessionID: "screenshot-overview-primary",
			cwd: "/Users/demo/apps/pimux2000",
			lastUserMessageAt: now.addingTimeInterval(-45),
			lastMessage: "Stable fixtures and a screenshot script are ready.",
			lastMessageAt: now,
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-300),
			isCliActive: true,
			startedAt: now.addingTimeInterval(-1800),
			lastSeenAt: now,
			supportsImages: true
		)

		try insertMessage(
			in: db,
			sessionID: primarySessionID,
			role: .user,
			position: 0,
			createdAt: now.addingTimeInterval(-90),
			blocks: [
				(type: "text", text: "Can you make screenshot generation boring and repeatable?", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: primarySessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-30),
			blocks: [
				(type: "text", text: "Stable fixtures and a screenshot script are ready.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		_ = try insertSession(
			in: db,
			hostID: localHostID,
			summary: "Trim transcript spacing",
			sessionID: "screenshot-overview-secondary",
			cwd: "/Users/demo/apps/pimux2000",
			lastUserMessageAt: now.addingTimeInterval(-300),
			lastMessage: "Spacing tweak shipped.",
			lastMessageAt: now.addingTimeInterval(-240),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-240),
			isCliActive: true,
			startedAt: now.addingTimeInterval(-2400),
			lastSeenAt: now.addingTimeInterval(-240)
		)

		_ = try insertSession(
			in: db,
			hostID: remoteHostID,
			summary: "Check relay logs",
			sessionID: "screenshot-overview-remote",
			cwd: "/Users/demo/apps/pimux2000",
			lastUserMessageAt: now.addingTimeInterval(-480),
			lastMessage: "Relay stream stayed attached through the run.",
			lastMessageAt: now.addingTimeInterval(-420),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-420),
			isCliActive: true,
			startedAt: now.addingTimeInterval(-3600),
			lastSeenAt: now.addingTimeInterval(-420)
		)

		_ = try insertSession(
			in: db,
			hostID: localHostID,
			summary: "Background indexing",
			sessionID: "screenshot-overview-background",
			cwd: "/Users/demo/apps/pimux-server",
			lastUserMessageAt: now.addingTimeInterval(-1200),
			lastMessage: "Index finished cleanly.",
			lastMessageAt: now.addingTimeInterval(-1080),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-1080),
			isCliActive: false,
			startedAt: now.addingTimeInterval(-5400),
			lastSeenAt: now.addingTimeInterval(-1080)
		)
	}

	private static func installTranscriptScreenshotFixtures(in db: Database) throws {
		let now = referenceDate
		let hostID = try insertHost(in: db, location: "demo@fixture", at: now)

		let sessionID = try insertSession(
			in: db,
			hostID: hostID,
			summary: "Programmatic screenshot workflow",
			sessionID: "screenshot-transcript-session",
			cwd: "/Users/demo/apps/pimux2000",
			lastUserMessageAt: now.addingTimeInterval(-300),
			lastMessage: "Done — added screenshot scenarios and an export script so the app can generate repeatable screenshots.",
			lastMessageAt: now,
			lastMessageRole: "assistant",
			lastReadMessageAt: now,
			isCliActive: true,
			startedAt: now.addingTimeInterval(-2400),
			lastSeenAt: now,
			supportsImages: true
		)

		try insertMessage(
			in: db,
			sessionID: sessionID,
			role: .user,
			position: 0,
			createdAt: now.addingTimeInterval(-360),
			blocks: [
				(type: "text", text: "Can you wire up a repeatable screenshot workflow for the iOS app?", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-300),
			blocks: [
				(type: "thinking", text: "Planning a deterministic path: add launch-time screenshot scenarios, feed stable database fixtures, then export screenshot attachments from an xcresult bundle.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				(type: "toolCall", text: "pimux2000/Models/UITestFixtures.swift\npimux2000UITests/ScreenshotTests.swift", toolCallName: "read", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sessionID,
			role: .toolResult,
			toolName: "read",
			position: 2,
			createdAt: now.addingTimeInterval(-240),
			blocks: [
				(type: "text", text: "The app already seeds UI test fixtures and the UI tests already know how to save screenshot attachments — this just needs a dedicated scenario path and an export script.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sessionID,
			role: .assistant,
			position: 3,
			createdAt: now.addingTimeInterval(-180),
			blocks: [
				(type: "toolCall", text: "scripts/generate-screenshots.sh\npimux2000/pimux2000App.swift", toolCallName: "edit", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sessionID,
			role: .toolResult,
			toolName: "edit",
			position: 4,
			createdAt: now.addingTimeInterval(-120),
			blocks: [
				(type: "text", text: "Added screenshot scenarios, created dedicated UI screenshot tests, and wrote a script that runs the tests, exports attachments, and renames them into a stable screenshots directory.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sessionID,
			role: .bashExecution,
			position: 5,
			createdAt: now.addingTimeInterval(-60),
			blocks: [
				(type: "text", text: "$ ./scripts/generate-screenshots.sh\n==> Booting iPhone 16 Pro\n==> Running ScreenshotTests\n==> Exported screenshots to build/screenshots", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sessionID,
			role: .assistant,
			position: 6,
			createdAt: now,
			blocks: [
				(type: "text", text: "Done — added screenshot scenarios and an export script so the app can generate repeatable screenshots.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)
	}

	@discardableResult
	private static func insertHost(in db: Database, location: String, at now: Date) throws -> Int64 {
		var host = Host(id: nil, location: location, createdAt: now, updatedAt: now)
		try host.insert(db)
		return try db.require(host.id)
	}

	@discardableResult
	private static func insertSession(
		in db: Database,
		hostID: Int64,
		summary: String,
		sessionID: String,
		cwd: String?,
		lastUserMessageAt: Date?,
		lastMessage: String?,
		lastMessageAt: Date?,
		lastMessageRole: String?,
		lastReadMessageAt: Date?,
		isCliActive: Bool,
		startedAt: Date,
		lastSeenAt: Date,
		supportsImages: Bool? = nil
	) throws -> Int64 {
		var session = PiSession(
			id: nil,
			hostID: hostID,
			summary: summary,
			sessionID: sessionID,
			sessionFile: nil,
			model: "anthropic/claude-sonnet",
			cwd: cwd,
			lastMessage: lastMessage,
			lastUserMessageAt: lastUserMessageAt,
			lastMessageAt: lastMessageAt,
			lastMessageRole: lastMessageRole,
			lastReadMessageAt: lastReadMessageAt,
			isCliActive: isCliActive,
			contextTokensUsed: nil,
			contextTokensMax: nil,
			supportsImages: supportsImages,
			startedAt: startedAt,
			lastSeenAt: lastSeenAt
		)
		try session.insert(db)
		return try db.require(session.id)
	}

	private static func insertMessage(
		in db: Database,
		sessionID: Int64,
		role: Message.Role,
		toolName: String? = nil,
		position: Int,
		createdAt: Date,
		blocks: [FixtureBlock]
	) throws {
		var message = Message(
			piSessionID: sessionID,
			role: role,
			toolName: toolName,
			position: position,
			createdAt: createdAt
		)
		try message.insert(db)
		let messageID = try db.require(message.id)

		for (blockIndex, block) in blocks.enumerated() {
			var contentBlock = MessageContentBlock(
				messageID: messageID,
				type: block.type,
				text: block.text,
				toolCallName: block.toolCallName,
				mimeType: block.mimeType,
				attachmentID: block.attachmentID,
				position: blockIndex
			)
			try contentBlock.insert(db)
		}
	}
}

private extension Database {
	func require<T>(_ value: T?) throws -> T {
		guard let value else {
			throw DatabaseError(message: "Expected fixture value to be present")
		}
		return value
	}
}
