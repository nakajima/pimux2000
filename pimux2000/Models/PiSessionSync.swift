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
		try await client.connect()
		defer { Task { await client.disconnect() } }

		let remoteSessions = try await client.listSessions()

		for remoteSession in remoteSessions {
			try await self.sync(remoteSession: remoteSession, hostID: hostID, client: client)
		}
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
			return session.id!
		}

		// Sync messages if we have a session file
		guard let sessionFile = remoteSession["sessionFile"]?.stringValue else { return }
		do {
			try await self.syncMessages(sessionFile: sessionFile, piSessionID: piSessionID, client: client)
		} catch {
			print("Error syncing messages for \(sessionId): \(error)")
		}
	}

	// MARK: - Message sync

	private func syncMessages(sessionFile: String, piSessionID: Int64, client: PiServerClient) async throws {
		let remoteMessages = try await client.getMessages(sessionFile: sessionFile)

		let now = Date()
		try await self.dbContext.writer.write { db in
			try Message.filter(Column("piSessionID") == piSessionID).deleteAll(db)

			for (messageIndex, remoteMessage) in remoteMessages.enumerated() {
				let roleString = remoteMessage["role"]?.stringValue ?? "unknown"
				var message = Message(
					piSessionID: piSessionID,
					role: Message.Role(roleString),
					toolName: remoteMessage["toolName"]?.stringValue,
					position: messageIndex,
					createdAt: now
				)
				try message.insert(db)

				let blocks = Self.parseContentBlocks(from: remoteMessage["content"], messageID: message.id!)
				for var block in blocks {
					try block.insert(db)
				}
			}
		}
	}

	private nonisolated static func cwdFolderName(_ cwd: String?) -> String? {
		guard let cwd, !cwd.isEmpty else { return nil }
		let name = (cwd as NSString).lastPathComponent
		return name.isEmpty ? nil : name
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
			let text = object["text"]?.stringValue
			let toolCallName = object["name"]?.stringValue
			return MessageContentBlock(messageID: messageID, type: type, text: text, toolCallName: toolCallName, position: index)
		}
	}
}
