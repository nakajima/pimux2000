import Foundation
import GRDB
import GRDBQuery

struct PiSessionSync {
	var dbContext: DatabaseContext

	func sync() async {
		let serverConfiguration: ServerConfiguration?
		do {
			serverConfiguration = try await dbContext.reader.read { db in
				try CurrentServerConfigurationRequest().fetch(db)
			}
		} catch {
			print("Error reading server configuration: \(error)")
			return
		}

		guard let serverConfiguration else { return }

		do {
			let client = try PimuxServerClient(baseURL: serverConfiguration.serverURL)
			async let remoteHosts = client.listHosts()
			async let remoteSessions = client.listAllSessions()
			let (hosts, sessions) = try await (remoteHosts, remoteSessions)

			try await dbContext.writer.write { db in
				try Self.store(remoteHosts: hosts, remoteSessions: sessions, in: db)
			}
		} catch {
			print("Error syncing \(serverConfiguration.serverURL): \(error)")
		}
	}

	nonisolated static func store(
		remoteHosts: [PimuxHostSessions],
		remoteSessions: [PimuxListedSession],
		in db: Database
	) throws {
		var latestHostUpdates: [String: Date] = [:]
		let remoteLocations = Set(remoteHosts.map(\.location)).union(remoteSessions.map(\.hostLocation))
		let now = Date()

		for remoteHost in remoteHosts {
			if let latestSessionUpdate = remoteHost.sessions.map(\.updatedAt).max() {
				latestHostUpdates[remoteHost.location] = max(
					latestHostUpdates[remoteHost.location] ?? Date.distantPast,
					latestSessionUpdate
				)
			}
			if let lastSeenAt = remoteHost.lastSeenAt {
				latestHostUpdates[remoteHost.location] = max(
					latestHostUpdates[remoteHost.location] ?? Date.distantPast,
					lastSeenAt
				)
			}
		}

		for remoteSession in remoteSessions {
			latestHostUpdates[remoteSession.hostLocation] = max(
				latestHostUpdates[remoteSession.hostLocation] ?? Date.distantPast,
				remoteSession.updatedAt
			)
		}

		let existingHosts = try Host.fetchAll(db)
		var existingHostsByLocation = Dictionary(uniqueKeysWithValues: existingHosts.map { ($0.location, $0) })
		var hostIDByLocation: [String: Int64] = [:]

		for location in remoteLocations.sorted() {
			let fallbackUpdatedAt = existingHostsByLocation[location]?.updatedAt ?? now
			let updatedAt = latestHostUpdates[location] ?? fallbackUpdatedAt
			if var host = existingHostsByLocation.removeValue(forKey: location) {
				host.updatedAt = updatedAt
				try host.update(db)
				if let id = host.id {
					hostIDByLocation[location] = id
				}
			} else {
				var host = Host(id: nil, location: location, createdAt: now, updatedAt: updatedAt)
				try host.insert(db)
				if let id = host.id {
					hostIDByLocation[location] = id
				}
			}
		}

		let staleHostIDs = existingHostsByLocation.values.compactMap(\.id)
		if !staleHostIDs.isEmpty {
			_ = try Host.filter(staleHostIDs.contains(Column("id"))).deleteAll(db)
		}

		let activeSessionIDs = Set(
			remoteHosts
				.filter(\.connected)
				.flatMap(\.sessions)
				.map(\.id)
		)

		let canonicalRemoteSessions = canonicalRemoteSessions(from: remoteSessions)
		let existingSessions = try PiSession.fetchAll(db)
		var existingSessionsByID = Dictionary(uniqueKeysWithValues: existingSessions.map { ($0.sessionID, $0) })

		for remoteSession in canonicalRemoteSessions {
			guard let hostID = hostIDByLocation[remoteSession.hostLocation] else { continue }

			let lastMessageAt = max(remoteSession.lastUserMessageAt, remoteSession.lastAssistantMessageAt)
			let lastMessageRole = remoteSession.lastAssistantMessageAt >= remoteSession.lastUserMessageAt
				? "assistant"
				: "user"

			if var session = existingSessionsByID.removeValue(forKey: remoteSession.id) {
				session.hostID = hostID
				session.summary = remoteSession.summary
				session.sessionFile = nil
				session.model = remoteSession.model
				session.cwd = remoteSession.cwd
				session.lastMessage = nil
				session.lastUserMessageAt = remoteSession.lastUserMessageAt
				session.lastMessageAt = lastMessageAt
				session.lastMessageRole = lastMessageRole
				session.isCliActive = activeSessionIDs.contains(remoteSession.id)
				session.contextTokensUsed = remoteSession.contextUsage?.usedTokens
				session.contextTokensMax = remoteSession.contextUsage?.maxTokens
				session.supportsImages = remoteSession.supportsImages
				session.startedAt = remoteSession.createdAt
				session.lastSeenAt = remoteSession.updatedAt
				try session.update(db)
			} else {
				var session = PiSession(
					id: nil,
					hostID: hostID,
					summary: remoteSession.summary,
					sessionID: remoteSession.id,
					sessionFile: nil,
					model: remoteSession.model,
					cwd: remoteSession.cwd,
					lastMessage: nil,
					lastUserMessageAt: remoteSession.lastUserMessageAt,
					lastMessageAt: lastMessageAt,
					lastMessageRole: lastMessageRole,
					lastReadMessageAt: lastMessageAt,
					contextTokensUsed: remoteSession.contextUsage?.usedTokens,
					contextTokensMax: remoteSession.contextUsage?.maxTokens,
					supportsImages: remoteSession.supportsImages,
					startedAt: remoteSession.createdAt,
					lastSeenAt: remoteSession.updatedAt
				)
				session.isCliActive = activeSessionIDs.contains(remoteSession.id)
				try session.insert(db)
			}
		}

		let staleSessionIDs = existingSessionsByID.values.compactMap(\.id)
		if !staleSessionIDs.isEmpty {
			_ = try PiSession.filter(staleSessionIDs.contains(Column("id"))).deleteAll(db)
		}
	}

	nonisolated private static func canonicalRemoteSessions(from remoteSessions: [PimuxListedSession]) -> [PimuxListedSession] {
		var sessionsByID: [String: PimuxListedSession] = [:]

		for remoteSession in remoteSessions {
			guard let existing = sessionsByID[remoteSession.id] else {
				sessionsByID[remoteSession.id] = remoteSession
				continue
			}

			if shouldPrefer(remoteSession, over: existing) {
				sessionsByID[remoteSession.id] = remoteSession
			}
		}

		return sessionsByID.values.sorted { $0.id < $1.id }
	}

	nonisolated private static func shouldPrefer(_ candidate: PimuxListedSession, over existing: PimuxListedSession) -> Bool {
		if candidate.hostConnected != existing.hostConnected {
			return candidate.hostConnected && !existing.hostConnected
		}

		if candidate.updatedAt != existing.updatedAt {
			return candidate.updatedAt > existing.updatedAt
		}

		if candidate.lastAssistantMessageAt != existing.lastAssistantMessageAt {
			return candidate.lastAssistantMessageAt > existing.lastAssistantMessageAt
		}

		if candidate.lastUserMessageAt != existing.lastUserMessageAt {
			return candidate.lastUserMessageAt > existing.lastUserMessageAt
		}

		return candidate.hostLocation < existing.hostLocation
	}

	nonisolated static func storeMessages(_ remoteMessages: [PimuxTranscriptMessage], piSessionID: Int64, in db: Database) throws {
		let incomingPayloads = messagePayloads(from: remoteMessages)

		if !incomingPayloads.isEmpty && incomingPayloads.allSatisfy({ $0.serverMessageID != nil }) {
			try storeMessagesIncrementally(incomingPayloads, piSessionID: piSessionID, in: db)
		} else {
			let existingPayloads = try messagePayloads(in: db, piSessionID: piSessionID)
			guard incomingPayloads != existingPayloads else { return }
			try replaceAllMessages(incomingPayloads, piSessionID: piSessionID, in: db)
		}
	}

	nonisolated private static func storeMessagesIncrementally(
		_ incomingPayloads: [MessagePayload],
		piSessionID: Int64,
		in db: Database
	) throws {
		let existingMessages = try Message
			.filter(Column("piSessionID") == piSessionID)
			.fetchAll(db)

		let existingMessageIDs = existingMessages.compactMap(\.id)
		let existingBlocks: [MessageContentBlock]
		if existingMessageIDs.isEmpty {
			existingBlocks = []
		} else {
			existingBlocks = try MessageContentBlock
				.filter(existingMessageIDs.contains(Column("messageID")))
				.order(Column("position").asc)
				.fetchAll(db)
		}
		let blocksByMessageID = Dictionary(grouping: existingBlocks, by: \.messageID)

		var existingByServerID: [Int: (message: Message, payload: MessagePayload)] = [:]
		for message in existingMessages {
			if let serverID = message.serverMessageID {
				existingByServerID[serverID] = (
					message: message,
					payload: MessagePayload(
						serverMessageID: serverID,
						role: message.role,
						toolName: message.toolName,
						position: message.position,
						createdAt: message.createdAt,
						blocks: (blocksByMessageID[message.id ?? -1] ?? []).map(BlockPayload.init)
					)
				)
			}
		}

		let incomingServerIDs = Set(incomingPayloads.compactMap(\.serverMessageID))

		// Delete messages no longer in the transcript
		let staleMessageIDs = existingMessages.compactMap { msg -> Int64? in
			guard let serverID = msg.serverMessageID, incomingServerIDs.contains(serverID) else {
				return msg.id
			}
			return nil
		}
		if !staleMessageIDs.isEmpty {
			try MessageContentBlock.filter(staleMessageIDs.contains(Column("messageID"))).deleteAll(db)
			try Message.filter(staleMessageIDs.contains(Column("id"))).deleteAll(db)
		}

		// Insert or update incoming messages
		for payload in incomingPayloads {
			guard let serverID = payload.serverMessageID else { continue }

			if let existing = existingByServerID[serverID] {
				guard existing.payload != payload else { continue }
				guard let msgID = existing.message.id else { continue }

				var updated = existing.message
				updated.role = payload.role
				updated.toolName = payload.toolName
				updated.position = payload.position
				updated.createdAt = payload.createdAt
				try updated.update(db)

				try MessageContentBlock.filter(Column("messageID") == msgID).deleteAll(db)
				for blockPayload in payload.blocks {
					var block = MessageContentBlock(
						messageID: msgID,
						type: blockPayload.type,
						text: blockPayload.text,
						toolCallName: blockPayload.toolCallName,
						mimeType: blockPayload.mimeType,
						attachmentID: blockPayload.attachmentID,
						position: blockPayload.position
					)
					try block.insert(db)
				}
			} else {
				var message = Message(
					piSessionID: piSessionID,
					serverMessageID: serverID,
					role: payload.role,
					toolName: payload.toolName,
					position: payload.position,
					createdAt: payload.createdAt
				)
				try message.insert(db)

				for blockPayload in payload.blocks {
					var block = MessageContentBlock(
						messageID: message.id!,
						type: blockPayload.type,
						text: blockPayload.text,
						toolCallName: blockPayload.toolCallName,
						mimeType: blockPayload.mimeType,
						attachmentID: blockPayload.attachmentID,
						position: blockPayload.position
					)
					try block.insert(db)
				}
			}
		}
	}

	nonisolated private static func replaceAllMessages(
		_ payloads: [MessagePayload],
		piSessionID: Int64,
		in db: Database
	) throws {
		try Message.filter(Column("piSessionID") == piSessionID).deleteAll(db)

		for payload in payloads {
			var message = Message(
				piSessionID: piSessionID,
				serverMessageID: payload.serverMessageID,
				role: payload.role,
				toolName: payload.toolName,
				position: payload.position,
				createdAt: payload.createdAt
			)
			try message.insert(db)

			for blockPayload in payload.blocks {
				var block = MessageContentBlock(
					messageID: message.id!,
					type: blockPayload.type,
					text: blockPayload.text,
					toolCallName: blockPayload.toolCallName,
					mimeType: blockPayload.mimeType,
					attachmentID: blockPayload.attachmentID,
					position: blockPayload.position
				)
				try block.insert(db)
			}
		}
	}

	nonisolated private static func messagePayloads(from remoteMessages: [PimuxTranscriptMessage]) -> [MessagePayload] {
		remoteMessages.enumerated().map { index, remoteMessage in
			MessagePayload(
				serverMessageID: remoteMessage.messageId,
				role: Message.Role(remoteMessage.role),
				toolName: {
					guard let toolName = remoteMessage.toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !toolName.isEmpty else {
						return nil
					}
					return toolName
				}(),
				position: index,
				createdAt: remoteMessage.createdAt,
				blocks: blockPayloads(from: remoteMessage)
			)
		}
	}

	nonisolated private static func blockPayloads(from remoteMessage: PimuxTranscriptMessage) -> [BlockPayload] {
		let explicitBlocks = remoteMessage.blocks.enumerated().compactMap { (index, block) -> BlockPayload? in
			let normalizedText = block.text?.trimmingCharacters(in: .whitespacesAndNewlines)
			switch block.type {
			case "text", "thinking", "other":
				guard let normalizedText, !normalizedText.isEmpty else { return nil }
				return BlockPayload(type: block.type, text: normalizedText, toolCallName: nil, mimeType: nil, attachmentID: nil, position: index)
			case "toolCall":
				guard let toolCallName = block.toolCallName?.trimmingCharacters(in: .whitespacesAndNewlines), !toolCallName.isEmpty else {
					return nil
				}
				return BlockPayload(type: "toolCall", text: normalizedText, toolCallName: toolCallName, mimeType: nil, attachmentID: nil, position: index)
			case "image":
				return BlockPayload(
					type: "image",
					text: nil,
					toolCallName: nil,
					mimeType: block.mimeType,
					attachmentID: block.attachmentId,
					position: index
				)
			default:
				guard let normalizedText, !normalizedText.isEmpty else { return nil }
				return BlockPayload(type: block.type, text: normalizedText, toolCallName: block.toolCallName, mimeType: block.mimeType, attachmentID: block.attachmentId, position: index)
			}
		}

		if !explicitBlocks.isEmpty {
			return explicitBlocks
		}

		guard !remoteMessage.body.isEmpty else { return [] }
		return [BlockPayload(type: "text", text: remoteMessage.body, toolCallName: nil, mimeType: nil, attachmentID: nil, position: 0)]
	}

	nonisolated private static func messagePayloads(in db: Database, piSessionID: Int64) throws -> [MessagePayload] {
		let messages = try Message
			.filter(Column("piSessionID") == piSessionID)
			.order(Column("position").asc)
			.fetchAll(db)

		let messageIDs = messages.compactMap(\.id)
		let blocks: [MessageContentBlock]
		if messageIDs.isEmpty {
			blocks = []
		} else {
			blocks = try MessageContentBlock
				.filter(messageIDs.contains(Column("messageID")))
				.order(Column("position").asc)
				.fetchAll(db)
		}

		let blocksByMessageID = Dictionary(grouping: blocks, by: \.messageID)

		return messages.map { message in
			MessagePayload(
				serverMessageID: message.serverMessageID,
				role: message.role,
				toolName: message.toolName,
				position: message.position,
				createdAt: message.createdAt,
				blocks: (blocksByMessageID[message.id ?? -1] ?? []).map(BlockPayload.init)
			)
		}
	}
}

private struct MessagePayload: Equatable {
	let serverMessageID: Int?
	let role: Message.Role
	let toolName: String?
	let position: Int
	let createdAt: Date
	let blocks: [BlockPayload]
}

private struct BlockPayload: Equatable {
	let type: String
	let text: String?
	let toolCallName: String?
	let mimeType: String?
	let attachmentID: String?
	let position: Int

	nonisolated init(type: String, text: String?, toolCallName: String?, mimeType: String?, attachmentID: String?, position: Int) {
		self.type = type
		self.text = text
		self.toolCallName = toolCallName
		self.mimeType = mimeType
		self.attachmentID = attachmentID
		self.position = position
	}

	nonisolated init(_ block: MessageContentBlock) {
		self.type = block.type
		self.text = block.text
		self.toolCallName = block.toolCallName
		self.mimeType = block.mimeType
		self.attachmentID = block.attachmentID
		self.position = block.position
	}
}
