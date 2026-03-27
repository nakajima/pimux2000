import Foundation
import Pi

@MainActor
@Observable
final class ServerInstaller {
	var logLines: [String] = []
	var isRunning = false
	var isComplete = false
	var error: String?

	private let sshTarget: String
	private let sshPassword: String?
	private let host: String

	init(sshTarget: String, sshPassword: String? = nil) {
		self.sshTarget = sshTarget
		self.sshPassword = sshPassword
		if let atSign = sshTarget.firstIndex(of: "@") {
			self.host = String(sshTarget[sshTarget.index(after: atSign)...])
		} else {
			self.host = sshTarget
		}
	}

	var serverURL: String { "ws://\(host):7749" }

	private nonisolated var healthURL: URL? {
		URL(string: "http://\(host):7749/health")
	}

	private var remoteReleaseDir: String {
		"$HOME/.pimux2000/releases/\(ServerFiles.version)"
	}

	// MARK: - Check if server is already running

	func checkServerRunning() async -> Bool {
		do {
			let health = try await fetchServerHealth()
			return health.ok
		} catch {
			return false
		}
	}

	// MARK: - Install server on remote host

	func install(updatingExistingServer: Bool = false) async {
		isRunning = true
		isComplete = false
		error = nil
		logLines = []

		defer { isRunning = false }

		do {
			if updatingExistingServer {
				log("Existing server detected. Updating it to the latest bundled release...")
			} else {
				log("Installing the bundled server release and extensions...")
			}

			log("Connecting to \(sshTarget)...")
			let _ = try await ssh("echo ok")
			log("Connected.")

			try await stageReleaseFiles()
			try await runRemoteUpdater()

			let health = try await fetchServerHealth()
			guard health.ok else {
				throw InstallerError.message("The remote server is running but reported an unhealthy status.")
			}
			guard health.version == ServerFiles.version else {
				if let version = health.version {
					throw InstallerError.message("The remote server is still serving bundled version \(version) instead of \(ServerFiles.version).")
				} else {
					throw InstallerError.message("The remote server is still serving a legacy health response instead of bundled version \(ServerFiles.version).")
				}
			}

			log("Server is running at \(serverURL) with bundled version \(ServerFiles.version)")
			isComplete = true
		} catch let e as InstallerError {
			let message = switch e { case .message(let text): text }
			error = message
			log("Error: \(message)")
		} catch {
			self.error = error.localizedDescription
			log("Error: \(error.localizedDescription)")
		}
	}

	// MARK: - Helpers

	private func log(_ message: String) {
		logLines.append(message)
	}

	private func stageReleaseFiles() async throws {
		log("Staging bundled release \(ServerFiles.version) to \(remoteReleaseDir)...")
		let mkdirCommand = "mkdir -p \(remoteReleaseDir)/src \(remoteReleaseDir)/bin \(remoteReleaseDir)/extensions"
		let _ = try await ssh(mkdirCommand)

		for file in ServerFiles.all {
			try await writeRemoteFile(path: "\(remoteReleaseDir)/\(file.path)", content: file.content)
			log("  \(file.path)")
		}

		for file in ServerFiles.extensions {
			try await writeRemoteFile(path: "\(remoteReleaseDir)/extensions/\(file.path)", content: file.content)
			log("  extensions/\(file.path)")
		}

		log("Release files staged.")
	}

	private func runRemoteUpdater() async throws {
		log("Running the remote updater...")
		let updaterPath = "\(remoteReleaseDir)/bin/update.sh"
		let command = "export PATH=\"$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" && /bin/sh \(updaterPath)"
		let output = try await ssh(command)
		let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
		if lines.isEmpty {
			log("  Remote updater completed.")
		} else {
			for line in lines where !line.isEmpty {
				log("  \(line)")
			}
		}
	}

	private nonisolated func fetchServerHealth() async throws -> RemoteServerHealth {
		guard let healthURL else {
			throw InstallerError.message("Invalid health URL for \(host)")
		}

		var request = URLRequest(url: healthURL)
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
		request.setValue("no-cache", forHTTPHeaderField: "Pragma")

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse,
			(200..<300).contains(httpResponse.statusCode) else {
			throw InstallerError.message("Remote server health check failed")
		}

		if let health = try? JSONDecoder().decode(RemoteServerHealth.self, from: data) {
			return health
		}

		let legacyResponse = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
		if legacyResponse == "ok" {
			return RemoteServerHealth(ok: true, version: nil)
		}

		throw InstallerError.message("Invalid remote server health response")
	}

	private nonisolated func ssh(_ command: String) async throws -> String {
		let config = PiHostConfiguration(sshTarget: sshTarget, sshPassword: sshPassword)
		return try await SSH.run(configuration: config, remoteCommand: command)
	}

	private nonisolated func writeRemoteFile(path: String, content: String) async throws {
		let command = "cat > \(path) << 'PIMUX2000_EOF'\n\(content)\nPIMUX2000_EOF"
		let config = PiHostConfiguration(sshTarget: sshTarget, sshPassword: sshPassword)
		_ = try await SSH.run(configuration: config, remoteCommand: command)
	}
}

private struct RemoteServerHealth: Decodable {
	let ok: Bool
	let version: String?
}

private enum InstallerError: Error {
	case message(String)
}
