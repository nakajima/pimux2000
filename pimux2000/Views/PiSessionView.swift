import GRDB
import GRDBQuery
import PhotosUI
import SwiftUI
#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

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
	@State private var draftImages: [ComposerImage] = []
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
	@State private var isAgentBusy = false
	@State private var currentUIDialog: PimuxSessionUIDialogState?
	@State private var currentTerminalOnlyUIState: PimuxSessionTerminalOnlyUIState?
	@State private var isUIDialogActionInFlight = false
	@State private var uiDialogActionError: String?
	@State private var uiDialogValueSyncTask: Task<Void, Never>?
	@State private var agentIdleTask: Task<Void, Never>?
	@State private var deferredStartupGeneration = 0
	@State private var deferredStartupRequestID = 0
	@State private var requestedBuiltinSession: PiSession?
	@State private var availableForkMessages: [PimuxSessionForkMessage] = []
	@State private var isShowingForkMessagePicker = false
	@State private var isCreatingFork = false
	@State private var forkCommandError: String?
	@Binding var columnVisibility: NavigationSplitViewVisibility
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass

	init(session: PiSession, columnVisibility: Binding<NavigationSplitViewVisibility>) {
		self.session = session
		self._columnVisibility = columnVisibility
		self._storedMessages = Query(MessagesRequest(sessionID: session.sessionID))
	}

	var body: some View {
		ZStack {
			VStack(spacing: 0) {
				transcriptView

				if let currentTerminalOnlyUIState {
					ExtensionCommandTerminalOnlyBanner(
						state: currentTerminalOnlyUIState,
						onDismiss: {
							self.currentTerminalOnlyUIState = nil
						},
						onInterrupt: {
							Task { await interruptSession() }
						}
					)
					.padding(.horizontal)
					.padding(.top, 8)
					.padding(.bottom, 4)
				}

				MessageComposerView(
					text: $draftMessage,
					attachments: draftImages,
					customCommands: customCommands,
					canAttachImages: session.supportsImages ?? true,
					isEnabled: serverConfiguration != nil,
					isSending: isSendingMessage,
					isAgentActive: isAgentBusy,
					errorMessage: sendError,
					onSend: { Task { await sendMessage() } },
					onStop: { Task { await interruptSession() } },
					onRemoveAttachment: { id in draftImages.removeAll { $0.id == id } },
					onPhotosSelected: { importPhotos($0) },
					onImportImageData: { data, source in importImageData(data, source: source) }
				)
				.onChange(of: draftMessage) {
					sendError = nil
				}
			}

			if let currentUIDialog {
				Color.black.opacity(0.16)
					.ignoresSafeArea()
					.onTapGesture {
						guard !isUIDialogActionInFlight else { return }
						Task { await cancelUIDialog() }
					}

				SessionUIDialogOverlay(
					dialog: currentUIDialog,
					textValue: uiDialogTextBinding(for: currentUIDialog),
					isSendingAction: isUIDialogActionInFlight,
					errorMessage: uiDialogActionError,
					onSelectOption: { index in
						Task { await chooseUIDialogOption(index) }
					},
					onSubmitTextValue: {
						Task { await submitUIDialogTextValue() }
					},
					onCancel: {
						Task { await cancelUIDialog() }
					}
				)
				.padding(20)
			}
		}
		.navigationTitle(session.summary)
		#if canImport(UIKit) && !os(macOS)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .topBarLeading) {
				if horizontalSizeClass != .compact {
					Button {
						withAnimation {
							columnVisibility = columnVisibility == .detailOnly ? .automatic : .detailOnly
						}
					} label: {
						Label("Toggle Sidebar", systemImage: "sidebar.left")
					}
					.keyboardShortcut("l", modifiers: [.command, .shift])
				}
			}
		}
		#endif
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
		.navigationDestination(item: $requestedBuiltinSession) { builtinSession in
			PiSessionView(session: builtinSession, columnVisibility: $columnVisibility)
				.id(builtinSession.sessionID)
		}
		.sheet(isPresented: $isShowingForkMessagePicker) {
			SessionForkMessagePickerView(
				messages: availableForkMessages,
				isSubmitting: isCreatingFork,
				errorMessage: forkCommandError,
				onSelect: { message in
					Task { await createFork(from: message) }
				},
				onCancel: {
					isShowingForkMessagePicker = false
					availableForkMessages = []
					forkCommandError = nil
				}
			)
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

	private func markAgentBusy() {
		isAgentBusy = true
		agentIdleTask?.cancel()
		agentIdleTask = Task {
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			isAgentBusy = false
		}
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
		SessionTranscriptView(
			messages: transcriptMessages,
			sessionID: session.sessionID,
			serverURL: serverConfiguration?.serverURL,
			emptyState: transcriptEmptyState,
			forcePinToken: transcriptForcePinToken,
			onRetry: { Task { await loadMessages() } },
			onOpenMessageContext: { requestedMessageContext = $0 }
		)
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
								TranscriptMessageView(
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
			currentUIDialog = nil
			currentTerminalOnlyUIState = nil
			uiDialogActionError = nil
			isUIDialogActionInFlight = false
			uiDialogValueSyncTask?.cancel()
			uiDialogValueSyncTask = nil
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
			let newMessages = streamMessageInfos(
				from: sessionResponse.messages,
				piSessionID: session.id ?? 0
			)
			let contentChanged = streamedMessages != nil
				&& newMessages.map(\.contentFingerprint) != streamedMessages?.map(\.contentFingerprint)
			streamedMessages = newMessages
			if contentChanged {
				markAgentBusy()
			}
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
		case .uiState(let sequence, _):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
		case .uiDialogState(let sequence, let state):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			applyIncomingUIDialogState(state)
		case .terminalOnlyUiState(let sequence, let state):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			currentTerminalOnlyUIState = state
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
				Label("Couldn't Load Messages", systemImage: "exclamationmark.triangle")
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
		let readyImages = draftImages.filter(\.isReady)
		guard !body.isEmpty || !readyImages.isEmpty else { return }

		if let builtinCommand = builtinCommand(for: body, readyImages: readyImages) {
			await executeBuiltinCommand(builtinCommand, serverURL: serverConfiguration.serverURL)
			return
		}

		let pendingMessage = PendingLocalMessage(
			body: body,
			images: readyImages,
			confirmedUserMessageBaseline: confirmedUserMessageCount
		)
		transcriptForcePinToken &+= 1
		pendingMessages.append(pendingMessage)
		let savedDraftImages = draftImages
		draftMessage = ""
		draftImages = []
		isSendingMessage = true
		sendError = nil
		defer { isSendingMessage = false }

		do {
			let inputImages = readyImages.compactMap(\.inputImage)
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			try await client.sendMessage(sessionID: session.sessionID, body: body, images: inputImages)
			markAgentBusy()
			await loadMessages()
		} catch {
			pendingMessages.removeAll { $0.id == pendingMessage.id }
			draftMessage = body
			draftImages = savedDraftImages
			sendError = error.localizedDescription
			print("Error sending message for \(session.sessionID): \(error)")
		}
	}

	private enum BuiltinSlashCommand {
		case copy
		case name(String)
		case compact(String?)
		case session(String)
		case reload(String)
		case newSession
		case fork
	}

	private func builtinCommand(for body: String, readyImages: [ComposerImage]) -> BuiltinSlashCommand? {
		guard readyImages.isEmpty else { return nil }
		guard body.hasPrefix("/") else { return nil }

		let parts = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
		guard let rawCommand = parts.first else { return nil }
		let command = rawCommand.dropFirst().lowercased()
		let argument = parts.count > 1
			? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
			: ""

		switch command {
		case "copy":
			return .copy
		case "name":
			return .name(argument)
		case "compact":
			return .compact(argument.isEmpty ? nil : argument)
		case "session":
			return .session(argument)
		case "reload":
			return .reload(argument)
		case "new":
			return .newSession
		case "fork":
			return .fork
		default:
			return nil
		}
	}

	private func executeBuiltinCommand(_ command: BuiltinSlashCommand, serverURL: String) async {
		switch command {
		case .copy:
			executeCopyBuiltinCommand()
		case .name(let name):
			let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmedName.isEmpty else {
				sendError = "Usage: /name <name>"
				return
			}
			await runBuiltinCommand(restoreDraftOnFailure: true) {
				let client = try PimuxServerClient(baseURL: serverURL)
				try await client.setSessionName(sessionID: session.sessionID, name: trimmedName)
				draftMessage = ""
			}
		case .compact(let customInstructions):
			await runBuiltinCommand(restoreDraftOnFailure: true) {
				let client = try PimuxServerClient(baseURL: serverURL)
				try await client.compactSession(
					sessionID: session.sessionID,
					customInstructions: customInstructions
				)
				draftMessage = ""
				markAgentBusy()
			}
		case .session(let argument):
			guard argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				sendError = "Usage: /session"
				return
			}
			sendError = nil
			draftMessage = ""
			requestedMessageContext = sessionInfoRoute()
		case .reload(let argument):
			guard argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				sendError = "Usage: /reload"
				return
			}
			await runBuiltinCommand(restoreDraftOnFailure: true) {
				let client = try PimuxServerClient(baseURL: serverURL)
				try await client.reloadSession(sessionID: session.sessionID)
				draftMessage = ""
				Task {
					try? await Task.sleep(for: .seconds(1))
					await loadCustomCommands()
				}
			}
		case .newSession:
			await runBuiltinCommand(restoreDraftOnFailure: true) {
				let client = try PimuxServerClient(baseURL: serverURL)
				let newSessionID = try await client.createNewSession(sessionID: session.sessionID)
				draftMessage = ""
				requestedBuiltinSession = makeTransientBuiltinSession(
					sessionID: newSessionID,
					summary: "New Session"
				)
			}
		case .fork:
			await loadForkMessages(serverURL: serverURL)
		}
	}

	private func runBuiltinCommand(
		restoreDraftOnFailure: Bool,
		operation: @escaping () async throws -> Void
	) async {
		guard !isSendingMessage else { return }
		let savedDraftMessage = draftMessage
		let savedDraftImages = draftImages
		isSendingMessage = true
		sendError = nil
		defer { isSendingMessage = false }

		do {
			try await operation()
		} catch {
			if restoreDraftOnFailure {
				draftMessage = savedDraftMessage
				draftImages = savedDraftImages
			}
			sendError = error.localizedDescription
		}
	}

	private func executeCopyBuiltinCommand() {
		guard let text = lastAssistantTextToCopy() else {
			sendError = "No agent messages to copy yet."
			return
		}

		#if canImport(UIKit) && !os(macOS)
		UIPasteboard.general.string = text
		sendError = nil
		draftMessage = ""
		#else
		sendError = "Copy is currently only implemented for iOS."
		#endif
	}

	private func lastAssistantTextToCopy() -> String? {
		for messageInfo in renderedMessages.reversed() where messageInfo.message.role == .assistant {
			let text = messageInfo.contentBlocks
				.compactMap(\.text)
				.joined(separator: "\n")
				.trimmingCharacters(in: .whitespacesAndNewlines)
			if !text.isEmpty {
				return text
			}
		}
		return nil
	}

	private func loadForkMessages(serverURL: String) async {
		guard !isSendingMessage else { return }
		let savedDraftMessage = draftMessage
		let savedDraftImages = draftImages
		isSendingMessage = true
		sendError = nil
		defer { isSendingMessage = false }

		do {
			let client = try PimuxServerClient(baseURL: serverURL)
			let messages = try await client.getForkMessages(sessionID: session.sessionID)
			guard !messages.isEmpty else {
				sendError = "No messages to fork from."
				return
			}
			availableForkMessages = messages
			forkCommandError = nil
			isShowingForkMessagePicker = true
			draftMessage = ""
		} catch {
			draftMessage = savedDraftMessage
			draftImages = savedDraftImages
			sendError = error.localizedDescription
		}
	}

	private func createFork(from message: PimuxSessionForkMessage) async {
		guard let serverConfiguration else {
			forkCommandError = "No pimux server configured."
			return
		}

		isCreatingFork = true
		forkCommandError = nil
		defer { isCreatingFork = false }

		do {
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			let newSessionID = try await client.forkSession(
				sessionID: session.sessionID,
				entryID: message.entryID
			)
			isShowingForkMessagePicker = false
			availableForkMessages = []
			requestedBuiltinSession = makeTransientBuiltinSession(
				sessionID: newSessionID,
				summary: forkedSessionSummary(from: message.text)
			)
		} catch {
			forkCommandError = error.localizedDescription
		}
	}

	private func makeTransientBuiltinSession(sessionID: String, summary: String) -> PiSession {
		PiSession(
			id: nil,
			hostID: session.hostID,
			summary: summary,
			sessionID: sessionID,
			sessionFile: nil,
			model: session.model,
			cwd: session.cwd,
			lastMessage: nil,
			lastUserMessageAt: nil,
			lastMessageAt: nil,
			lastMessageRole: nil,
			lastReadMessageAt: nil,
			isCliActive: false,
			contextTokensUsed: nil,
			contextTokensMax: nil,
			supportsImages: session.supportsImages,
			startedAt: Date(),
			lastSeenAt: Date()
		)
	}

	private func forkedSessionSummary(from text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return "Fork" }
		let prefix = String(trimmed.prefix(48))
		return trimmed.count > 48 ? "Fork: \(prefix)…" : "Fork: \(prefix)"
	}

	private func sessionInfoRoute() -> MessageContextRoute {
		MessageContextRoute(
			title: "Session Info",
			text: sessionInfoMarkdown(),
			role: .other("sessionInfo")
		)
	}

	private func sessionInfoMarkdown() -> String {
		let userCount = renderedMessages.filter { $0.message.role == .user }.count
		let assistantCount = renderedMessages.filter { $0.message.role == .assistant }.count
		let toolResultCount = renderedMessages.filter { $0.message.role == .toolResult }.count
		let bashExecutionCount = renderedMessages.filter { $0.message.role == .bashExecution }.count
		let customCount = renderedMessages.filter { $0.message.role == .custom }.count
		let branchSummaryCount = renderedMessages.filter { $0.message.role == .branchSummary }.count
		let compactionSummaryCount = renderedMessages.filter { $0.message.role == .compactionSummary }.count
		let otherCount = renderedMessages.count - userCount - assistantCount - toolResultCount - bashExecutionCount - customCount - branchSummaryCount - compactionSummaryCount

		var lines: [String] = [
			"# Session Info",
			"",
			"## Identity",
			"- Summary: \(inlineCode(session.summary))",
			"- Session ID: \(inlineCode(session.sessionID))",
			"- Model: \(inlineCode(session.model))",
		]

		if let cwd = session.cwd, !cwd.isEmpty {
			lines.append("- Working Directory: \(inlineCode(cwd))")
		}
		if let sessionFile = session.sessionFile, !sessionFile.isEmpty {
			lines.append("- Session File: \(inlineCode(sessionFile))")
		}

		lines.append(contentsOf: [
			"- Started: \(formattedDateLine(session.startedAt))",
			"- Last Seen: \(formattedOptionalDateLine(session.lastSeenAt))",
		])

		if let lastUserMessageAt = session.lastUserMessageAt {
			lines.append("- Last User Message: \(formattedDateLine(lastUserMessageAt))")
		}
		if let lastMessageAt = session.lastMessageAt {
			lines.append("- Last Message: \(formattedDateLine(lastMessageAt))")
		}

		lines.append("")
		lines.append("## Activity")
		if let transcriptActivity {
			lines.append("- Active: \(transcriptActivity.active ? "yes" : "no")")
			lines.append("- Attached: \(transcriptActivity.attached ? "yes" : "no")")
		}
		if let transcriptFreshness {
			lines.append("- Transcript State: \(inlineCode(transcriptFreshness.state))")
			lines.append("- Transcript Source: \(inlineCode(transcriptFreshness.source))")
			lines.append("- Transcript As Of: \(formattedDateLine(transcriptFreshness.asOf))")
		}
		if let streamStatus = liveStreamState.statusText {
			lines.append("- Stream Status: \(inlineCode(streamStatus))")
		}
		if !transcriptWarnings.isEmpty {
			lines.append("- Transcript Warnings: \(transcriptWarnings.count)")
		}

		lines.append("")
		lines.append("## Messages")
		lines.append("- User: \(userCount)")
		lines.append("- Assistant: \(assistantCount)")
		lines.append("- Tool Results: \(toolResultCount)")
		if bashExecutionCount > 0 {
			lines.append("- Bash Executions: \(bashExecutionCount)")
		}
		if customCount > 0 {
			lines.append("- Custom: \(customCount)")
		}
		if branchSummaryCount > 0 {
			lines.append("- Branch Summaries: \(branchSummaryCount)")
		}
		if compactionSummaryCount > 0 {
			lines.append("- Compaction Summaries: \(compactionSummaryCount)")
		}
		if otherCount > 0 {
			lines.append("- Other: \(otherCount)")
		}
		lines.append("- Total Confirmed: \(renderedMessages.count)")
		if !pendingMessages.isEmpty {
			lines.append("- Pending Local Messages: \(pendingMessages.count)")
		}

		if session.contextTokensUsed != nil || session.contextTokensMax != nil {
			lines.append("")
			lines.append("## Context")
			if let used = session.contextTokensUsed {
				lines.append("- Used Tokens: \(used.formatted())")
			}
			if let max = session.contextTokensMax {
				lines.append("- Max Tokens: \(max.formatted())")
			}
			if let used = session.contextTokensUsed, let max = session.contextTokensMax, max > 0 {
				let percent = Double(used) / Double(max) * 100
				lines.append("- Usage: \(percent.formatted(.number.precision(.fractionLength(1))))%")
			}
		}

		if !transcriptWarnings.isEmpty {
			lines.append("")
			lines.append("## Warnings")
			for warning in transcriptWarnings {
				lines.append("- \(warning)")
			}
		}

		return lines.joined(separator: "\n")
	}

	private func formattedDateLine(_ date: Date) -> String {
		date.formatted(date: .abbreviated, time: .shortened)
	}

	private func formattedOptionalDateLine(_ date: Date?) -> String {
		guard let date else { return "unknown" }
		return formattedDateLine(date)
	}

	private func inlineCode(_ text: String) -> String {
		"`\(text.replacingOccurrences(of: "`", with: "\\`"))`"
	}

	private func interruptSession() async {
		guard let serverConfiguration else { return }
		agentIdleTask?.cancel()
		isAgentBusy = false
		do {
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			try await client.interruptSession(sessionID: session.sessionID)
		} catch {
			print("Error interrupting session \(session.sessionID): \(error)")
		}
	}

	private func importPhotos(_ items: [PhotosPickerItem]) {
		let slotsAvailable = max(0, 8 - draftImages.count)
		for item in items.prefix(slotsAvailable) {
			let imageID = UUID()
			draftImages.append(ComposerImage(id: imageID, source: .library))

			Task {
				do {
					guard let data = try await item.loadTransferable(type: Data.self) else {
						markDraftImageFailed(id: imageID, error: "Couldn't load this image.")
						return
					}
					let result = try await OutgoingImageProcessor.process(data)
					completeDraftImage(id: imageID, with: result)
				} catch {
					markDraftImageFailed(id: imageID, error: error.localizedDescription)
				}
			}
		}
	}

	private func completeDraftImage(id: UUID, with result: ProcessedImageResult) {
		guard let index = draftImages.firstIndex(where: { $0.id == id }) else { return }
		draftImages[index].processingState = .ready
		draftImages[index].mimeType = result.mimeType
		draftImages[index].base64Data = result.base64Data
		draftImages[index].predictedAttachmentID = result.predictedAttachmentID
		draftImages[index].previewData = result.previewData
	}

	private func markDraftImageFailed(id: UUID, error: String) {
		guard let index = draftImages.firstIndex(where: { $0.id == id }) else { return }
		draftImages[index].processingState = .failed(error)
	}

	private func importImageData(_ data: Data, source: ComposerImage.Source) {
		guard draftImages.count < 8 else { return }
		let imageID = UUID()
		draftImages.append(ComposerImage(id: imageID, source: source))

		Task {
			do {
				let result = try await OutgoingImageProcessor.process(data)
				completeDraftImage(id: imageID, with: result)
			} catch {
				markDraftImageFailed(id: imageID, error: error.localizedDescription)
			}
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
				loadError = "This session doesn't have a local database ID yet."
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

	private func chooseUIDialogOption(_ index: Int) async {
		guard let dialog = currentUIDialog, dialog.isSelectorDialog else { return }
		guard let serverConfiguration else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		isUIDialogActionInFlight = true
		uiDialogActionError = nil
		defer { isUIDialogActionInFlight = false }

		do {
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			if dialog.selectedIndex != index {
				currentUIDialog = dialog.settingSelectedIndex(index)
				try await client.sendUIDialogAction(
					sessionID: session.sessionID,
					dialogID: dialog.id,
					action: .selectIndex(index: index)
				)
			}
			try await client.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: .submit
			)
		} catch {
			uiDialogActionError = error.localizedDescription
		}
	}

	private func updateUIDialogTextValue(_ value: String) {
		guard let dialog = currentUIDialog, dialog.isTextValueDialog else { return }
		guard dialog.resolvedTextValue != value else { return }
		currentUIDialog = dialog.settingTextValue(value)
		uiDialogActionError = nil
		uiDialogValueSyncTask?.cancel()

		guard let serverConfiguration else {
			uiDialogActionError = "No pimux server configured."
			uiDialogValueSyncTask = nil
			return
		}

		let sessionID = session.sessionID
		let dialogID = dialog.id
		uiDialogValueSyncTask = Task {
			do {
				try await Task.sleep(for: .milliseconds(150))
				let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
				try await client.sendUIDialogAction(
					sessionID: sessionID,
					dialogID: dialogID,
					action: .setValue(value: value)
				)
			} catch is CancellationError {
				return
			} catch {
				guard !Task.isCancelled else { return }
				await MainActor.run {
					if currentUIDialog?.id == dialogID {
						uiDialogActionError = error.localizedDescription
					}
				}
			}
		}
	}

	private func submitUIDialogTextValue() async {
		guard let dialog = currentUIDialog, dialog.isTextValueDialog else { return }
		guard let serverConfiguration else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		uiDialogValueSyncTask?.cancel()
		uiDialogValueSyncTask = nil
		isUIDialogActionInFlight = true
		uiDialogActionError = nil
		defer { isUIDialogActionInFlight = false }

		do {
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			try await client.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: .setValue(value: dialog.value ?? "")
			)
			try await client.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: .submit
			)
		} catch {
			uiDialogActionError = error.localizedDescription
		}
	}

	private func applyIncomingUIDialogState(_ state: PimuxSessionUIDialogState?) {
		let previousDialog = currentUIDialog
		let shouldPreserveOptimisticTextValue =
			previousDialog?.id == state?.id
			&& previousDialog?.isTextValueDialog == true
			&& state?.isTextValueDialog == true
			&& (uiDialogValueSyncTask != nil || isUIDialogActionInFlight)

		if shouldPreserveOptimisticTextValue, let state, let previousDialog {
			currentUIDialog = state.settingTextValue(previousDialog.resolvedTextValue)
		} else {
			uiDialogValueSyncTask?.cancel()
			uiDialogValueSyncTask = nil
			currentUIDialog = state
		}

		if state == nil || state?.id != previousDialog?.id {
			isUIDialogActionInFlight = false
		}
		uiDialogActionError = nil
	}

	private func uiDialogTextBinding(for dialog: PimuxSessionUIDialogState) -> Binding<String> {
		Binding(
			get: {
				guard let currentUIDialog, currentUIDialog.id == dialog.id else {
					return dialog.resolvedTextValue
				}
				return currentUIDialog.resolvedTextValue
			},
			set: { updateUIDialogTextValue($0) }
		)
	}

	private func cancelUIDialog() async {
		guard let dialog = currentUIDialog else { return }
		guard let serverConfiguration else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		uiDialogValueSyncTask?.cancel()
		uiDialogValueSyncTask = nil
		isUIDialogActionInFlight = true
		uiDialogActionError = nil
		defer { isUIDialogActionInFlight = false }

		do {
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			try await client.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: .cancel
			)
		} catch {
			uiDialogActionError = error.localizedDescription
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

// MARK: - Preview

#Preview("All message types") {
	let preview = {
		let db = AppDatabase.preview()
		let previewSessionID = "test-session-1"
		let previewAttachmentID = "img-preview"
		let _ = PreviewAttachmentFixture.installImageAttachment(sessionID: previewSessionID, attachmentID: previewAttachmentID)
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
				sessionID: previewSessionID,
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
					(type: "thinking", text: "Inspecting the supported roles and block kinds before updating the fixtures.\nLet me look at the Message.Role enum to see what cases exist.\nI see: user, assistant, toolResult, bashExecution, custom, branchSummary, compactionSummary, other.\nNow checking block types: text, thinking, toolCall, image, other.\nThe preview currently only has a user message and an assistant message.\nI need to add tool results, bash execution, branch summaries, compaction summaries.\nAlso need to show images and unknown/other role types.\nLet me also make sure the thinking block is long enough to test scrolling.\nI should verify each role gets the right icon and color.\nPlanning the full set of fixture messages now.\nI'll add about 12 messages covering all the cases.\nStarting with the edit now.", toolCallName: nil, mimeType: nil, attachmentID: nil),
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
					(type: "image", text: nil, toolCallName: nil, mimeType: "image/png", attachmentID: previewAttachmentID)
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
			PiSessionView(session: session, columnVisibility: .constant(.automatic))
		}
		.environment(\.appDatabase, db)
		.databaseContext(.readWrite { db.dbQueue })
	}()

	preview
}
