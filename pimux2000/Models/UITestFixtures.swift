import Foundation
import GRDB

enum UITestFixtures {
	private typealias FixtureBlock = (type: String, text: String?, toolCallName: String?, mimeType: String?, attachmentID: String?)

	private static let imageTranscriptSessionID = "transcript-image-preview"
	private static let imageTranscriptAttachmentID = "preview-inline-image"

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

		installScreenshotAttachments(for: scenario)
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
			isCliActive: true,
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
			lastUserMessageAt: now.addingTimeInterval(-150),
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
			createdAt: now.addingTimeInterval(-510),
			blocks: [
				(type: "text", text: "can we provide a menu of available when the user types / in the ios app, same as the tui", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-450),
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
			createdAt: now.addingTimeInterval(-390),
			blocks: [
				(type: "text", text: "Found the composer and transcript view. The first pass can ship the built-in list locally, then the live session path can expose `get_commands` for extension, skill, and prompt-template commands.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .assistant,
			position: 3,
			createdAt: now.addingTimeInterval(-330),
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
			createdAt: now.addingTimeInterval(-270),
			blocks: [
				(type: "text", text: "Added `SlashCommand.swift`, a filtered menu in `MessageComposerView`, and a preview that renders the slash state.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .user,
			position: 5,
			createdAt: now.addingTimeInterval(-210),
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
			createdAt: now.addingTimeInterval(-150),
			blocks: [
				(type: "text", text: "Plumbed `GetCommands` through the live session store and updated the composer to merge built-in commands with dynamic session commands.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: slashMenuSessionID,
			role: .bashExecution,
			position: 8,
			createdAt: now.addingTimeInterval(-120),
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

		let typestateSessionID = try insertSession(
			in: db,
			hostID: hostID,
			summary: "Typestate refactor for record lifecycle",
			sessionID: "transcript-typestate",
			cwd: "/Users/nakajima/apps/seekwel",
			lastUserMessageAt: now.addingTimeInterval(-90),
			lastMessage: "Updated README to match the current typestate API and removed the stale migrate section.",
			lastMessageAt: now.addingTimeInterval(-60),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-60),
			isCliActive: true,
			startedAt: now.addingTimeInterval(-7200),
			lastSeenAt: now.addingTimeInterval(-60)
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .user,
			position: 0,
			createdAt: now.addingTimeInterval(-420),
			blocks: [
				(type: "text", text: "let's brainstorm. can we rework the model a bit? I was thinking we'd have Person have a typestate of either NewRecord or Persisted.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-390),
			blocks: [
				(type: "text", text: "Yeah — typestate for record lifecycle is a good fit here. `Persisted<const ID: u64>` sounds elegant, but the ID is runtime data, so I'd keep `id` as a value and use the type parameter only for lifecycle semantics.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .assistant,
			position: 2,
			createdAt: now.addingTimeInterval(-360),
			blocks: [
				(type: "toolCall", text: "README.md\nsrc/model.rs\nseekwel-derive/src/lib.rs", toolCallName: "read", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .toolResult,
			toolName: "read",
			position: 3,
			createdAt: now.addingTimeInterval(-330),
			blocks: [
				(type: "text", text: "The current derive macro builds and inserts immediately, and the runtime trait surface assumes `id()` / `set_id()`. That makes `Person<S>` plus a `save()` transition much more practical than splitting into `NewPerson` and `Person`.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .user,
			position: 4,
			createdAt: now.addingTimeInterval(-300),
			blocks: [
				(type: "text", text: "right totally forgot about the runtime part. let's go with typestates but keep id as a property. i mostly just don't want a `NewPerson` vs `Person` type split", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .assistant,
			position: 5,
			createdAt: now.addingTimeInterval(-270),
			blocks: [
				(type: "text", text: "`Person<S>` is the sweet spot here:\n\n```rust\npub struct NewRecord;\npub struct Persisted;\n\npub struct Person<S = Persisted> {\n    id: u64,\n    name: String,\n    age: Option<u8>,\n    _state: PhantomData<S>,\n}\n```\n\nThen `build()` returns `Person<NewRecord>` and `save()` returns `Person<Persisted>`.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .assistant,
			position: 6,
			createdAt: now.addingTimeInterval(-240),
			blocks: [
				(type: "toolCall", text: "src/model.rs\nseekwel-derive/src/lib.rs\nREADME.md", toolCallName: "edit", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .toolResult,
			toolName: "edit",
			position: 7,
			createdAt: now.addingTimeInterval(-210),
			blocks: [
				(type: "text", text: "Implemented the typestate refactor: added `NewRecord` / `Persisted`, split runtime behavior into `Model` and `PersistedModel`, and taught the derive macro to generate the new builder + save flow.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .bashExecution,
			position: 8,
			createdAt: now.addingTimeInterval(-180),
			blocks: [
				(type: "text", text: "$ cargo test\nCompiling seekwel-derive v0.1.0\nCompiling seekwel v0.1.0\nFinished test profile\nRunning tests\n\ntest result: ok. 9 passed; 0 failed", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .user,
			position: 9,
			createdAt: now.addingTimeInterval(-150),
			blocks: [
				(type: "text", text: "is the readme up to date?", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .assistant,
			position: 10,
			createdAt: now.addingTimeInterval(-120),
			blocks: [
				(type: "text", text: "Not fully. The models section matches the new `build()` → `NewRecord` → `save()` flow, but the old migrate section is stale and still documents the pre-typestate API.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .assistant,
			position: 11,
			createdAt: now.addingTimeInterval(-90),
			blocks: [
				(type: "toolCall", text: "README.md", toolCallName: "write", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .toolResult,
			toolName: "write",
			position: 12,
			createdAt: now.addingTimeInterval(-75),
			blocks: [
				(type: "text", text: "Successfully wrote 1415 bytes to README.md and replaced the stale migration docs with the current typestate model flow.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: typestateSessionID,
			role: .assistant,
			position: 13,
			createdAt: now.addingTimeInterval(-60),
			blocks: [
				(type: "text", text: "Updated README to match the current typestate API and removed the stale migrate section.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		let imageTranscriptSessionID = try insertSession(
			in: db,
			hostID: hostID,
			summary: "iOS app preview tool calls and messages",
			sessionID: Self.imageTranscriptSessionID,
			cwd: "/Users/nakajima/apps/pimux2000",
			lastUserMessageAt: now.addingTimeInterval(-240),
			lastMessage: "The updated preview screenshot renders inline below.",
			lastMessageAt: now.addingTimeInterval(-30),
			lastMessageRole: "assistant",
			lastReadMessageAt: now.addingTimeInterval(-30),
			isCliActive: true,
			startedAt: now.addingTimeInterval(-3600),
			lastSeenAt: now.addingTimeInterval(-30),
			supportsImages: true
		)

		try insertMessage(
			in: db,
			sessionID: imageTranscriptSessionID,
			role: .user,
			position: 0,
			createdAt: now.addingTimeInterval(-300),
			blocks: [
				(type: "text", text: "some previews aren't building for the ios app", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: imageTranscriptSessionID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(-240),
			blocks: [
				(type: "thinking", text: "The preview host already covers text, thinking, tool calls, and summaries. I want one transcript that also proves inline image attachments render correctly.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				(type: "toolCall", text: "pimux2000/Views/PiSessionView.swift\npimux2000/Views/Messages/TranscriptImageView.swift", toolCallName: "read", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: imageTranscriptSessionID,
			role: .toolResult,
			toolName: "read",
			position: 2,
			createdAt: now.addingTimeInterval(-180),
			blocks: [
				(type: "text", text: "Found the preview transcript fixtures and the image attachment view. A dedicated message block with `type: image` will let the transcript render the attachment inline just like a real session.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: imageTranscriptSessionID,
			role: .assistant,
			position: 3,
			createdAt: now.addingTimeInterval(-150),
			blocks: [
				(type: "toolCall", text: "pimux2000/Models/UITestFixtures.swift\npimux2000/Views/Messages/TranscriptImageView.swift", toolCallName: "edit", mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: imageTranscriptSessionID,
			role: .toolResult,
			toolName: "edit",
			position: 4,
			createdAt: now.addingTimeInterval(-120),
			blocks: [
				(type: "text", text: "Added a screenshot fixture session that carries a real cached PNG attachment, plus a UI test hook that waits for the inline image before capturing.", toolCallName: nil, mimeType: nil, attachmentID: nil),
			]
		)

		try insertMessage(
			in: db,
			sessionID: imageTranscriptSessionID,
			role: .assistant,
			position: 5,
			createdAt: now.addingTimeInterval(-30),
			blocks: [
				(type: "text", text: "The updated preview screenshot renders inline below.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				(type: "image", text: nil, toolCallName: nil, mimeType: "image/png", attachmentID: Self.imageTranscriptAttachmentID),
			]
		)
	}

	private static func installScreenshotAttachments(for scenario: ScreenshotScenario) {
		switch scenario {
		case .overview:
			return
		case .transcript, .slashCommands:
			_ = PreviewAttachmentFixture.installImageAttachment(
				sessionID: imageTranscriptSessionID,
				attachmentID: imageTranscriptAttachmentID,
				mimeType: "image/png"
			)
		}
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
