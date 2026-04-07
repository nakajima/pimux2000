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
		let hostID = try insertHost(in: db, location: "nakajima@local", at: now)

		let sshPromptSessionID = try insertSession(
			in: db,
			hostID: hostID,
			summary: "SSH password authentication prompt implementation",
			sessionID: "overview-ssh-password",
			cwd: "/Users/nakajima/apps/Termsy",
			lastUserMessageAt: now.addingTimeInterval(-150),
			lastMessage: "Auth failures now short-circuit cleanly and the password prompt appears.",
			lastMessageAt: now,
			lastMessageRole: "assistant",
			lastReadMessageAt: now,
			isCliActive: true,
			startedAt: now.addingTimeInterval(-4200),
			lastSeenAt: now
		)

		try insertMessage(
			in: db,
			sessionID: sshPromptSessionID,
			role: .user,
			position: 0,
			createdAt: now.addingTimeInterval(-360),
			blocks: [
				(type: "text", text: "can we add the ability to prompt for a password if no auth doesn't work?", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sshPromptSessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-300),
			blocks: [
				(type: "text", text: "Now I understand the flow. `TerminalTab.connect()` always passes `password: nil`, `SSHConnection` falls through to `authenticationFailed`, and the cleanest fix is a `needsPassword` retry path.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				(type: "toolCall", text: "Termsy/Views/ViewCoordinator.swift\nTermsy/SSH/SSHConnection.swift", toolCallName: "edit", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sshPromptSessionID,
			role: .toolResult,
			toolName: "edit",
			position: 2,
			createdAt: now.addingTimeInterval(-240),
			blocks: [
				(type: "text", text: "Added `needsPassword` to `TerminalTab`, a reconnect-with-password path, and UI that asks for a password instead of surfacing a generic connection error.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sshPromptSessionID,
			role: .user,
			position: 3,
			createdAt: now.addingTimeInterval(-120),
			blocks: [
				(type: "text", text: "it's just hanging here: `[SSH] trying none auth` finishes, but `startShell()` never returns.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: sshPromptSessionID,
			role: .assistant,
			position: 4,
			createdAt: now,
			blocks: [
				(type: "text", text: "Auth failures now short-circuit cleanly and the password prompt appears.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		let slashMenuSessionID = try insertSession(
			in: db,
			hostID: hostID,
			summary: "iOS app slash command menu feature",
			sessionID: "overview-slash-menu",
			cwd: "/Users/nakajima/apps/pimux2000",
			lastUserMessageAt: now.addingTimeInterval(-540),
			lastMessage: "Built-in and live session commands now autocomplete in the composer.",
			lastMessageAt: now.addingTimeInterval(-420),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-420),
			isCliActive: true,
			startedAt: now.addingTimeInterval(-5400),
			lastSeenAt: now.addingTimeInterval(-420)
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .user,
			position: 0,
			createdAt: now.addingTimeInterval(-600),
			blocks: [
				(type: "text", text: "can we provide a menu of available when the user types / in the ios app, same as the tui", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-420),
			blocks: [
				(type: "text", text: "The composer now shows a filterable slash menu, and the live session path can merge built-in commands with dynamic commands from `get_commands`.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		let typestateSessionID = try insertSession(
			in: db,
			hostID: hostID,
			summary: "Typestate refactor for record lifecycle",
			sessionID: "overview-typestate",
			cwd: "/Users/nakajima/apps/seekwel",
			lastUserMessageAt: now.addingTimeInterval(-900),
			lastMessage: "Person<S> models new vs persisted records without splitting the type.",
			lastMessageAt: now.addingTimeInterval(-780),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-780),
			isCliActive: false,
			startedAt: now.addingTimeInterval(-7200),
			lastSeenAt: now.addingTimeInterval(-780)
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .user,
			position: 0,
			createdAt: now.addingTimeInterval(-960),
			blocks: [
				(type: "text", text: "let's brainstorm. can we rework the model a bit? I was thinking we'd have Person have a typestate of either NewRecord or Persisted.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-780),
			blocks: [
				(type: "text", text: "Person<S> is the sweet spot here: keep `id` as data, use typestate for lifecycle, and let `save()` move `NewRecord` into `Persisted`.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)
	}

	private static func installTranscriptScreenshotFixtures(in db: Database) throws {
		let now = referenceDate
		let hostID = try insertHost(in: db, location: "nakajima@local", at: now)

		let slashMenuSessionID = try insertSession(
			in: db,
			hostID: hostID,
			summary: "iOS app slash command menu feature",
			sessionID: "transcript-slash-menu",
			cwd: "/Users/nakajima/apps/pimux2000",
			lastUserMessageAt: now.addingTimeInterval(-240),
			lastMessage: "Done — the composer now shows built-in and live session commands in a slash menu.",
			lastMessageAt: now,
			lastMessageRole: "assistant",
			lastReadMessageAt: now,
			isCliActive: true,
			startedAt: now.addingTimeInterval(-5400),
			lastSeenAt: now,
			supportsImages: true
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .user,
			position: 0,
			createdAt: now.addingTimeInterval(-540),
			blocks: [
				(type: "text", text: "can we provide a menu of available when the user types / in the ios app, same as the tui", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-480),
			blocks: [
				(type: "thinking", text: "Slash commands are already sent as normal text like `/compact`, so the iOS side mainly needs a filterable menu and a source of command metadata.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				(type: "toolCall", text: "pimux2000/Views/MessageComposerView.swift\npimux2000/Views/PiSessionView.swift", toolCallName: "read", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .toolResult,
			toolName: "read",
			position: 2,
			createdAt: now.addingTimeInterval(-420),
			blocks: [
				(type: "text", text: "Found the composer and transcript view. The first pass can ship the built-in list locally, then the live session path can expose `get_commands` for extension, skill, and prompt-template commands.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .assistant,
			position: 3,
			createdAt: now.addingTimeInterval(-360),
			blocks: [
				(type: "text", text: "The first pass can ship the built-in menu locally, then we can plumb `get_commands` through the live session path for custom commands.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				(type: "toolCall", text: "pimux2000/Models/SlashCommand.swift\npimux2000/Views/MessageComposerView.swift", toolCallName: "edit", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .toolResult,
			toolName: "edit",
			position: 4,
			createdAt: now.addingTimeInterval(-300),
			blocks: [
				(type: "text", text: "Added `SlashCommand.swift`, a filtered menu in `MessageComposerView`, and a preview that renders the slash state.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .user,
			position: 5,
			createdAt: now.addingTimeInterval(-240),
			blocks: [
				(type: "text", text: "will this work with commands that are added by extensions", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .assistant,
			position: 6,
			createdAt: now.addingTimeInterval(-180),
			blocks: [
				(type: "text", text: "Not yet — extension, skill, and prompt-template commands come from `get_commands`, so the server needs to expose them and the iOS client needs to merge the results.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				(type: "toolCall", text: "pimux-server/src/agent/live.rs\npimux2000/Views/PiSessionView.swift", toolCallName: "edit", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .toolResult,
			toolName: "edit",
			position: 7,
			createdAt: now.addingTimeInterval(-120),
			blocks: [
				(type: "text", text: "Plumbed `GetCommands` through the live session store and updated the composer to merge built-in commands with dynamic session commands.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .bashExecution,
			position: 8,
			createdAt: now.addingTimeInterval(-60),
			blocks: [
				(type: "text", text: "$ xcodebuild test -scheme pimux2000 -only-testing:pimux2000UITests/pimux2000UITests/testSlashCommandMenuAppears\n** TEST SUCCEEDED **\nExported screenshot to /tmp/slash_menu_filtered.png", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .assistant,
			position: 9,
			createdAt: now,
			blocks: [
				(type: "text", text: "Done — the composer now shows built-in and live session commands in a slash menu.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		_ = try insertSession(
			in: db,
			hostID: hostID,
			summary: "SSH password authentication prompt implementation",
			sessionID: "transcript-ssh-password",
			cwd: "/Users/nakajima/apps/Termsy",
			lastUserMessageAt: now.addingTimeInterval(-420),
			lastMessage: "Auth failures now short-circuit cleanly and the password prompt appears.",
			lastMessageAt: now.addingTimeInterval(-300),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-300),
			isCliActive: true,
			startedAt: now.addingTimeInterval(-4200),
			lastSeenAt: now.addingTimeInterval(-300)
		)

		_ = try insertSession(
			in: db,
			hostID: hostID,
			summary: "Typestate refactor for record lifecycle",
			sessionID: "transcript-typestate",
			cwd: "/Users/nakajima/apps/seekwel",
			lastUserMessageAt: now.addingTimeInterval(-720),
			lastMessage: "Person<S> models new vs persisted records without splitting the type.",
			lastMessageAt: now.addingTimeInterval(-600),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-600),
			isCliActive: false,
			startedAt: now.addingTimeInterval(-7200),
			lastSeenAt: now.addingTimeInterval(-600)
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
