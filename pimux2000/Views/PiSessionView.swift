import GRDB
import GRDBQuery
import SwiftUI

// MARK: - Query types

struct MessageInfo: Identifiable {
	let message: Message
	let contentBlocks: [MessageContentBlock]
	var id: String { "\(message.piSessionID)-\(message.position)" }
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

private enum LiveStreamState {
	case idle
	case connecting
	case live
	case reconnecting

	var statusText: String? {
		switch self {
		case .idle:
			nil
		case .connecting:
			"stream connecting"
		case .live:
			"stream live"
		case .reconnecting:
			"stream reconnecting"
		}
	}
}

private enum DisplayedSessionMessage: Identifiable {
	case confirmed(MessageInfo)
	case pending(PendingLocalMessage)

	var id: String {
		switch self {
		case .confirmed(let messageInfo):
			messageInfo.id
		case .pending(let pendingMessage):
			"pending-\(pendingMessage.id.uuidString)"
		}
	}
}

// MARK: - PiSessionView

struct PiSessionView: View {
	let session: PiSession
	@Environment(\.appDatabase) private var appDatabase
	@Query(CurrentServerConfigurationRequest()) private var serverConfiguration: ServerConfiguration?
	@Query<MessagesRequest> private var storedMessages: [MessageInfo]
	@State private var streamedMessages: [MessageInfo]?
	@State private var draftMessage = ""
	@State private var pendingMessages: [PendingLocalMessage] = []
	@State private var isSendingMessage = false
	@State private var sendError: String?
	@State private var isLoadingMessages = false
	@State private var loadError: String?
	@State private var transcriptWarnings: [String] = []
	@State private var transcriptFreshness: PimuxTranscriptFreshness?
	@State private var transcriptActivity: PimuxSessionActivity?
	@State private var liveStreamState: LiveStreamState = .idle
	@State private var lastStreamSequence: UInt64 = 0

	init(session: PiSession) {
		self.session = session
		self._storedMessages = Query(MessagesRequest(sessionID: session.sessionID))
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 16) {
						if let transcriptStatusText {
							TranscriptStatusView(text: transcriptStatusText)
						}

						ForEach(transcriptWarnings, id: \.self) { warning in
							TranscriptWarningView(text: warning)
						}

						if displayedMessages.isEmpty {
							emptyStateView
						} else {
							ForEach(displayedMessages) { displayedMessage in
								switch displayedMessage {
								case .confirmed(let messageInfo):
									MessageView(messageInfo: messageInfo)
										.id(displayedMessage.id)
								case .pending(let pendingMessage):
									PendingLocalMessageView(message: pendingMessage)
										.id(displayedMessage.id)
								}
							}
						}
					}
					.padding()
				}
				.refreshable {
					await loadMessages()
				}
				.defaultScrollAnchor(.bottom)
				.onChange(of: displayedMessagesScrollSignature) {
					scrollToBottom(proxy: proxy)
				}
			}

			MessageComposerView(
				text: $draftMessage,
				isEnabled: serverConfiguration != nil,
				isSending: isSendingMessage,
				errorMessage: sendError,
				onSend: { Task { await sendMessage() } }
			)
			.onChange(of: draftMessage) {
				sendError = nil
			}
		}
		.navigationTitle(session.summary)
		.task(id: liveTaskKey) {
			await liveMessagesLoop()
		}
	}

	private var liveTaskKey: String {
		"\(session.sessionID)|\(serverConfiguration?.serverURL ?? "none")"
	}

	private var renderedMessages: [MessageInfo] {
		streamedMessages ?? storedMessages
	}

	private var displayedMessages: [DisplayedSessionMessage] {
		renderedMessages.map(DisplayedSessionMessage.confirmed) + pendingMessages.map(DisplayedSessionMessage.pending)
	}

	private var confirmedUserMessageCount: Int {
		renderedMessages.reduce(into: 0) { count, messageInfo in
			if messageInfo.message.role == .user {
				count += 1
			}
		}
	}

	private var displayedMessagesScrollSignature: String {
		guard let lastMessage = displayedMessages.last else { return "empty" }
		switch lastMessage {
		case .confirmed(let messageInfo):
			let lastBlock = messageInfo.contentBlocks.last
			return [
				String(displayedMessages.count),
				messageInfo.id,
				lastBlock?.type ?? "none",
				lastBlock?.text ?? "",
				lastBlock?.toolCallName ?? "",
			].joined(separator: "|")
		case .pending(let pendingMessage):
			return [
				String(displayedMessages.count),
				"pending",
				pendingMessage.id.uuidString,
				pendingMessage.normalizedBody,
			].joined(separator: "|")
		}
	}

	private var transcriptStatusText: String? {
		var components: [String] = []

		if let transcriptFreshness {
			switch transcriptFreshness.state {
			case "live":
				components.append(transcriptActivity?.active == true ? "Live transcript" : "Recent live snapshot")
			case "persisted":
				components.append("Persisted snapshot")
			case "liveUnknown":
				components.append("Transcript reconstructed from file")
			default:
				components.append(transcriptFreshness.state)
			}

			if let transcriptActivity {
				components.append(transcriptActivity.attached ? "attached" : "detached")
			}

			components.append("source: \(transcriptFreshness.source)")
		}

		if let streamStatus = liveStreamState.statusText {
			components.append(streamStatus)
		}

		return components.isEmpty ? nil : components.joined(separator: " • ")
	}

	private func liveMessagesLoop() async {
		guard serverConfiguration != nil else {
			liveStreamState = .idle
			return
		}

		await loadMessages()

		while !Task.isCancelled {
			do {
				guard let serverConfiguration else {
					liveStreamState = .idle
					return
				}

				liveStreamState = .connecting
				lastStreamSequence = 0
				let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
				try await client.streamMessages(sessionID: session.sessionID) { event in
					await handleStreamEvent(event)
				}

				if Task.isCancelled { break }
				liveStreamState = .reconnecting
			} catch {
				if Task.isCancelled { break }
				streamedMessages = nil
				liveStreamState = .reconnecting
				if renderedMessages.isEmpty {
					loadError = error.localizedDescription
				}
				print("Live stream error for \(session.sessionID): \(error)")
			}

			if Task.isCancelled { break }
			await loadMessages()
			try? await Task.sleep(for: .seconds(1))
		}
	}

	private func handleStreamEvent(_ event: PimuxSessionStreamEvent) async {
		switch event {
		case .snapshot(let sequence, let sessionResponse):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			streamedMessages = streamMessageInfos(
				from: sessionResponse.messages,
				piSessionID: session.id ?? 0
			)
			reconcilePendingMessages(using: sessionResponse.messages)
			transcriptWarnings = sessionResponse.warnings
			transcriptFreshness = sessionResponse.freshness
			transcriptActivity = sessionResponse.activity
			liveStreamState = .live
			loadError = nil
		case .sessionState(let sequence, let connected, _, _):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			liveStreamState = connected ? .live : .reconnecting
		case .keepalive(let sequence, _):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			if liveStreamState == .connecting {
				liveStreamState = .live
			}
		}
	}

	private func scrollToBottom(proxy: ScrollViewProxy) {
		if let lastID = displayedMessages.last?.id {
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

	private func sendMessage() async {
		guard !isSendingMessage else { return }
		guard let serverConfiguration else {
			sendError = "No pimux server configured."
			return
		}

		let body = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !body.isEmpty else { return }

		let pendingMessage = PendingLocalMessage(
			body: body,
			confirmedUserMessageBaseline: confirmedUserMessageCount
		)
		pendingMessages.append(pendingMessage)
		draftMessage = ""
		isSendingMessage = true
		sendError = nil
		defer { isSendingMessage = false }

		do {
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			try await client.sendMessage(sessionID: session.sessionID, body: body)
			await loadMessages()
		} catch {
			pendingMessages.removeAll { $0.id == pendingMessage.id }
			draftMessage = body
			sendError = error.localizedDescription
			print("Error sending message for \(session.sessionID): \(error)")
		}
	}

	private func currentSessionRow() async throws -> PiSession? {
		guard let appDatabase else { return nil }
		return try await appDatabase.dbQueue.read { db in
			try PiSession
				.filter(Column("sessionID") == session.sessionID)
				.fetchOne(db)
		}
	}

	private func loadMessages() async {
		guard let appDatabase, !isLoadingMessages else { return }
		guard let serverConfiguration else {
			loadError = "No pimux server configured."
			return
		}

		isLoadingMessages = true
		defer { isLoadingMessages = false }

		do {
			guard let currentSession = try await currentSessionRow() else {
				loadError = "This session is no longer available locally."
				return
			}
			guard let sessionRowID = currentSession.id else {
				loadError = "This session doesn’t have a local database ID yet."
				return
			}

			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			let response = try await client.getMessages(sessionID: currentSession.sessionID)

			try await appDatabase.dbQueue.write { dbConn in
				try PiSessionSync.storeMessages(response.messages, piSessionID: sessionRowID, in: dbConn)
			}

			reconcilePendingMessages(using: response.messages)
			transcriptWarnings = response.warnings
			transcriptFreshness = response.freshness
			transcriptActivity = response.activity
			loadError = nil
		} catch {
			loadError = error.localizedDescription
			print("Error loading messages for \(session.sessionID): \(error)")
		}
	}

	private func reconcilePendingMessages(using confirmedMessages: [PimuxTranscriptMessage]) {
		pendingMessages = pendingMessagesAwaitingConfirmation(
			pendingMessages,
			confirmedMessages: confirmedMessages
		)
	}

	private func streamMessageInfos(from remoteMessages: [PimuxTranscriptMessage], piSessionID: Int64) -> [MessageInfo] {
		remoteMessages.enumerated().map { index, remoteMessage in
			MessageInfo(
				message: Message(
					id: nil,
					piSessionID: piSessionID,
					role: Message.Role(remoteMessage.role),
					toolName: nil,
					position: index,
					createdAt: remoteMessage.createdAt
				),
				contentBlocks: remoteMessage.blocks.enumerated().compactMap { blockIndex, block in
					let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines)
					switch block.type {
					case "text", "thinking", "other":
						guard let text, !text.isEmpty else { return nil }
						return MessageContentBlock(
							id: nil,
							messageID: Int64(index),
							type: block.type,
							text: text,
							toolCallName: nil,
							position: blockIndex
						)
					case "toolCall":
						guard let toolCallName = block.toolCallName?.trimmingCharacters(in: .whitespacesAndNewlines), !toolCallName.isEmpty else {
							return nil
						}
						return MessageContentBlock(
							id: nil,
							messageID: Int64(index),
							type: "toolCall",
							text: nil,
							toolCallName: toolCallName,
							position: blockIndex
						)
					default:
						guard let text, !text.isEmpty else { return nil }
						return MessageContentBlock(
							id: nil,
							messageID: Int64(index),
							type: block.type,
							text: text,
							toolCallName: block.toolCallName,
							position: blockIndex
						)
					}
				}
			)
		}
	}
}

private struct TranscriptStatusView: View {
	let text: String

	var body: some View {
		Label(text, systemImage: "dot.radiowaves.left.and.right")
			.font(.caption)
			.foregroundStyle(.secondary)
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
	}
}

private struct TranscriptWarningView: View {
	let text: String

	var body: some View {
		Label(text, systemImage: "exclamationmark.triangle.fill")
			.font(.caption)
			.foregroundStyle(.yellow)
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			.background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
	}
}

private struct PendingLocalMessageView: View {
	let message: PendingLocalMessage

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				Image(systemName: "clock.fill")
				Text("You")
					.font(.caption)
					.fontWeight(.semibold)
					.textCase(.uppercase)
				Text("· Pending")
					.font(.caption)
			}
			.foregroundStyle(.secondary)

			MessageMarkdownView(text: message.body, role: .user, title: "You")
				.opacity(0.55)
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
		case .bashExecution: "Bash"
		case .custom: "Custom"
		case .branchSummary: "Branch Summary"
		case .compactionSummary: "Summary"
		case .other(let value): value
		}
	}

	private var roleIcon: String {
		switch message.role {
		case .user: "person.fill"
		case .assistant: "sparkles"
		case .toolResult: "wrench.fill"
		case .bashExecution: "terminal.fill"
		case .custom: "square.stack.3d.up.fill"
		case .branchSummary: "arrow.triangle.branch"
		case .compactionSummary: "archivebox.fill"
		case .other: "ellipsis.circle"
		}
	}

	private var roleColor: Color {
		switch message.role {
		case .user: .blue
		case .assistant: .purple
		case .toolResult: .orange
		case .bashExecution: .teal
		case .custom: .indigo
		case .branchSummary: .green
		case .compactionSummary: .brown
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
	try! db.saveServerConfiguration(serverURL: "http://localhost:3000")

	try! db.dbQueue.write { dbConn in
		var host = Host(id: nil, location: "nakajima@localhost", createdAt: Date(), updatedAt: Date())
		try host.insert(dbConn)

		var session = PiSession(
			id: nil,
			hostID: host.id!,
			summary: "Working on chat UI",
			sessionID: "test-session-1",
			sessionFile: nil,
			model: "anthropic/claude-sonnet",
			lastMessage: nil,
			lastMessageAt: Date(),
			lastMessageRole: "assistant",
			startedAt: Date(),
			lastSeenAt: Date()
		)
		try session.insert(dbConn)

		var userMessage = Message(piSessionID: session.id!, role: .user, toolName: nil, position: 0, createdAt: Date())
		try userMessage.insert(dbConn)
		var userBlock = MessageContentBlock(messageID: userMessage.id!, type: "text", text: "Can you help me set up a transcript view?", toolCallName: nil, position: 0)
		try userBlock.insert(dbConn)

		var assistantMessage = Message(piSessionID: session.id!, role: .assistant, toolName: nil, position: 1, createdAt: Date())
		try assistantMessage.insert(dbConn)
		var assistantThinking = MessageContentBlock(messageID: assistantMessage.id!, type: "thinking", text: "Planning a robust live transcript path with stream fallback.", toolCallName: nil, position: 0)
		try assistantThinking.insert(dbConn)
		var assistantBlock = MessageContentBlock(messageID: assistantMessage.id!, type: "text", text: "Sure — this view now supports a live session stream plus snapshot fallback.", toolCallName: nil, position: 1)
		try assistantBlock.insert(dbConn)
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
