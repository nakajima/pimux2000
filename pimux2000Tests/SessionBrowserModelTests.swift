import Foundation
import Pi
@testable import pimux2000
import Testing

private struct BrowserModelTestError: LocalizedError {
	let message: String

	var errorDescription: String? { message }
}

@MainActor
private final class MockSessionRepository: SessionBrowsing {
	var loadSessionsHandler: (String, Bool) async throws -> [RemotePiSession] = { _, _ in [] }
	var loadTranscriptHandler: (String, RemotePiSession, Bool) async throws -> String = { _, _, _ in "" }
	var sendHandler: (String, String, RemotePiSession, Bool) async throws -> Void = { _, _, _, _ in }

	func loadSessions(for sshTarget: String, allowInsecureHostKey: Bool) async throws -> [RemotePiSession] {
		try await loadSessionsHandler(sshTarget, allowInsecureHostKey)
	}

	func loadTranscript(for sshTarget: String, session: RemotePiSession, allowInsecureHostKey: Bool) async throws -> String {
		try await loadTranscriptHandler(sshTarget, session, allowInsecureHostKey)
	}

	func send(_ text: String, to sshTarget: String, session: RemotePiSession, allowInsecureHostKey: Bool) async throws {
		try await sendHandler(text, sshTarget, session, allowInsecureHostKey)
	}
}

@MainActor
struct SessionBrowserModelTests {
	@Test
	func refreshFailureKeepsLastKnownSessionsAndMarksThemStale() async {
		let repository = MockSessionRepository()
		let model = SessionBrowserModel(sessionRepository: repository)
		let host = makeHost(id: 1, sshTarget: "root@fixture")

		repository.loadSessionsHandler = { _, _ in
			[makeSession(id: "shell", sessionFile: "/tmp/shell.jsonl", workSummary: "Shell health")]
		}

		await model.refreshSessionsNow(for: host)
		#expect(model.sessions(for: host.id).count == 1)
		#expect(model.isShowingStaleData(for: host.id) == false)

		repository.loadSessionsHandler = { _, _ in
			throw BrowserModelTestError(message: "offline")
		}

		await model.refreshSessionsNow(for: host)

		#expect(model.sessions(for: host.id).count == 1)
		#expect(model.isShowingStaleData(for: host.id))
		#expect(model.refreshErrorMessage(for: host.id) == "offline")
	}

	@Test
	func refreshLoadsTranscriptForSelectedSession() async {
		let repository = MockSessionRepository()
		let model = SessionBrowserModel(sessionRepository: repository)
		let host = makeHost(id: 1, sshTarget: "root@fixture")
		let session = makeSession(id: "shell", sessionFile: "/tmp/shell.jsonl", workSummary: "Shell health")

		repository.loadSessionsHandler = { _, _ in [session] }
		repository.loadTranscriptHandler = { _, session, _ in
			"Pi: transcript for \(session.sessionId)"
		}

		await model.refreshSessionsNow(for: host)

		#expect(model.selectedSession(for: host.id)?.transcript == "Pi: transcript for shell")
	}

	@Test
	func sendFailurePreservesComposerTextAndReportsActionError() async {
		let repository = MockSessionRepository()
		let model = SessionBrowserModel(sessionRepository: repository)
		let host = makeHost(id: 1, sshTarget: "root@fixture")
		let session = makeSession(id: "shell", sessionFile: "/tmp/shell.jsonl", workSummary: "Shell health")

		model.loadPreviewState(hostID: 1, sessions: [session], selectedSessionID: session.id)
		model.composerText = " continue please "
		repository.sendHandler = { _, _, _, _ in
			throw BrowserModelTestError(message: "send failed")
		}

		await model.sendToSelectedSession(on: host)

		#expect(model.composerText == " continue please ")
		#expect(model.actionErrorMessage(for: host.id) == "send failed")
	}

	@Test
	func hostKeyPromptCanRetryRefreshWithRelaxedChecking() async {
		let repository = MockSessionRepository()
		let model = SessionBrowserModel(sessionRepository: repository)
		let host = makeHost(id: 1, sshTarget: "root@fixture")
		var callCount = 0

		repository.loadSessionsHandler = { _, allowInsecureHostKey in
			callCount += 1
			if !allowInsecureHostKey {
				throw BrowserModelTestError(message: "Host key verification failed.")
			}
			return [makeSession(id: "shell", sessionFile: "/tmp/shell.jsonl", workSummary: "Shell health")]
		}

		await model.refreshSessionsNow(for: host)
		#expect(model.hostKeyPrompt?.sshTarget == "root@fixture")
		#expect(model.sessions(for: host.id).isEmpty)

		model.trustHostAndRetry()
		for _ in 0 ..< 5 {
			await Task.yield()
		}

		#expect(callCount >= 2)
		#expect(model.hostKeyPrompt == nil)
		#expect(model.sessions(for: host.id).count == 1)
	}
}

private func makeHost(id: Int64, sshTarget: String) -> Host {
	Host(id: id, sshTarget: sshTarget, createdAt: .now, updatedAt: .now)
}

private func makeSession(id: String, sessionFile: String?, workSummary: String?) -> RemotePiSession {
	RemotePiSession(
		record: PiSessionRecord(
			pid: 100,
			cwd: "/tmp/\(id)",
			sessionFile: sessionFile,
			sessionId: id,
			sessionName: id,
			model: PiModelInfo(provider: "openai", id: "gpt-5.4-mini"),
			startedAt: "2026-03-25T00:00:00Z",
			lastSeenAt: "2026-03-25T00:10:00Z",
			mode: "interactive",
			workSummary: workSummary,
			workSummaryUpdatedAt: "2026-03-25T00:10:00Z",
			lastMessage: nil,
			lastMessageAt: nil,
			lastMessageRole: nil,
			registryFile: nil
		),
		transcript: nil
	)
}
