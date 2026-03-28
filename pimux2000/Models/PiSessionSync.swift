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
			async let remoteSessions = client.listSessions()
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
				session.lastMessage = nil
				session.lastMessageAt = lastMessageAt
				session.lastMessageRole = lastMessageRole
				if !remoteSession.hostConnected {
					session.isCliActive = false
				}
				session.contextTokensUsed = remoteSession.contextUsage?.usedTokens
				session.contextTokensMax = remoteSession.contextUsage?.maxTokens
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
					lastMessage: nil,
					lastMessageAt: lastMessageAt,
					lastMessageRole: lastMessageRole,
					lastReadMessageAt: lastMessageAt,
					contextTokensUsed: remoteSession.contextUsage?.usedTokens,
					contextTokensMax: remoteSession.contextUsage?.maxTokens,
					startedAt: remoteSession.createdAt,
					lastSeenAt: remoteSession.updatedAt
				)
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
		let existingPayloads = try messagePayloads(in: db, piSessionID: piSessionID)

		guard incomingPayloads != existingPayloads else { return }

		try Message.filter(Column("piSessionID") == piSessionID).deleteAll(db)

		for payload in incomingPayloads {
			var message = Message(
				piSessionID: piSessionID,
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
					position: blockPayload.position
				)
				try block.insert(db)
			}
		}
	}

	nonisolated private static func messagePayloads(from remoteMessages: [PimuxTranscriptMessage]) -> [MessagePayload] {
		remoteMessages.enumerated().map { index, remoteMessage in
			MessagePayload(
				role: Message.Role(remoteMessage.role),
				toolName: nil,
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
				return BlockPayload(type: block.type, text: normalizedText, toolCallName: nil, position: index)
			case "toolCall":
				guard let toolCallName = block.toolCallName?.trimmingCharacters(in: .whitespacesAndNewlines), !toolCallName.isEmpty else {
					return nil
				}
				return BlockPayload(type: "toolCall", text: nil, toolCallName: toolCallName, position: index)
			default:
				guard let normalizedText, !normalizedText.isEmpty else { return nil }
				return BlockPayload(type: block.type, text: normalizedText, toolCallName: block.toolCallName, position: index)
			}
		}

		if !explicitBlocks.isEmpty {
			return explicitBlocks
		}

		guard !remoteMessage.body.isEmpty else { return [] }
		return [BlockPayload(type: "text", text: remoteMessage.body, toolCallName: nil, position: 0)]
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
	let position: Int

	nonisolated init(type: String, text: String?, toolCallName: String?, position: Int) {
		self.type = type
		self.text = text
		self.toolCallName = toolCallName
		self.position = position
	}

	nonisolated init(_ block: MessageContentBlock) {
		self.type = block.type
		self.text = block.text
		self.toolCallName = block.toolCallName
		self.position = block.position
	}
}
