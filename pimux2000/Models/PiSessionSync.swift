//
//  PiSessionSync.swift
//  pimux2000
//
//  Created by Pat Nakajima on 3/26/26.
//
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

		let client = PiClient(configuration: .init(sshTarget: host.sshTarget))
		let sessions = try await client.listSessions()

		for remoteSession in sessions {
			try await self.sync(remoteSession: remoteSession, hostID: hostID, client: client)
		}
	}

	private func sync(remoteSession: PiSessionRecord, hostID: Int64, client: PiClient) async throws {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		let startedAt = formatter.date(from: remoteSession.startedAt) ?? Date.distantPast
		let lastSeenAt = formatter.date(from: remoteSession.lastSeenAt) ?? Date.distantPast

		let lastMessageAt = remoteSession.lastMessageAt.flatMap { formatter.date(from: $0) }

		let session = PiSession(
			hostID: hostID,
			summary: remoteSession.workSummary ?? remoteSession.sessionId,
			sessionID: remoteSession.sessionId,
			model: remoteSession.model.map { "\($0)" } ?? "unknown model",
			lastMessage: remoteSession.lastMessage,
			lastMessageAt: lastMessageAt,
			lastMessageRole: remoteSession.lastMessageRole,
			startedAt: startedAt,
			lastSeenAt: lastSeenAt
		)

		let piSessionID = try await self.dbContext.writer.write { db -> Int64 in
			var session = session
			try session.upsert(db)
			return session.id!
		}

		guard remoteSession.registryFile != nil else { return }
		do {
			try await self.syncMessages(for: remoteSession, piSessionID: piSessionID, client: client)
		} catch {
			print("Error syncing messages for \(remoteSession.sessionId): \(error)")
		}
	}

	// MARK: - Message sync

	private func syncMessages(for remoteSession: PiSessionRecord, piSessionID: Int64, client: PiClient) async throws {
		guard let registryFile = remoteSession.registryFile else { return }

		// Messages file is written by the extension alongside the registry file: {pid}-messages.json
		let messagesFile = registryFile.replacingOccurrences(of: ".json", with: "-messages.json")
		let quoted = "'" + messagesFile.replacingOccurrences(of: "'", with: "'\\''") + "'"
		let command = "cat \(quoted) 2>/dev/null || echo '[]'"
		let output = try await client.runCommand(command)
		let data = Data(output.utf8)
		let remoteMessages = try JSONDecoder().decode([JSONValue].self, from: data)

		let now = Date()
		try await self.dbContext.writer.write { db in
			try Message.filter(Column("piSessionID") == piSessionID).deleteAll(db)

			for (messageIndex, value) in remoteMessages.enumerated() {
				guard let remoteMessage = value.objectValue else { continue }
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

	private nonisolated static func parseContentBlocks(from content: JSONValue?, messageID: Int64) -> [MessageContentBlock] {
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
