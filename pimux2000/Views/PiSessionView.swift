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

// MARK: - PiSessionView

struct PiSessionView: View {
	let session: PiSession

	// MARK: - Dependencies

	@Environment(\.appDatabase) private var appDatabase
	@Environment(\.pimuxServerClient) private var pimuxServerClient
	@Query<MessagesRequest> private var storedMessages: [MessageInfo]

	// MARK: - Live Transcript

	// Connection state for the live transcript stream.
	@State private var liveStreamState: LiveStreamState = .idle
	// Highest stream event sequence processed so stale or out-of-order events are ignored.
	@State private var lastStreamSequence: UInt64 = 0
	// Tracks explicit transcript reloads from the server.
	@State private var isLoadingMessages = false
	// Error shown when transcript loading fails.
	@State private var loadError: String?
	// Warnings returned alongside the current transcript snapshot.
	@State private var transcriptWarnings: [String] = []
	// Metadata describing whether the transcript is live, persisted, or reconstructed.
	@State private var transcriptFreshness: PimuxTranscriptFreshness?
	// Latest active/attached status reported for the session.
	@State private var transcriptActivity: PimuxSessionActivity?
	// Increment to force the transcript view to jump back to the bottom.
	@State private var transcriptForcePinToken = 0
	// Whether the transcript has been scrolled far enough up to show the jump-to-bottom affordance.
	@State private var isScrolledUp = false

	// MARK: - Composer & Sending

	// Current text in the composer.
	@State private var draftMessage = ""
	// Images attached in the composer, including any in-flight processing state.
	@State private var draftImages: [ComposerImage] = []
	// Optimistic local messages shown until the server transcript confirms them.
	@State private var pendingMessages: [PendingLocalMessage] = []
	// Prevents duplicate sends and drives composer loading state.
	@State private var isSendingMessage = false
	// Error surfaced by message sending or builtin command execution.
	@State private var sendError: String?
	// Server-reported working message shown while the agent is doing work.
	@State private var currentWorkingMessage: String?
	// Optimistic "waiting for the agent to start responding" state after sending a message.
	@State private var isAwaitingAgentActivity = false
	// Timeout task that clears optimistic agent-waiting state if no activity arrives.
	@State private var agentActivityConfirmationTask: Task<Void, Never>?

	// MARK: - Commands, Dialogs & UI State

	// Custom slash commands fetched for this session.
	@State private var customCommands: [PimuxSessionCommand] = []
	// Prevents overlapping custom-command fetches.
	@State private var isLoadingCustomCommands = false
	// Active interactive UI dialog pushed by the session.
	@State private var currentUIDialog: PimuxSessionUIDialogState?
	// Active terminal-only UI state shown as a banner above the composer.
	@State private var currentTerminalOnlyUIState: PimuxSessionTerminalOnlyUIState?
	// Disables UI dialog controls while a dialog action is being sent.
	@State private var isUIDialogActionInFlight = false
	// Error surfaced while interacting with the current UI dialog.
	@State private var uiDialogActionError: String?
	// Debounced task that syncs text-value dialog edits back to the server.
	@State private var uiDialogValueSyncTask: Task<Void, Never>?

	// MARK: - Navigation

	// Navigation target for showing message or session context.
	@State private var requestedMessageContext: MessageContextRoute?
	// Navigation target created by builtin commands like /new or /fork.
	@State private var requestedBuiltinSession: PiSession?

	// MARK: - Forking

	// Candidate transcript messages the user can fork from.
	@State private var availableForkMessages: [PimuxSessionForkMessage] = []
	// Controls presentation of the fork message picker sheet.
	@State private var isShowingForkMessagePicker = false
	// Loading state while a fork session is being created.
	@State private var isCreatingFork = false
	// Error surfaced during fork-related commands.
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
					isEnabled: pimuxServerClient != nil,
					isSending: isSendingMessage,
					isAgentActive: isAgentWorking,
					isWorking: isAgentWorking,
					workingMessage: composerWorkingMessage,
					errorMessage: sendError,
					loadArgumentCompletions: { commandName, argumentPrefix in
						await loadCommandArgumentCompletions(
							commandName: commandName,
							argumentPrefix: argumentPrefix
						)
					},
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
					onMoveSelection: { delta in
						Task { await moveUIDialogSelection(by: delta) }
					},
					onSubmitSelector: {
						Task { await submitUIDialogSelection() }
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
			.task(id: liveTaskKey, priority: .low) {
				await withTaskGroup(of: Void.self) { group in
					group.addTask {
						await liveMessagesLoop()
					}
					group.addTask {
						await loadCustomCommands()
					}
					await group.waitForAll()
				}
			}
			.onChange(of: transcriptActivity?.attached) { _, attached in
				guard attached == true else { return }
				Task { await loadCustomCommands(force: true) }
			}
	}

	private var liveTaskKey: String {
		"\(session.sessionID)|\(pimuxServerClient.map { String(describing: ObjectIdentifier($0)) } ?? "none")"
	}

	private var isAgentWorking: Bool {
		isAwaitingAgentActivity || transcriptActivity?.active == true || currentWorkingMessage != nil
	}

	private var composerWorkingMessage: String? {
		guard isAgentWorking else { return nil }
		return currentWorkingMessage
	}

	private func beginAwaitingAgentActivity() {
		currentWorkingMessage = nil
		isAwaitingAgentActivity = true
		agentActivityConfirmationTask?.cancel()
		agentActivityConfirmationTask = Task { @MainActor in
			try? await Task.sleep(for: .seconds(10))
			guard !Task.isCancelled else { return }
			isAwaitingAgentActivity = false
		}
	}

	private func confirmAgentActivityState() {
		agentActivityConfirmationTask?.cancel()
		agentActivityConfirmationTask = nil
		isAwaitingAgentActivity = false
	}

	private func updateTranscriptActivity(
		_ activity: PimuxSessionActivity,
		clearsOptimisticWork: Bool
	) {
		transcriptActivity = activity
		if activity.active {
			confirmAgentActivityState()
		} else {
			currentWorkingMessage = nil
			if clearsOptimisticWork {
				confirmAgentActivityState()
			}
		}
		persistActivity(activity)
	}

	private func normalizedWorkingMessage(from state: PimuxSessionUIState) -> String? {
		guard let workingMessage = state.workingMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !workingMessage.isEmpty else {
			return nil
		}
		return workingMessage
	}

	private func applyTranscriptSnapshotState(
		from response: PimuxSessionMessagesResponse,
		clearsOptimisticWork: Bool
	) {
		transcriptWarnings = response.warnings
		transcriptFreshness = response.freshness
		updateTranscriptActivity(response.activity, clearsOptimisticWork: clearsOptimisticWork)
	}

	private func clearTranscriptSnapshotState() {
		loadError = nil
		transcriptWarnings = []
		transcriptFreshness = nil
	}

	private var transcriptMessages: [TranscriptMessage] {
		storedMessages.map(TranscriptMessage.confirmed) + pendingMessages.map(TranscriptMessage.pending)
	}

	private var transcriptEmptyState: TranscriptEmptyState? {
		guard transcriptMessages.isEmpty else { return nil }
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
			ZStack(alignment: .bottom) {
				SessionTranscriptView(
					messages: transcriptMessages,
					sessionID: session.sessionID,
					emptyState: transcriptEmptyState,
					forcePinToken: transcriptForcePinToken,
					onRetry: { Task { await loadMessages() } },
					onOpenMessageContext: { requestedMessageContext = $0 },
					onScrollOffsetChanged: { offset in
						let scrolledUp = offset > 100
						if scrolledUp != isScrolledUp {
							withAnimation(.easeInOut(duration: 0.2)) {
								isScrolledUp = scrolledUp
							}
						}
					}
				)

				if isScrolledUp {
					Button {
						transcriptForcePinToken &+= 1
					} label: {
						Label("Scroll to bottom", systemImage: "chevron.down")
							.font(.footnote.weight(.medium))
							.padding(.horizontal, 14)
							.padding(.vertical, 8)
							.background(.thinMaterial, in: Capsule())
					}
					.padding(.bottom, 8)
					.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}
		#else
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 16) {
						if transcriptMessages.isEmpty {
							emptyStateView
						} else {
							ForEach(transcriptMessages) { message in
								switch message {
								case let .confirmed(messageInfo):
									TranscriptMessageView(
										messageInfo: messageInfo,
										sessionID: session.sessionID
									)
									.id(message.id)
								case let .pending(pendingMessage):
									PendingLocalMessageView(message: pendingMessage)
										.id(message.id)
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
				.onChange(of: transcriptMessagesScrollSignature) {
					scrollToBottom(proxy: proxy)
				}
			}
		#endif
	}

	private var confirmedUserMessageCount: Int {
		storedMessages.reduce(into: 0) { count, messageInfo in
			if messageInfo.message.role == .user {
				count += 1
			}
		}
	}

	private var transcriptMessagesScrollSignature: String {
		guard let lastMessage = transcriptMessages.last else { return "empty" }

		switch lastMessage {
		case let .confirmed(messageInfo):
			return confirmedScrollSignature(for: messageInfo)
		case let .pending(pendingMessage):
			return pendingScrollSignature(for: pendingMessage)
		}
	}

	private func confirmedScrollSignature(for messageInfo: MessageInfo) -> String {
		let count = String(transcriptMessages.count)
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
			String(transcriptMessages.count),
			"pending",
			pendingMessage.id.uuidString,
			pendingMessage.normalizedBody,
		]
		return components.joined(separator: "|")
	}

	private func liveMessagesLoop() async {
		guard let pimuxServerClient else {
			liveStreamState = .idle
			transcriptActivity = nil
			currentWorkingMessage = nil
			confirmAgentActivityState()
			clearTranscriptSnapshotState()
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
				liveStreamState = .connecting
				lastStreamSequence = 0
				try await pimuxServerClient.streamMessages(sessionID: session.sessionID) { event in
					await handleStreamEvent(event)
				}

				if Task.isCancelled { break }
				liveStreamState = .reconnecting
			} catch {
				if Task.isCancelled { break }
				liveStreamState = .reconnecting
				if storedMessages.isEmpty {
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
		case let .snapshot(sequence, sessionResponse):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			do {
				try await persistMessages(sessionResponse.messages)
				loadError = nil
			} catch {
				if storedMessages.isEmpty {
					loadError = error.localizedDescription
				}
				print("Error persisting live messages for \(session.sessionID): \(error)")
			}
			confirmAgentActivityState()
			reconcilePendingMessages(using: sessionResponse.messages)
			applyTranscriptSnapshotState(from: sessionResponse, clearsOptimisticWork: true)
			liveStreamState = .live
		case let .sessionState(sequence, connected, _, _):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			liveStreamState = connected ? .live : .reconnecting
			if !connected {
				currentWorkingMessage = nil
				updateTranscriptActivity(PimuxSessionActivity(active: false, attached: false), clearsOptimisticWork: true)
			}
		case let .uiState(sequence, state):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			currentWorkingMessage = normalizedWorkingMessage(from: state)
			confirmAgentActivityState()
		case let .uiDialogState(sequence, state):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			confirmAgentActivityState()
			applyIncomingUIDialogState(state)
		case let .terminalOnlyUiState(sequence, state):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			confirmAgentActivityState()
			currentTerminalOnlyUIState = state
		case let .keepalive(sequence, _):
			guard sequence > lastStreamSequence else { return }
			lastStreamSequence = sequence
			if liveStreamState == .connecting {
				liveStreamState = .live
			}
		}
	}

	private func scrollToBottom(proxy: ScrollViewProxy) {
		if let lastID = transcriptMessages.last?.id {
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
		guard let pimuxServerClient else {
			sendError = "No pimux server configured."
			return
		}

		let body = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
		let readyImages = draftImages.filter(\.isReady)
		guard !body.isEmpty || !readyImages.isEmpty else { return }

		if let builtinCommand = builtinCommand(for: body, readyImages: readyImages) {
			await executeBuiltinCommand(builtinCommand)
			return
		}

		let showsPendingMessage = !isRecognizedNonBuiltinSlashCommand(body)
		let pendingMessage = showsPendingMessage
			? PendingLocalMessage(
				body: body,
				images: readyImages,
				confirmedUserMessageBaseline: confirmedUserMessageCount
			)
			: nil
		if let pendingMessage {
			transcriptForcePinToken &+= 1
			pendingMessages.append(pendingMessage)
		}
		let savedDraftImages = draftImages
		draftMessage = ""
		draftImages = []
		isSendingMessage = true
		sendError = nil
		defer { isSendingMessage = false }

		do {
			let inputImages = readyImages.compactMap(\.inputImage)
			try await pimuxServerClient.sendMessage(sessionID: session.sessionID, body: body, images: inputImages)
			beginAwaitingAgentActivity()
		} catch {
			confirmAgentActivityState()
			currentWorkingMessage = nil
			if let pendingMessage {
				pendingMessages.removeAll { $0.id == pendingMessage.id }
			}
			draftMessage = body
			draftImages = savedDraftImages
			sendError = error.localizedDescription
			print("Error sending message for \(session.sessionID): \(error)")
		}
	}

	private func isRecognizedNonBuiltinSlashCommand(_ body: String) -> Bool {
		guard let context = SlashCommand.draftContext(for: body) else { return false }

		let commandName: String = switch context.phase {
		case let .commandName(prefix):
			prefix
		case let .arguments(commandName, _):
			commandName
		}

		guard let command = SlashCommand.command(
			named: commandName,
			from: SlashCommand.merged(custom: customCommands)
		) else {
			return false
		}

		return command.source != "builtin"
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

	private func executeBuiltinCommand(_ command: BuiltinSlashCommand) async {
		switch command {
		case .copy:
			executeCopyBuiltinCommand()
		case let .name(name):
			let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmedName.isEmpty else {
				sendError = "Usage: /name <name>"
				return
			}
			guard let pimuxServerClient else {
				sendError = "No pimux server configured."
				return
			}
			await runBuiltinCommand(restoreDraftOnFailure: true) {
				try await pimuxServerClient.setSessionName(sessionID: session.sessionID, name: trimmedName)
				draftMessage = ""
			}
		case let .compact(customInstructions):
			guard let pimuxServerClient else {
				sendError = "No pimux server configured."
				return
			}
			await runBuiltinCommand(restoreDraftOnFailure: true) {
				try await pimuxServerClient.compactSession(
					sessionID: session.sessionID,
					customInstructions: customInstructions
				)
				draftMessage = ""
				beginAwaitingAgentActivity()
			}
		case let .session(argument):
			guard argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				sendError = "Usage: /session"
				return
			}
			sendError = nil
			draftMessage = ""
			requestedMessageContext = sessionInfoRoute()
		case let .reload(argument):
			guard argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
				sendError = "Usage: /reload"
				return
			}
			guard let pimuxServerClient else {
				sendError = "No pimux server configured."
				return
			}
			await runBuiltinCommand(restoreDraftOnFailure: true) {
				try await pimuxServerClient.reloadSession(sessionID: session.sessionID)
				draftMessage = ""
				Task {
					try? await Task.sleep(for: .seconds(1))
					await loadCustomCommands()
				}
			}
		case .newSession:
			guard let pimuxServerClient else {
				sendError = "No pimux server configured."
				return
			}
			await runBuiltinCommand(restoreDraftOnFailure: true) {
				let newSessionID = try await pimuxServerClient.createNewSession(sessionID: session.sessionID)
				draftMessage = ""
				requestedBuiltinSession = makeTransientBuiltinSession(
					sessionID: newSessionID,
					summary: "New Session"
				)
			}
		case .fork:
			await loadForkMessages()
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
		for messageInfo in storedMessages.reversed() where messageInfo.message.role == .assistant {
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

	private func loadForkMessages() async {
		guard !isSendingMessage else { return }
		guard let pimuxServerClient else {
			sendError = "No pimux server configured."
			return
		}
		let savedDraftMessage = draftMessage
		let savedDraftImages = draftImages
		isSendingMessage = true
		sendError = nil
		defer { isSendingMessage = false }

		do {
			let messages = try await pimuxServerClient.getForkMessages(sessionID: session.sessionID)
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
		guard let pimuxServerClient else {
			forkCommandError = "No pimux server configured."
			return
		}

		isCreatingFork = true
		forkCommandError = nil
		defer { isCreatingFork = false }

		do {
			let newSessionID = try await pimuxServerClient.forkSession(
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
		let userCount = storedMessages.filter { $0.message.role == .user }.count
		let assistantCount = storedMessages.filter { $0.message.role == .assistant }.count
		let toolResultCount = storedMessages.filter { $0.message.role == .toolResult }.count
		let bashExecutionCount = storedMessages.filter { $0.message.role == .bashExecution }.count
		let customCount = storedMessages.filter { $0.message.role == .custom }.count
		let branchSummaryCount = storedMessages.filter { $0.message.role == .branchSummary }.count
		let compactionSummaryCount = storedMessages.filter { $0.message.role == .compactionSummary }.count
		let otherCount = storedMessages.count - userCount - assistantCount - toolResultCount - bashExecutionCount - customCount - branchSummaryCount - compactionSummaryCount

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
		lines.append("- Total Confirmed: \(storedMessages.count)")
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
		guard let pimuxServerClient else { return }
		currentWorkingMessage = nil
		updateTranscriptActivity(PimuxSessionActivity(active: false, attached: false), clearsOptimisticWork: true)
		do {
			try await pimuxServerClient.interruptSession(sessionID: session.sessionID)
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

	private func localSessionRowID(createIfNeeded: Bool = false) async throws -> Int64? {
		guard let appDatabase else { return nil }
		if createIfNeeded {
			return try await appDatabase.dbQueue.write { db in
				if let existingSession = try PiSession
					.filter(Column("sessionID") == session.sessionID)
					.fetchOne(db),
					let existingSessionID = existingSession.id
				{
					return existingSessionID
				}

				var localSession = session
				localSession.id = nil
				try localSession.insert(db)
				return localSession.id
			}
		}

		return try await appDatabase.dbQueue.read { db in
			try PiSession
				.filter(Column("sessionID") == session.sessionID)
				.fetchOne(db)?
				.id
		}
	}

	private func persistMessages(_ remoteMessages: [PimuxTranscriptMessage]) async throws {
		guard let appDatabase else { return }
		guard let sessionRowID = try await localSessionRowID(createIfNeeded: true) else {
			throw NSError(
				domain: "PiSessionView",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Couldn't create a local session row."]
			)
		}

		try await appDatabase.dbQueue.write { dbConn in
			try PiSessionSync.storeMessages(remoteMessages, piSessionID: sessionRowID, in: dbConn)
		}
	}

	private func loadMessages() async {
		guard !isLoadingMessages else { return }
		guard let pimuxServerClient else {
			loadError = "No pimux server configured."
			return
		}

		isLoadingMessages = true
		defer {
			isLoadingMessages = false
		}

		do {
			let response = try await pimuxServerClient.getMessages(sessionID: session.sessionID)
			try await persistMessages(response.messages)

			reconcilePendingMessages(using: response.messages)
			applyTranscriptSnapshotState(from: response, clearsOptimisticWork: false)
			loadError = nil
		} catch {
			loadError = error.localizedDescription
			print("Error loading messages for \(session.sessionID): \(error)")
		}
	}

	private func loadCustomCommands(force: Bool = false) async {
		guard let pimuxServerClient else { return }
		guard !isLoadingCustomCommands else { return }
		if !force, !customCommands.isEmpty { return }

		isLoadingCustomCommands = true
		defer { isLoadingCustomCommands = false }

		do {
			customCommands = try await pimuxServerClient.getCommands(sessionID: session.sessionID)
		} catch {
			// Non-critical; built-in commands still work. Retry once the live session reports attached.
			print("Failed to load custom commands for \(session.sessionID): \(error)")
		}
	}

	private func loadCommandArgumentCompletions(
		commandName: String,
		argumentPrefix: String
	) async -> [SlashCommandArgumentCompletion] {
		guard let pimuxServerClient else { return [] }

		do {
			let completions = try await pimuxServerClient.getCommandArgumentCompletions(
				sessionID: session.sessionID,
				commandName: commandName,
				argumentPrefix: argumentPrefix
			)
			return completions.map {
				SlashCommandArgumentCompletion(
					value: $0.value,
					label: $0.label,
					description: $0.description
				)
			}
		} catch {
			print(
				"Failed to load command argument completions for \(session.sessionID) /\(commandName): \(error)"
			)
			return []
		}
	}

	private func moveUIDialogSelection(by delta: Int) async {
		guard delta != 0 else { return }
		guard !isUIDialogActionInFlight else { return }
		guard let dialog = currentUIDialog, dialog.isSelectorDialog, !dialog.options.isEmpty else { return }
		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		let newIndex = max(0, min(dialog.selectedIndex + delta, dialog.options.count - 1))
		guard newIndex != dialog.selectedIndex else { return }

		currentUIDialog = dialog.settingSelectedIndex(newIndex)
		uiDialogActionError = nil

		do {
			try await pimuxServerClient.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: .move(direction: delta < 0 ? "up" : "down")
			)
		} catch {
			currentUIDialog = dialog
			uiDialogActionError = error.localizedDescription
		}
	}

	private func submitUIDialogSelection() async {
		guard let dialog = currentUIDialog, dialog.isSelectorDialog else { return }
		await chooseUIDialogOption(dialog.selectedIndex)
	}

	private func chooseUIDialogOption(_ index: Int) async {
		guard let dialog = currentUIDialog, dialog.isSelectorDialog else { return }
		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		isUIDialogActionInFlight = true
		uiDialogActionError = nil
		defer { isUIDialogActionInFlight = false }

		do {
			if dialog.selectedIndex != index {
				currentUIDialog = dialog.settingSelectedIndex(index)
				try await pimuxServerClient.sendUIDialogAction(
					sessionID: session.sessionID,
					dialogID: dialog.id,
					action: .selectIndex(index: index)
				)
			}
			try await pimuxServerClient.sendUIDialogAction(
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

		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			uiDialogValueSyncTask = nil
			return
		}

		let sessionID = session.sessionID
		let dialogID = dialog.id
		uiDialogValueSyncTask = Task {
			do {
				try await Task.sleep(for: .milliseconds(150))
				try await pimuxServerClient.sendUIDialogAction(
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
		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		uiDialogValueSyncTask?.cancel()
		uiDialogValueSyncTask = nil
		isUIDialogActionInFlight = true
		uiDialogActionError = nil
		defer { isUIDialogActionInFlight = false }

		do {
			try await pimuxServerClient.sendUIDialogAction(
				sessionID: session.sessionID,
				dialogID: dialog.id,
				action: .setValue(value: dialog.value ?? "")
			)
			try await pimuxServerClient.sendUIDialogAction(
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
		guard let pimuxServerClient else {
			uiDialogActionError = "No pimux server configured."
			return
		}

		uiDialogValueSyncTask?.cancel()
		uiDialogValueSyncTask = nil
		isUIDialogActionInFlight = true
		uiDialogActionError = nil
		defer { isUIDialogActionInFlight = false }

		do {
			try await pimuxServerClient.sendUIDialogAction(
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
}

// MARK: - Preview

#Preview("All message types") {
	let preview = {
		let db = AppDatabase.preview()
		let previewSessionID = "test-session-1"
		let previewAttachmentID = "img-preview"
		_ = PreviewAttachmentFixture.installImageAttachment(sessionID: previewSessionID, attachmentID: previewAttachmentID)
		try! db.saveServerURL("http://localhost:3000")

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
					(type: "text", text: "Can you help me expand this preview so it covers more transcript cases?", toolCallName: nil, mimeType: nil, attachmentID: nil),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .assistant,
				position: 1,
				createdAt: now.addingTimeInterval(30),
				blocks: [
					(type: "thinking", text: "Inspecting the supported roles and block kinds before updating the fixtures.\nLet me look at the Message.Role enum to see what cases exist.\nI see: user, assistant, toolResult, bashExecution, custom, branchSummary, compactionSummary, other.\nNow checking block types: text, thinking, toolCall, image, other.\nThe preview currently only has a user message and an assistant message.\nI need to add tool results, bash execution, branch summaries, compaction summaries.\nAlso need to show images and unknown/other role types.\nLet me also make sure the thinking block is long enough to test scrolling.\nI should verify each role gets the right icon and color.\nPlanning the full set of fixture messages now.\nI'll add about 12 messages covering all the cases.\nStarting with the edit now.", toolCallName: nil, mimeType: nil, attachmentID: nil),
					(type: "toolCall", text: "pimux2000/Views/PiSessionView.swift (offset=785, limit=140)", toolCallName: "read", mimeType: nil, attachmentID: nil),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .toolResult,
				toolName: "read",
				position: 2,
				createdAt: now.addingTimeInterval(60),
				blocks: [
					(type: "text", text: "Found the preview block at the bottom of `PiSessionView.swift`:\n\n```swift\nprivate var displayedMessagesScrollSignature: String {\n    ...\n}\n```\n\nIt currently renders text, thinking, tool calls, images, and fallback blocks.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .assistant,
				position: 3,
				createdAt: now.addingTimeInterval(90),
				blocks: [
					(type: "toolCall", text: "$ xcodebuild -project pimux2000.xcodeproj -scheme pimux2000 ENABLE_PREVIEWS=YES\n\ntimeout: 120s", toolCallName: "bash", mimeType: nil, attachmentID: nil),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .bashExecution,
				position: 4,
				createdAt: now.addingTimeInterval(120),
				blocks: [
					(type: "text", text: "$ xcodebuild -scheme pimux2000 ENABLE_PREVIEWS=YES\nSwiftCompile PiSessionView.swift\n** BUILD SUCCEEDED **", toolCallName: nil, mimeType: nil, attachmentID: nil),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .assistant,
				position: 5,
				createdAt: now.addingTimeInterval(150),
				blocks: [
					(type: "toolCall", text: "pimux2000/Views/PiSessionView.swift\n\nsingle replacement", toolCallName: "edit", mimeType: nil, attachmentID: nil),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .toolResult,
				toolName: "edit",
				position: 6,
				createdAt: now.addingTimeInterval(180),
				blocks: [
					(type: "text", text: "Applied 1 edit to `pimux2000/Views/PiSessionView.swift`:\n\n- split the scroll signature into smaller helper functions\n- expanded preview fixtures to cover tool calls and summary roles\n- kept the image attachment placeholder in place", toolCallName: nil, mimeType: nil, attachmentID: nil),
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
					(type: "image", text: nil, toolCallName: nil, mimeType: "image/png", attachmentID: previewAttachmentID),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .custom,
				position: 8,
				createdAt: now.addingTimeInterval(240),
				blocks: [
					(type: "other", text: "Custom extension note: the live stream briefly detached, so the app fell back to a persisted snapshot.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .branchSummary,
				position: 9,
				createdAt: now.addingTimeInterval(270),
				blocks: [
					(type: "text", text: "Created branch `preview-message-fixtures` from `main` and staged the updated transcript preview data.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .compactionSummary,
				position: 10,
				createdAt: now.addingTimeInterval(300),
				blocks: [
					(type: "text", text: "Earlier setup discussion was compacted into a shorter summary so the preview still shows long-running session behavior.", toolCallName: nil, mimeType: nil, attachmentID: nil),
				]
			)

			try insertMessage(
				for: sessionRowID,
				role: .other("systemNote"),
				position: 11,
				createdAt: now.addingTimeInterval(330),
				blocks: [
					(type: "text", text: "Unknown roles render with fallback styling so future transcript events remain visible.", toolCallName: nil, mimeType: nil, attachmentID: nil),
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
		.environment(\.pimuxServerClient, try! PimuxServerClient(baseURL: "http://localhost:3000"))
		.databaseContext(.readWrite { db.dbQueue })
	}()

	preview
}
