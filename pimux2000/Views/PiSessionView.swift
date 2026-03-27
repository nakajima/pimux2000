import GRDB
import GRDBQuery
import Pi
import SwiftUI

// MARK: - Query types

struct MessageInfo: Identifiable, Equatable {
	let message: Message
	let contentBlocks: [MessageContentBlock]
	var id: Int64? { message.id }
}

struct MessagesRequest: ValueObservationQueryable {
	static var defaultValue: [MessageInfo] { [] }

	let session: PiSession

	func fetch(_ db: Database) throws -> [MessageInfo] {
		let messages = try Message
			.filter(Column("piSessionID") == session.id)
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
	@State private var sendError: String?

	init(session: PiSession) {
		self.session = session
		self._messages = Query(MessagesRequest(session: session))
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 16) {
						ForEach(messages) { messageInfo in
							MessageView(messageInfo: messageInfo)
								.id(messageInfo.id)
						}
					}
					.padding()
				}
				.defaultScrollAnchor(.bottom)
				.onChange(of: messages.count) {
					if let lastID = messages.last?.id {
						withAnimation {
							proxy.scrollTo(lastID, anchor: .bottom)
						}
					}
				}
			}

			Divider()

			HStack(alignment: .bottom, spacing: 12) {
				TextField("Send a message…", text: $inputText, axis: .vertical)
					.textFieldStyle(.plain)
					.lineLimit(1...5)
					.disabled(isSending)

				Button {
					Task { await sendPrompt() }
				} label: {
					if isSending {
						ProgressView()
							.controlSize(.small)
					} else {
						Image(systemName: "arrow.up.circle.fill")
							.font(.title2)
					}
				}
				.disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
			}
			.padding()
		}
		.navigationTitle(session.summary)
		.task {
			while !Task.isCancelled {
				await loadMessages()
				try? await Task.sleep(for: .seconds(3))
			}
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

	private func connectToServer() async throws -> PiServerClient? {
		guard let db = appDatabase else { return nil }
		let host = try await db.dbQueue.read { db in
			try Host.fetchOne(db, id: session.hostID)
		}
		guard let host else { return nil }

		let client = PiServerClient(serverURL: host.serverURL)
		try await client.connect()
		return client
	}

	private func loadMessages() async {
		guard let db = appDatabase, let sessionID = session.id else { return }
		guard let sessionFile = session.sessionFile else { return }

		do {
			guard let client = try await connectToServer() else { return }
			let remoteMessages = try await client.getMessages(sessionFile: sessionFile)
			await client.disconnect()

			try await db.dbQueue.write { dbConn in
				try Message.filter(Column("piSessionID") == sessionID).deleteAll(dbConn)

				for (index, msg) in remoteMessages.enumerated() {
					let roleString = msg["role"]?.stringValue ?? "unknown"
					var message = Message(
						piSessionID: sessionID,
						role: Message.Role(roleString),
						toolName: msg["toolName"]?.stringValue,
						position: index,
						createdAt: Date()
					)
					try message.insert(dbConn)

					let blocks = PiSessionSync.parseContentBlocks(
						from: msg["content"],
						messageID: message.id!
					)
					for var block in blocks {
						try block.insert(dbConn)
					}
				}
			}
		} catch {
			print("Error loading messages: \(error)")
		}
	}

	private func sendPrompt() async {
		let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		guard let sessionFile = session.sessionFile else { return }

		inputText = ""
		isSending = true
		defer { isSending = false }

		do {
			guard let client = try await connectToServer() else { return }
			_ = try await client.prompt(sessionFile: sessionFile, message: text)
			await client.disconnect()
		} catch {
			sendError = error.localizedDescription
		}
	}
}

// MARK: - MessageView

struct MessageView: View {
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

			ForEach(messageInfo.contentBlocks) { block in
				ContentBlockView(block: block)
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
}

// MARK: - ContentBlockView

struct ContentBlockView: View {
	let block: MessageContentBlock

	var body: some View {
		switch block.type {
		case "text":
			if let text = block.text, !text.isEmpty {
				Text(text)
					.font(chatFont(style: .body))
					.textSelection(.enabled)
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
