import Foundation
import GRDB
import GRDBQuery
import Pi

struct PiSessionSync {
	var dbContext: DatabaseContext

	func sync() async {
		let hosts: [Host]
		do {
			hosts = try await self.dbContext.reader.read { db in
				try Host.all().fetchAll(db)
			}
		} catch {
			print("Error reading hosts: \(error)")
			return
		}

		await withTaskGroup { group in
			for host in hosts {
				group.addTask {
					do {
						try await self.sync(host: host)
					} catch let error as PiError {
						if case let .commandFailed(message) = error,
							message == "The remote server is too old. Please update it from pimux2000." {
							return
						}
						print("Error syncing \(host.sshTarget): \(error)")
					} catch {
						print("Error syncing \(host.sshTarget): \(error)")
					}
				}
			}
		}
	}

	private nonisolated func sync(host: Host) async throws {
		guard let hostID = host.id else { return }

		let client = PiServerClient(serverURL: host.serverURL)
		let remoteSessions = try await client.listSessions().filter(Self.shouldSync)

		for remoteSession in remoteSessions {
			try await self.sync(remoteSession: remoteSession, hostID: hostID, client: client)
		}

		let keptSessionIDs = Set(remoteSessions.compactMap { $0["sessionId"]?.stringValue })
		try await self.cleanupStaleSessions(hostID: hostID, keepingSessionIDs: keptSessionIDs)
	}

	private func sync(remoteSession: JSONObject, hostID: Int64, client: PiServerClient) async throws {
		let sessionId = remoteSession["sessionId"]?.stringValue ?? ""
		guard !sessionId.isEmpty else { return }

		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

		let startedAt = remoteSession["startedAt"]?.stringValue.flatMap { formatter.date(from: $0) } ?? Date.distantPast
		let lastSeenAt = remoteSession["lastSeenAt"]?.stringValue.flatMap { formatter.date(from: $0) } ?? Date.distantPast
		let lastMessageAt = remoteSession["lastMessageAt"]?.stringValue.flatMap { formatter.date(from: $0) }

		let modelString: String
		if let model = remoteSession["model"]?.objectValue {
			let provider = model["provider"]?.stringValue ?? ""
			let id = model["id"]?.stringValue ?? ""
			modelString = "\(provider)/\(id)"
		} else {
			modelString = "unknown model"
		}

		let summary = remoteSession["workSummary"]?.stringValue
			?? remoteSession["sessionName"]?.stringValue
			?? Self.cwdFolderName(remoteSession["cwd"]?.stringValue)
			?? sessionId

		let session = PiSession(
			hostID: hostID,
			summary: summary,
			sessionID: sessionId,
			sessionFile: remoteSession["sessionFile"]?.stringValue,
			model: modelString,
			lastMessage: remoteSession["lastMessage"]?.stringValue,
			lastMessageAt: lastMessageAt,
			lastMessageRole: remoteSession["lastMessageRole"]?.stringValue,
			startedAt: startedAt,
			lastSeenAt: lastSeenAt
		)

		let piSessionID = try await self.dbContext.writer.write { db -> Int64 in
			var session = session
			try session.upsert(db)
			guard let currentSessionID = try PiSession
				.filter(Column("sessionID") == sessionId)
				.fetchOne(db)?.id else {
				throw NSError(
					domain: "PiSessionSync",
					code: 1,
					userInfo: [NSLocalizedDescriptionKey: "Failed to resolve synced session ID for \(sessionId)"]
				)
			}
			return currentSessionID
		}

		// Sync messages if we have a session file
		guard let sessionFile = remoteSession["sessionFile"]?.stringValue else { return }
		do {
			try await self.syncMessages(sessionFile: sessionFile, piSessionID: piSessionID, client: client)
		} catch {
			print("Error syncing messages for \(sessionId): \(error)")
		}
	}

	private func cleanupStaleSessions(hostID: Int64, keepingSessionIDs: Set<String>) async throws {
		try await self.dbContext.writer.write { db in
			let existingSessions = try PiSession
				.filter(Column("hostID") == hostID)
				.fetchAll(db)

			let idsToDelete = existingSessions
				.filter { !keepingSessionIDs.contains($0.sessionID) }
				.compactMap(\.id)

			if !idsToDelete.isEmpty {
				_ = try PiSession.filter(ids: idsToDelete).deleteAll(db)
			}
		}
	}

	// MARK: - Message sync

	private func syncMessages(sessionFile: String, piSessionID: Int64, client: PiServerClient) async throws {
		let remoteMessages = try await client.getMessages(sessionFile: sessionFile)

		try await self.dbContext.writer.write { db in
			try Self.storeMessages(remoteMessages, piSessionID: piSessionID, in: db)
		}
	}

	nonisolated static func shouldSync(_ remoteSession: JSONObject) -> Bool {
		if let mode = remoteSession["mode"]?.stringValue {
			return mode == "interactive"
		}
		return remoteSession["sessionFile"]?.stringValue != nil
	}

	private nonisolated static func cwdFolderName(_ cwd: String?) -> String? {
		guard let cwd, !cwd.isEmpty else { return nil }
		let name = (cwd as NSString).lastPathComponent
		if name.isEmpty || name == "/" { return nil }
		return name
	}

	nonisolated static func parseContentBlocks(from content: JSONValue?, messageID: Int64) -> [MessageContentBlock] {
		guard let content else { return [] }

		if let text = content.stringValue {
			return [MessageContentBlock(messageID: messageID, type: "text", text: text, toolCallName: nil, position: 0)]
		}

		guard let items = content.arrayValue else { return [] }

		return items.enumerated().compactMap { index, item -> MessageContentBlock? in
			guard let object = item.objectValue else { return nil }
			let type = object["type"]?.stringValue ?? "text"
			let text = object["text"]?.stringValue ?? object["thinking"]?.stringValue
			let toolCallName = object["name"]?.stringValue
			return MessageContentBlock(messageID: messageID, type: type, text: text, toolCallName: toolCallName, position: index)
		}
	}

	static func storeMessages(_ remoteMessages: [JSONObject], piSessionID: Int64, in db: Database) throws {
		let incomingPayloads = messagePayloads(from: remoteMessages)
		let existingPayloads = try messagePayloads(in: db, piSessionID: piSessionID)

		guard incomingPayloads != existingPayloads else { return }

		try Message.filter(Column("piSessionID") == piSessionID).deleteAll(db)

		let now = Date()
		for payload in incomingPayloads {
			var message = Message(
				piSessionID: piSessionID,
				role: payload.role,
				toolName: payload.toolName,
				position: payload.position,
				createdAt: now
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

	private static func messagePayloads(from remoteMessages: [JSONObject]) -> [MessagePayload] {
		remoteMessages.enumerated().map { index, remoteMessage in
			MessagePayload(
				role: Message.Role(remoteMessage["role"]?.stringValue ?? "unknown"),
				toolName: remoteMessage["toolName"]?.stringValue,
				position: index,
				blocks: parseContentBlocks(from: remoteMessage["content"], messageID: 0).map(BlockPayload.init)
			)
		}
	}

	private static func messagePayloads(in db: Database, piSessionID: Int64) throws -> [MessagePayload] {
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
				blocks: (blocksByMessageID[message.id ?? -1] ?? []).map(BlockPayload.init)
			)
		}
	}
}

private struct MessagePayload: Equatable {
	let role: Message.Role
	let toolName: String?
	let position: Int
	let blocks: [BlockPayload]
}

private struct BlockPayload: Equatable {
	let type: String
	let text: String?
	let toolCallName: String?
	let position: Int

	init(_ block: MessageContentBlock) {
		self.type = block.type
		self.text = block.text
		self.toolCallName = block.toolCallName
		self.position = block.position
	}
}
