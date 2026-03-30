import GRDB
import GRDBQuery
import SwiftUI

// MARK: - Query types

struct MessageInfo: Identifiable {
	let message: Message
	let contentBlocks: [MessageContentBlock]
	let contentFingerprint: UInt64
	var id: String { "\(message.piSessionID)-\(message.position)" }

	init(message: Message, contentBlocks: [MessageContentBlock]) {
		self.message = message
		self.contentBlocks = contentBlocks
		self.contentFingerprint = Self.makeContentFingerprint(message: message, contentBlocks: contentBlocks)
	}

	private static func makeContentFingerprint(message: Message, contentBlocks: [MessageContentBlock]) -> UInt64 {
		TranscriptFingerprint.make { fingerprint in
			fingerprint.combine(message.role.rawString)
			fingerprint.combine(message.toolName)
			fingerprint.combine(message.position)
			for block in contentBlocks {
				fingerprint.combine(block.position)
				fingerprint.combine(block.type)
				fingerprint.combine(block.text)
				fingerprint.combine(block.toolCallName)
				fingerprint.combine(block.mimeType)
				fingerprint.combine(block.attachmentID)
			}
		}
	}
}

struct MessagesRequest: ValueObservationQueryable {
	static var defaultValue: [MessageInfo] { [] }

	let sessionID: String

	func fetch(_ db: Database) throws -> [MessageInfo] {
		let interval = SessionSelectionPerformanceTrace.beginInterval(
			name: "MessagesRequestFetch",
			sessionID: sessionID
		)
		var fetchedCount = 0
		defer {
			SessionSelectionPerformanceTrace.endInterval(
				interval,
				message: "count=\(fetchedCount)"
			)
		}

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
		let messageInfos = messages.map { message in
			MessageInfo(
				message: message,
				contentBlocks: blocksByMessage[message.id ?? -1] ?? []
			)
		}
		fetchedCount = messageInfos.count
		return messageInfos
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
	@State private var customCommands: [PimuxSessionCommand] = []
	@State private var requestedMessageContext: MessageContextRoute?
	@State private var transcriptForcePinToken = 0
	@State private var deferredStartupGeneration = 0
	@State private var deferredStartupRequestID = 0

	init(session: PiSession) {
		self.session = session
		self._storedMessages = Query(MessagesRequest(sessionID: session.sessionID))
	}

	var body: some View {
		VStack(spacing: 0) {
			transcriptView

			MessageComposerView(
				text: $draftMessage,
				customCommands: customCommands,
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
		.onAppear {
			SessionSelectionPerformanceTrace.emitEvent(
				sessionID: session.sessionID,
				name: "PiSessionViewAppear",
				message: "stored=\(storedMessages.count) streamed=\(streamedMessages?.count ?? -1) pending=\(pendingMessages.count)"
			)
			scheduleDeferredStartup()
		}
		.onChange(of: liveTaskKey) {
			scheduleDeferredStartup()
		}
		.navigationDestination(item: $requestedMessageContext) { route in
			MessageContextView(route: route)
		}
		.task(id: "live|\(liveTaskKey)|\(deferredStartupGeneration)") {
			guard deferredStartupGeneration > 0 else { return }
			await liveMessagesLoop()
		}
		.task(id: "commands|\(liveTaskKey)|\(deferredStartupGeneration)") {
			guard deferredStartupGeneration > 0 else { return }
			await loadCustomCommands()
		}
	}

	private var liveTaskKey: String {
		"\(session.sessionID)|\(serverConfiguration?.serverURL ?? "none")"
	}

	private func scheduleDeferredStartup() {
		deferredStartupRequestID &+= 1
		let requestID = deferredStartupRequestID
		let scheduledKey = liveTaskKey

		Task { @MainActor in
			await Task.yield()
			await Task.yield()
			guard requestID == deferredStartupRequestID else { return }
			guard scheduledKey == liveTaskKey else { return }
			deferredStartupGeneration &+= 1
			SessionSelectionPerformanceTrace.emitEvent(
				sessionID: session.sessionID,
				name: "DeferredStartupActivated",
				message: "generation=\(deferredStartupGeneration) key=\(scheduledKey)"
			)
		}
	}

	private var renderedMessages: [MessageInfo] {
		streamedMessages ?? storedMessages
	}

	private var displayedMessages: [DisplayedSessionMessage] {
		renderedMessages.map(DisplayedSessionMessage.confirmed) + pendingMessages.map(DisplayedSessionMessage.pending)
	}

	private var transcriptMessages: [TranscriptMessage] {
		renderedMessages.map(TranscriptMessage.confirmed) + pendingMessages.map(TranscriptMessage.pending)
	}

	private var transcriptEmptyState: TranscriptEmptyState? {
		guard displayedMessages.isEmpty else { return nil }
		if isLoadingMessages {
			return .loading
		} else if let loadError {
			return .error(loadError)
		} else {
			return .empty
		}
	}

	@ViewBuilder
	private var transcriptView: some View {
		#if canImport(UIKit) && !os(macOS)
		VStack(spacing: 0) {
			if transcriptStatusText != nil || !transcriptWarnings.isEmpty {
				VStack(spacing: 0) {
					if let text = transcriptStatusText {
						Label(text, systemImage: "dot.radiowaves.left.and.right")
							.font(.caption)
							.foregroundStyle(.secondary)
							.padding(.horizontal)
							.padding(.vertical, 6)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					ForEach(transcriptWarnings, id: \.self) { warning in
						Label(warning, systemImage: "exclamationmark.triangle.fill")
							.font(.caption)
							.foregroundStyle(.yellow)
							.padding(.horizontal)
							.padding(.vertical, 6)
							.frame(maxWidth: .infinity, alignment: .leading)
							.background(.yellow.opacity(0.1))
					}
				}
				.background(.ultraThinMaterial)
			}

			SessionTranscriptView(
				messages: transcriptMessages,
				sessionID: session.sessionID,
				serverURL: serverConfiguration?.serverURL,
				emptyState: transcriptEmptyState,
				forcePinToken: transcriptForcePinToken,
				onRefresh: { await loadMessages() },
				onRetry: { Task { await loadMessages() } },
				onOpenMessageContext: { requestedMessageContext = $0 }
			)
		}
		#else
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
								MessageView(
									messageInfo: messageInfo,
									sessionID: session.sessionID,
									serverURL: serverConfiguration?.serverURL
								)
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
		#endif
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
			return confirmedScrollSignature(for: messageInfo)
		case .pending(let pendingMessage):
			return pendingScrollSignature(for: pendingMessage)
		}
	}

	private func confirmedScrollSignature(for messageInfo: MessageInfo) -> String {
		let count = String(displayedMessages.count)
		let messageID = messageInfo.id
		let lastBlock = messageInfo.contentBlocks.last
		let blockType = lastBlock?.type ?? "none"
		let blockText = lastBlock?.text ?? ""
		let toolCallName = lastBlock?.toolCallName ?? ""
		let mimeType = lastBlock?.mimeType ?? ""
		let attachmentID = lastBlock?.attachmentID ?? ""
		let components: [String] = [
			count,
			messageID,
			blockType,
			blockText,
			toolCallName,
			mimeType,
			attachmentID,
		]
		return components.joined(separator: "|")
	}

	private func pendingScrollSignature(for pendingMessage: PendingLocalMessage) -> String {
		let components: [String] = [
			String(displayedMessages.count),
			"pending",
			pendingMessage.id.uuidString,
			pendingMessage.normalizedBody,
		]
		return components.joined(separator: "|")
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
		SessionSelectionPerformanceTrace.emitEvent(
			sessionID: session.sessionID,
			name: "LiveMessagesLoopStart",
			message: "serverConfigured=\(serverConfiguration != nil) eagerLoad=false stored=\(storedMessages.count)"
		)

		guard serverConfiguration != nil else {
			liveStreamState = .idle
			return
		}

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
			persistActivity(sessionResponse.activity)
			liveStreamState = .live
			loadError = nil
		case .sessionState(let sequence, let connected, _, _):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			liveStreamState = connected ? .live : .reconnecting
			if !connected {
				persistActivity(PimuxSessionActivity(active: false, attached: false))
			}
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
				Text(verbatim: loadError)
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
		transcriptForcePinToken &+= 1
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

		let interval = SessionSelectionPerformanceTrace.beginInterval(
			name: "LoadMessages",
			sessionID: session.sessionID,
			message: "stored=\(storedMessages.count) rendered=\(renderedMessages.count)"
		)
		isLoadingMessages = true
		defer {
			isLoadingMessages = false
			SessionSelectionPerformanceTrace.endInterval(
				interval,
				message: "loadError=\(loadError ?? "none") rendered=\(renderedMessages.count)"
			)
		}

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
			persistActivity(response.activity)
			loadError = nil
		} catch {
			loadError = error.localizedDescription
			print("Error loading messages for \(session.sessionID): \(error)")
		}
	}

	private func loadCustomCommands() async {
		guard let serverConfiguration else { return }
		do {
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			customCommands = try await client.getCommands(sessionID: session.sessionID)
		} catch {
			// Non-critical; built-in commands still work
			print("Failed to load custom commands for \(session.sessionID): \(error)")
		}
	}

	private func persistActivity(_ activity: PimuxSessionActivity) {
		try? appDatabase?.updateSessionActivity(
			sessionID: session.sessionID,
			active: activity.active,
			attached: activity.attached
		)
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
					toolName: {
						guard let toolName = remoteMessage.toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !toolName.isEmpty else {
							return nil
						}
						return toolName
					}(),
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
							text: text,
							toolCallName: toolCallName,
							position: blockIndex
						)
					case "image":
						return MessageContentBlock(
							id: nil,
							messageID: Int64(index),
							type: "image",
							text: nil,
							toolCallName: nil,
							mimeType: block.mimeType,
							attachmentID: block.attachmentId,
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
							mimeType: block.mimeType,
							attachmentID: block.attachmentId,
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
		Label {
			Text(verbatim: text)
		} icon: {
			Image(systemName: "dot.radiowaves.left.and.right")
		}
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
		Label {
			Text(verbatim: text)
		} icon: {
			Image(systemName: "exclamationmark.triangle.fill")
		}
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
	let sessionID: String
	let serverURL: String?

	private var message: Message { messageInfo.message }

	var body: some View {
		HStack(alignment: .firstTextBaseline) {
			Image(systemName: roleIcon)
				.foregroundStyle(roleColor)
			VStack(alignment: .leading, spacing: 6) {
				HStack(spacing: 6) {
					
					Text(verbatim: roleLabel)
						.font(.caption)
						.fontWeight(.semibold)
						.textCase(.uppercase)
					
					if let toolName = message.toolName {
						Text(verbatim: "· \(toolName)")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				.foregroundStyle(roleColor)
				
				ForEach(messageInfo.contentBlocks, id: \.position) { block in
					ContentBlockView(
						block: block,
						messageRole: message.role,
						messageTitle: messageTitle,
						attachmentURL: attachmentURL(for: block)
					)
				}
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

	private func attachmentURL(for block: MessageContentBlock) -> URL? {
		guard block.type == "image",
			let attachmentID = block.attachmentID,
			!attachmentID.isEmpty,
			let serverURL
		else {
			return nil
		}

		do {
			let client = try PimuxServerClient(baseURL: serverURL)
			return client.attachmentURL(sessionID: sessionID, attachmentID: attachmentID)
		} catch {
			return nil
		}
	}
}

// MARK: - ContentBlockView

struct ContentBlockView: View {
	let block: MessageContentBlock
	let messageRole: Message.Role
	let messageTitle: String
	let attachmentURL: URL?

	var body: some View {
		switch block.type {
		case "text":
			if let text = block.text, !text.isEmpty {
				MessageMarkdownView(text: text, role: messageRole, title: messageTitle)
			}

		case "thinking":
			if let text = block.text, !text.isEmpty {
				Text(verbatim: text)
					.font(chatFont(style: .callout))
					.italic()
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
			}

		case "toolCall":
			VStack(alignment: .leading, spacing: 8) {
				Label {
					Text(verbatim: block.toolCallName ?? "unknown tool")
				} icon: {
					Image(systemName: "terminal.fill")
				}
					.font(chatFont(style: .callout))
					.foregroundStyle(.teal)
					.padding(.vertical, 4)
					.padding(.horizontal, 8)
					.background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

				if let text = block.text, !text.isEmpty {
					ToolCallDetailsView(text: text)
				}
			}

		case "image":
			if let attachmentURL {
				TranscriptImageView(
					url: attachmentURL,
					mimeType: block.mimeType,
					attachmentID: block.attachmentID
				)
			} else {
				Label("Image", systemImage: "photo")
					.font(chatFont(style: .callout))
					.foregroundStyle(.secondary)
			}

		default:
			if let text = block.text, !text.isEmpty {
				Text(verbatim: text)
					.font(chatFont(style: .body))
					.foregroundStyle(.secondary)
			}
		}
	}
}

private struct ToolCallDetailsView: View {
	let text: String

	var body: some View {
		Text(verbatim: text)
			.font(.system(.caption, design: .monospaced))
			.foregroundStyle(.secondary)
			.textSelection(.enabled)
			.padding(.vertical, 8)
			.padding(.horizontal, 10)
			.background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
	}
}

private struct TranscriptImageView: View {
	let url: URL
	let mimeType: String?
	let attachmentID: String?

	var body: some View {
		AsyncImage(url: url) { phase in
			switch phase {
			case .empty:
				placeholder(label: "Loading image…", systemImage: "photo")
			case .success(let image):
				image
					.resizable()
					.scaledToFit()
					.frame(maxWidth: 320, maxHeight: 240, alignment: .leading)
					.clipShape(RoundedRectangle(cornerRadius: 10))
			case .failure:
				placeholder(label: "Couldn’t load image", systemImage: "exclamationmark.triangle")
			@unknown default:
				placeholder(label: "Image", systemImage: "photo")
			}
		}
	}

	@ViewBuilder
	private func placeholder(label: String, systemImage: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Label(label, systemImage: systemImage)
				.font(chatFont(style: .callout))
				.foregroundStyle(.secondary)

			if let mimeType, !mimeType.isEmpty {
				Text(verbatim: mimeType)
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			if let attachmentID, !attachmentID.isEmpty {
				Text(verbatim: attachmentID)
					.font(.caption2)
					.foregroundStyle(.tertiary)
			}
		}
		.padding(.vertical, 8)
		.padding(.horizontal, 10)
		.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
	}
}

// MARK: - Preview

#Preview("All message types") {
	let db = AppDatabase.preview()
	try! db.saveServerConfiguration(serverURL: "http://localhost:3000")

	try! db.dbQueue.write { dbConn in
		let now = Date()

		func insertMessage(
			for sessionID: Int64,
			role: Message.Role,
			toolName: String? = nil,
			position: Int,
			createdAt: Date,
			blocks: [(type: String, text: String?, toolCallName: String?, mimeType: String?, attachmentID: String?)]
		) throws {
			var message = Message(
				piSessionID: sessionID,
				role: role,
				toolName: toolName,
				position: position,
				createdAt: createdAt
			)
			try message.insert(dbConn)

			for (blockIndex, block) in blocks.enumerated() {
				var contentBlock = MessageContentBlock(
					messageID: message.id!,
					type: block.type,
					text: block.text,
					toolCallName: block.toolCallName,
					mimeType: block.mimeType,
					attachmentID: block.attachmentID,
					position: blockIndex
				)
				try contentBlock.insert(dbConn)
			}
		}

		var host = Host(id: nil, location: "nakajima@localhost", createdAt: now, updatedAt: now)
		try host.insert(dbConn)

		var session = PiSession(
			id: nil,
			hostID: host.id!,
			summary: "Working on chat UI",
			sessionID: "test-session-1",
			sessionFile: nil,
			model: "anthropic/claude-sonnet",
			lastMessage: "Unknown roles fall back gracefully.",
			lastMessageAt: now.addingTimeInterval(210),
			lastMessageRole: "systemNote",
			startedAt: now.addingTimeInterval(-900),
			lastSeenAt: now.addingTimeInterval(210)
		)
		try session.insert(dbConn)

		let sessionRowID = session.id!

		try insertMessage(
			for: sessionRowID,
			role: .user,
			position: 0,
			createdAt: now,
			blocks: [
				(type: "text", text: "Can you help me expand this preview so it covers more transcript cases?", toolCallName: nil, mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .assistant,
			position: 1,
			createdAt: now.addingTimeInterval(30),
			blocks: [
				(type: "thinking", text: "Inspecting the supported roles and block kinds before updating the fixtures.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				(type: "toolCall", text: "pimux2000/Views/PiSessionView.swift (offset=785, limit=140)", toolCallName: "read", mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .toolResult,
			toolName: "read",
			position: 2,
			createdAt: now.addingTimeInterval(60),
			blocks: [
				(type: "text", text: "Found the preview block at the bottom of `PiSessionView.swift`:\n\n```swift\nprivate var displayedMessagesScrollSignature: String {\n    ...\n}\n```\n\nIt currently renders text, thinking, tool calls, images, and fallback blocks.", toolCallName: nil, mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .assistant,
			position: 3,
			createdAt: now.addingTimeInterval(90),
			blocks: [
				(type: "toolCall", text: "$ xcodebuild -project pimux2000.xcodeproj -scheme pimux2000 ENABLE_PREVIEWS=YES\n\ntimeout: 120s", toolCallName: "bash", mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .bashExecution,
			position: 4,
			createdAt: now.addingTimeInterval(120),
			blocks: [
				(type: "text", text: "$ xcodebuild -scheme pimux2000 ENABLE_PREVIEWS=YES\nSwiftCompile PiSessionView.swift\n** BUILD SUCCEEDED **", toolCallName: nil, mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .assistant,
			position: 5,
			createdAt: now.addingTimeInterval(150),
			blocks: [
				(type: "toolCall", text: "pimux2000/Views/PiSessionView.swift\n\nsingle replacement", toolCallName: "edit", mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .toolResult,
			toolName: "edit",
			position: 6,
			createdAt: now.addingTimeInterval(180),
			blocks: [
				(type: "text", text: "Applied 1 edit to `pimux2000/Views/PiSessionView.swift`:\n\n- split the scroll signature into smaller helper functions\n- expanded preview fixtures to cover tool calls and summary roles\n- kept the image attachment placeholder in place", toolCallName: nil, mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .assistant,
			position: 7,
			createdAt: now.addingTimeInterval(210),
			blocks: [
				(type: "toolCall", text: "pimux2000/Views/PiSessionView.swift (offset=785, limit=140)", toolCallName: "read", mimeType: nil, attachmentID: nil),
				(type: "toolCall", text: "$ xcodebuild -project pimux2000.xcodeproj -scheme pimux2000 ENABLE_PREVIEWS=YES\n\ntimeout: 120s", toolCallName: "bash", mimeType: nil, attachmentID: nil),
				(type: "toolCall", text: "pimux2000/Views/PiSessionView.swift\n\nsingle replacement", toolCallName: "edit", mimeType: nil, attachmentID: nil),
				(type: "text", text: "Done — this preview now shows tool calls alongside realistic outputs, plus summaries, shell output, image attachments, and fallback cases.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				(type: "image", text: nil, toolCallName: nil, mimeType: "image/png", attachmentID: "img-preview")
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .custom,
			position: 8,
			createdAt: now.addingTimeInterval(240),
			blocks: [
				(type: "other", text: "Custom extension note: the live stream briefly detached, so the app fell back to a persisted snapshot.", toolCallName: nil, mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .branchSummary,
			position: 9,
			createdAt: now.addingTimeInterval(270),
			blocks: [
				(type: "text", text: "Created branch `preview-message-fixtures` from `main` and staged the updated transcript preview data.", toolCallName: nil, mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .compactionSummary,
			position: 10,
			createdAt: now.addingTimeInterval(300),
			blocks: [
				(type: "text", text: "Earlier setup discussion was compacted into a shorter summary so the preview still shows long-running session behavior.", toolCallName: nil, mimeType: nil, attachmentID: nil)
			]
		)

		try insertMessage(
			for: sessionRowID,
			role: .other("systemNote"),
			position: 11,
			createdAt: now.addingTimeInterval(330),
			blocks: [
				(type: "text", text: "Unknown roles render with fallback styling so future transcript events remain visible.", toolCallName: nil, mimeType: nil, attachmentID: nil)
			]
		)
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
