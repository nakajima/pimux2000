import SwiftUI
#if canImport(UIKit) && !os(macOS)
	import UIKit
#endif

// MARK: - Builtin Slash Commands

extension PiSessionView {
	func isRecognizedNonBuiltinSlashCommand(_ body: String) -> Bool {
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

	enum BuiltinSlashCommand {
		case copy
		case name(String)
		case compact(String?)
		case session(String)
		case reload(String)
		case newSession
		case fork
	}

	func builtinCommand(for body: String, readyImages: [ComposerImage]) -> BuiltinSlashCommand? {
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

	func executeBuiltinCommand(_ command: BuiltinSlashCommand) async {
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

	func runBuiltinCommand(
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

	func executeCopyBuiltinCommand() {
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

	func lastAssistantTextToCopy() -> String? {
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

	// MARK: - Forking

	func loadForkMessages() async {
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

	func createFork(from message: PimuxSessionForkMessage) async {
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

	// MARK: - Helpers

	func makeTransientBuiltinSession(sessionID: String, summary: String) -> PiSession {
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

	func forkedSessionSummary(from text: String) -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return "Fork" }
		let prefix = String(trimmed.prefix(48))
		return trimmed.count > 48 ? "Fork: \(prefix)…" : "Fork: \(prefix)"
	}

	func sessionInfoRoute() -> MessageContextRoute {
		MessageContextRoute(
			title: "Session Info",
			text: sessionInfoMarkdown(),
			role: .other("sessionInfo")
		)
	}

	func sessionInfoMarkdown() -> String {
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

	func formattedDateLine(_ date: Date) -> String {
		date.formatted(date: .abbreviated, time: .shortened)
	}

	func formattedOptionalDateLine(_ date: Date?) -> String {
		guard let date else { return "unknown" }
		return formattedDateLine(date)
	}

	func inlineCode(_ text: String) -> String {
		"`\(text.replacingOccurrences(of: "`", with: "\\`"))`"
	}
}
