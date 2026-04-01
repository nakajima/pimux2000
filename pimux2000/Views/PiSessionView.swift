import GRDB
import GRDBQuery
import PhotosUI
import SwiftUI

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
	@State private var isUIDialogActionInFlight = false
	@State private var uiDialogActionError: String?
	@State private var agentIdleTask: Task<Void, Never>?
	@State private var deferredStartupGeneration = 0
	@State private var deferredStartupRequestID = 0
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
					isSendingAction: isUIDialogActionInFlight,
					errorMessage: uiDialogActionError,
					onSelectOption: { index in
						Task { await chooseUIDialogOption(index) }
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
			uiDialogActionError = nil
			isUIDialogActionInFlight = false
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
			currentUIDialog = state
			uiDialogActionError = nil
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
		guard let dialog = currentUIDialog else { return }
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
				currentUIDialog = PimuxSessionUIDialogState(
					id: dialog.id,
					kind: dialog.kind,
					title: dialog.title,
					message: dialog.message,
					options: dialog.options,
					selectedIndex: index
				)
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

	private func cancelUIDialog() async {
		guard let dialog = currentUIDialog else { return }
		guard let serverConfiguration else {
			uiDialogActionError = "No pimux server configured."
			return
		}

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

private struct SessionUIDialogOverlay: View {
	let dialog: PimuxSessionUIDialogState
	let isSendingAction: Bool
	let errorMessage: String?
	let onSelectOption: (Int) -> Void
	let onCancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(dialog.title)
				.font(.headline)

			if !dialog.message.isEmpty {
				Text(dialog.message)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}

			VStack(spacing: 10) {
				ForEach(Array(dialog.options.enumerated()), id: \.offset) { index, option in
					Button {
						onSelectOption(index)
					} label: {
						HStack(spacing: 12) {
							Text(option)
								.fontWeight(dialog.selectedIndex == index ? .semibold : .regular)
							Spacer()
							if dialog.selectedIndex == index {
								Image(systemName: "checkmark.circle.fill")
									.foregroundStyle(.tint)
							}
						}
						.padding(.horizontal, 14)
						.padding(.vertical, 12)
						.frame(maxWidth: .infinity)
						.background(
							dialog.selectedIndex == index
								? AnyShapeStyle(.tint.opacity(0.14))
								: AnyShapeStyle(.regularMaterial),
							in: RoundedRectangle(cornerRadius: 12)
						)
						.overlay(
							RoundedRectangle(cornerRadius: 12)
								.stroke(dialog.selectedIndex == index ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
						)
					}
					.buttonStyle(.plain)
					.disabled(isSendingAction)
				}
			}

			if isSendingAction {
				HStack(spacing: 8) {
					ProgressView()
						.controlSize(.small)
					Text("Sending action…")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			if let errorMessage, !errorMessage.isEmpty {
				Text(verbatim: errorMessage)
					.font(.caption)
					.foregroundStyle(.red)
			}

			HStack {
				Spacer()
				Button("Cancel", role: .cancel, action: onCancel)
					.disabled(isSendingAction)
			}
		}
		.padding(20)
		.frame(maxWidth: 420)
		.background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18))
		.overlay(
			RoundedRectangle(cornerRadius: 18)
				.stroke(Color.secondary.opacity(0.18), lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.12), radius: 24, y: 8)
	}
}

// MARK: - Preview

#Preview("Session UI confirm dialog") {
	ZStack {
		Color(.systemBackground)
		SessionUIDialogOverlay(
			dialog: PimuxSessionUIDialogState(
				id: "confirm-1",
				kind: "confirm",
				title: "Pimux Live Confirm Test",
				message: "Choose from either the Pi TUI or the iOS app. Does this confirm stay mirrored and resolve correctly?",
				options: ["Yes", "No"],
				selectedIndex: 0
			),
			isSendingAction: false,
			errorMessage: nil,
			onSelectOption: { _ in },
			onCancel: {}
		)
		.padding()
	}
}

#Preview("Session UI select dialog") {
	ZStack {
		Color(.systemBackground)
		SessionUIDialogOverlay(
			dialog: PimuxSessionUIDialogState(
				id: "select-1",
				kind: "select",
				title: "Pimux Live Select Test",
				message: "",
				options: ["Alpha", "Beta", "Gamma"],
				selectedIndex: 1
			),
			isSendingAction: false,
			errorMessage: nil,
			onSelectOption: { _ in },
			onCancel: {}
		)
		.padding()
	}
}

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
