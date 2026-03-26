import Foundation
import Pi
@testable import pimux2000
import Testing

@MainActor
struct SessionRepositoryTests {
	@Test
	func remoteSessionPrefersWorkSummaryForDisplayName() {
		let session = RemotePiSession(
			record: PiSessionRecord(
				pid: 1,
				cwd: "/tmp/project",
				sessionFile: "/tmp/project.jsonl",
				sessionId: "abc123",
				sessionName: "feature branch",
				model: PiModelInfo(provider: "openai", id: "gpt-5.4"),
				startedAt: "2026-03-25T00:00:00Z",
				lastSeenAt: "2026-03-25T00:10:00Z",
				mode: "interactive",
				workSummary: "Fixing session browser UI",
				workSummaryUpdatedAt: "2026-03-25T00:10:00Z",
				lastMessage: nil,
				lastMessageAt: nil,
				lastMessageRole: nil,
				registryFile: nil
			),
			transcript: nil
		)

		#expect(session.displayName == "Fixing session browser UI")
		#expect(session.secondaryName == "feature branch")
	}

	@Test
	func fixtureRepositoryReturnsSummarizedSessions() async throws {
		let repository = FixtureSessionRepository()

		let sessions = try await repository.loadSessions(for: "demo@fixture", allowInsecureHostKey: false)

		#expect(sessions.count == 2)
		#expect(sessions[0].workSummary == "Shell session health check")
		#expect(sessions[1].workSummary?.contains("Watching logs") == true)
	}

	@Test
	func fixtureRepositoryReportsConfiguredFailure() async {
		let repository = FixtureSessionRepository()
		var didThrow = false

		do {
			_ = try await repository.loadSessions(for: "broken@fixture", allowInsecureHostKey: false)
		} catch {
			didThrow = true
			#expect(error.localizedDescription.contains("configured to fail"))
		}

		#expect(didThrow)
	}
}
