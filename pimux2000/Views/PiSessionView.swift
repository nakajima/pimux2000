import GRDB
import GRDBQuery
import Pi
import SwiftUI

// MARK: - Query types

struct MessageInfo: Identifiable, Equatable {
	let message: Message
	let contentBlocks: [MessageContentBlock]
	var id: String { "\(message.piSessionID)-\(message.position)" }

	static func == (lhs: MessageInfo, rhs: MessageInfo) -> Bool {
		lhs.message.piSessionID == rhs.message.piSessionID
			&& lhs.message.position == rhs.message.position
			&& lhs.message.role == rhs.message.role
			&& lhs.message.toolName == rhs.message.toolName
			&& lhs.contentBlocks.elementsEqual(rhs.contentBlocks, by: Self.blocksEqual)
	}

	private static func blocksEqual(_ lhs: MessageContentBlock, _ rhs: MessageContentBlock) -> Bool {
		lhs.position == rhs.position
			&& lhs.type == rhs.type
			&& lhs.text == rhs.text
			&& lhs.toolCallName == rhs.toolCallName
	}
}

struct MessagesRequest: ValueObservationQueryable {
	static var defaultValue: [MessageInfo] { [] }

	let sessionID: String

	func fetch(_ db: Database) throws -> [MessageInfo] {
		guard let currentSession = try PiSession
			.filter(Column("sessionID") == sessionID)
			.fetchOne(db),
			let piSessionID = currentSession.id else { return [] }

		let messages = try Message
			.filter(Column("piSessionID") == piSessionID)
			.order(Column("position").asc)
			.fetchAll(db)

		let messageIDs = messages.compactMap(\.id)
		guard !messageIDs.isEmpty else { return [] }

		let blocks = try MessageContentBlock
			.filter(messageIDs.contains(Column("messageID")))
			.order(Column("position").asc)
			.fetchAll(db)

		let blocksByMessage = Dictionary(grouping: blocks, by: \.messageID)

		return messages.map { message in
			MessageInfo(
				message: message,
				contentBlocks: blocksByMessage[message.id ?? -1] ?? []
			)
		}
	}
}

// MARK: - PiSessionView

struct PiSessionView: View {
	let session: PiSession
	@Environment(\.appDatabase) private var appDatabase
	@Query<MessagesRequest> var messages: [MessageInfo]
	@State private var inputText = ""
	@State private var isSending = false
	@State private var isLoadingMessages = false
	@State private var pendingMessage: String?
	@State private var sendError: String?
	@State private var loadError: String?

	init(session: PiSession) {
		self.session = session
		self._messages = Query(MessagesRequest(sessionID: session.sessionID))
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 16) {
						if messages.isEmpty, pendingMessage == nil {
							emptyStateView
						}

						ForEach(messages) { messageInfo in
							MessageView(messageInfo: messageInfo)
								.equatable()
								.id(messageInfo.id)
						}

						if let pendingMessage {
							PendingUserMessageView(text: pendingMessage)
								.id("pending-user")

							ThinkingIndicatorView()
								.id("pending-thinking")
						}
					}
					.padding()
				}
				.refreshable {
					await loadMessages()
				}
				.defaultScrollAnchor(.bottom)
				.onChange(of: messages.count) {
					scrollToBottom(proxy: proxy)
				}
				.onChange(of: pendingMessage) {
					if pendingMessage != nil {
						proxy.scrollTo("pending-thinking", anchor: .bottom)
					}
				}
			}

			Divider()

			HStack(alignment: .bottom, spacing: 12) {
				TextField("Send a message…", text: $inputText, axis: .vertical)
					.textFieldStyle(.plain)
					.lineLimit(1...5)
					.submitLabel(.send)
					.disabled(isSending)
					.onSubmit { Task { await sendPrompt() } }

				Button {
					Task { await sendPrompt() }
				} label: {
					Image(systemName: "arrow.up.circle.fill")
						.font(.title2)
				}
				.disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
			}
			.padding()
		}
		.navigationTitle(session.summary)
		.task(id: session.sessionID) {
			await loadMessages()
		}
		.alert("Send Failed", isPresented: .init(
			get: { sendError != nil },
			set: { if !$0 { sendError = nil } }
		)) {
			Button("OK", role: .cancel) {}
		} message: {
			Text(sendError ?? "")
		}
	}

	private func scrollToBottom(proxy: ScrollViewProxy) {
		if pendingMessage != nil {
			proxy.scrollTo("pending-thinking", anchor: .bottom)
		} else if let lastID = messages.last?.id {
			proxy.scrollTo(lastID, anchor: .bottom)
		}
	}

	@ViewBuilder
	private var emptyStateView: some View {
		if isLoadingMessages {
			ContentUnavailableView {
				ProgressView()
			} description: {
				Text("Loading messages…")
			}
		} else if let loadError {
			ContentUnavailableView {
				Label("Couldn’t Load Messages", systemImage: "exclamationmark.triangle")
			} description: {
				Text(loadError)
			} actions: {
				Button("Retry") {
					Task { await loadMessages() }
				}
			}
		} else {
			ContentUnavailableView("No messages yet", systemImage: "text.bubble")
		}
	}

	private func currentSessionContext() async throws -> (session: PiSession, host: Host)? {
		guard let db = appDatabase else { return nil }
		return try await db.dbQueue.read { db in
			guard let currentSession = try PiSession
				.filter(Column("sessionID") == session.sessionID)
				.fetchOne(db),
				let host = try Host.fetchOne(db, id: currentSession.hostID) else { return nil }
			return (currentSession, host)
		}
	}

	private func connectToServer(host: Host) async throws -> PiServerClient {
		let client = PiServerClient(serverURL: host.serverURL)
		try await client.connect()
		return client
	}

	private func loadMessages() async {
		guard let db = appDatabase, !isLoadingMessages else { return }
		isLoadingMessages = true
		defer { isLoadingMessages = false }

		do {
			guard let context = try await currentSessionContext() else {
				loadError = "This session is no longer available locally."
				return
			}
			guard let sessionID = context.session.id else {
				loadError = "This session doesn’t have a local database ID yet."
				return
			}
			guard let sessionFile = context.session.sessionFile else {
				loadError = "This session has no session file."
				return
			}

			let client = PiServerClient(serverURL: context.host.serverURL)
			let remoteMessages = try await client.getMessages(sessionFile: sessionFile)

			try await db.dbQueue.write { dbConn in
				try PiSessionSync.storeMessages(remoteMessages, piSessionID: sessionID, in: dbConn)
			}
			loadError = nil
		} catch {
			loadError = error.localizedDescription
			print("Error loading messages for \(session.sessionID): \(error)")
		}
	}

	private func sendPrompt() async {
		let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }

		inputText = ""
		pendingMessage = text
		isSending = true

		do {
			guard let context = try await currentSessionContext() else {
				sendError = "This session is no longer available locally."
				pendingMessage = nil
				isSending = false
				return
			}
			guard let sessionFile = context.session.sessionFile else {
				sendError = "This session has no session file."
				pendingMessage = nil
				isSending = false
				return
			}

			let client = try await connectToServer(host: context.host)
			defer { Task { await client.disconnect() } }
			_ = try await client.prompt(sessionFile: sessionFile, message: text)
		} catch {
			sendError = error.localizedDescription
		}

		pendingMessage = nil
		isSending = false
		await loadMessages()
	}
}

// MARK: - Pending message views

private struct PendingUserMessageView: View {
	let text: String

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "person.fill")
				Text("You")
					.font(.caption)
					.fontWeight(.semibold)
					.textCase(.uppercase)
			}
			.foregroundStyle(.blue)

			Text(text)
				.font(chatFont(style: .body))
		}
	}
}

private struct ThinkingIndicatorView: View {
	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "sparkles")
			Text("Thinking…")
				.font(.caption)
				.fontWeight(.semibold)
				.textCase(.uppercase)
			ProgressView()
				.controlSize(.small)
		}
		.foregroundStyle(.purple)
	}
}

// MARK: - MessageView

struct MessageView: View, Equatable {
	let messageInfo: MessageInfo

	private var message: Message { messageInfo.message }

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: roleIcon)
				Text(roleLabel)
					.font(.caption)
					.fontWeight(.semibold)
					.textCase(.uppercase)

				if let toolName = message.toolName {
					Text("· \(toolName)")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.foregroundStyle(roleColor)

			ForEach(messageInfo.contentBlocks, id: \.position) { block in
				ContentBlockView(
					block: block,
					messageRole: message.role,
					messageTitle: messageTitle
				)
			}
		}
	}

	private var roleLabel: String {
		switch message.role {
		case .user: "You"
		case .assistant: "Assistant"
		case .toolResult: "Tool Result"
		case .other(let value): value
		}
	}

	private var roleIcon: String {
		switch message.role {
		case .user: "person.fill"
		case .assistant: "sparkles"
		case .toolResult: "wrench.fill"
		case .other: "ellipsis.circle"
		}
	}

	private var roleColor: Color {
		switch message.role {
		case .user: .blue
		case .assistant: .purple
		case .toolResult: .orange
		case .other: .secondary
		}
	}

	private var messageTitle: String {
		if let toolName = message.toolName {
			return "\(roleLabel) · \(toolName)"
		}
		return roleLabel
	}
}

// MARK: - ContentBlockView

struct ContentBlockView: View {
	let block: MessageContentBlock
	let messageRole: Message.Role
	let messageTitle: String

	var body: some View {
		switch block.type {
		case "text":
			if let text = block.text, !text.isEmpty {
				MessageMarkdownView(text: text, role: messageRole, title: messageTitle)
			}

		case "thinking":
			if let text = block.text, !text.isEmpty {
				Text(text)
					.font(chatFont(style: .callout))
					.italic()
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
			}

		case "toolCall":
			Label(block.toolCallName ?? "unknown tool", systemImage: "terminal.fill")
				.font(chatFont(style: .callout))
				.foregroundStyle(.teal)
				.padding(.vertical, 4)
				.padding(.horizontal, 8)
				.background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

		case "image":
			Label("Image", systemImage: "photo")
				.font(chatFont(style: .callout))
				.foregroundStyle(.secondary)

		default:
			if let text = block.text, !text.isEmpty {
				Text(text)
					.font(chatFont(style: .body))
					.foregroundStyle(.secondary)
			}
		}
	}
}

// MARK: - Preview

#Preview {
	let db = AppDatabase.preview()

	try! db.dbQueue.write { dbConn in
		var host = Host(sshTarget: "nakajima@localhost", createdAt: Date(), updatedAt: Date())
		try host.insert(dbConn)

		var session = PiSession(
			hostID: host.id!,
			summary: "Working on chat UI",
			sessionID: "test-session-1",
			sessionFile: "/tmp/test-session.jsonl",
			model: "anthropic/claude-sonnet",
			lastMessage: "Done!",
			lastMessageAt: Date(),
			lastMessageRole: "assistant",
			startedAt: Date(),
			lastSeenAt: Date()
		)
		try session.insert(dbConn)

		var userMsg = Message(piSessionID: session.id!, role: .user, toolName: nil, position: 0, createdAt: Date())
		try userMsg.insert(dbConn)
		var userBlock = MessageContentBlock(messageID: userMsg.id!, type: "text", text: "Can you help me set up a chat UI?", toolCallName: nil, position: 0)
		try userBlock.insert(dbConn)

		var assistantMsg = Message(piSessionID: session.id!, role: .assistant, toolName: nil, position: 1, createdAt: Date())
		try assistantMsg.insert(dbConn)
		var thinkingBlock = MessageContentBlock(messageID: assistantMsg.id!, type: "thinking", text: "Let me think about the best approach for a chat UI…", toolCallName: nil, position: 0)
		try thinkingBlock.insert(dbConn)
		var textBlock = MessageContentBlock(messageID: assistantMsg.id!, type: "text", text: "Sure! I'll help you set up a basic chat UI. Let me start by reading the existing code.", toolCallName: nil, position: 1)
		try textBlock.insert(dbConn)
		var toolCallBlock = MessageContentBlock(messageID: assistantMsg.id!, type: "toolCall", text: nil, toolCallName: "Read", position: 2)
		try toolCallBlock.insert(dbConn)

		var toolResultMsg = Message(piSessionID: session.id!, role: .toolResult, toolName: "Read", position: 2, createdAt: Date())
		try toolResultMsg.insert(dbConn)
		var resultBlock = MessageContentBlock(messageID: toolResultMsg.id!, type: "text", text: "// Contents of PiSessionView.swift\nimport SwiftUI\nimport GRDB…", toolCallName: nil, position: 0)
		try resultBlock.insert(dbConn)

		var assistantMsg2 = Message(piSessionID: session.id!, role: .assistant, toolName: nil, position: 3, createdAt: Date())
		try assistantMsg2.insert(dbConn)
		var textBlock2 = MessageContentBlock(messageID: assistantMsg2.id!, type: "text", text: "I've read the file. Here's my plan for the chat UI:\n\n1. Add a message list with ScrollView\n2. Style each message by role\n3. Add an input field at the bottom\n\nLet me implement this now.", toolCallName: nil, position: 0)
		try textBlock2.insert(dbConn)
	}

	let session = try! db.dbQueue.read { dbConn in
		try PiSession.fetchOne(dbConn)!
	}

	return NavigationStack {
		PiSessionView(session: session)
	}
	.environment(\.appDatabase, db)
	.databaseContext(.readWrite { db.dbQueue })
}
