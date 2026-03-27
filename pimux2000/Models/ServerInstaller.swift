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
	private let host: String

	init(sshTarget: String) {
		self.sshTarget = sshTarget
		if let atSign = sshTarget.firstIndex(of: "@") {
			self.host = String(sshTarget[sshTarget.index(after: atSign)...])
		} else {
			self.host = sshTarget
		}
	}

	var serverURL: String { "ws://\(host):7749" }

	// MARK: - Check if server is already running

	func checkServerRunning() async -> Bool {
		let client = PiServerClient(serverURL: serverURL)
		do {
			try await client.connect()
			_ = try await client.listSessions()
			await client.disconnect()
			return true
		} catch {
			await client.disconnect()
			return false
		}
	}

	// MARK: - Install server on remote host

	func install() async {
		isRunning = true
		isComplete = false
		error = nil
		logLines = []

		do {
			log("Connecting to \(sshTarget)...")
			// Verify SSH works
			let _ = try await ssh("echo ok")
			log("Connected.")

			log("Checking for bun...")
			let bunCheck = try? await ssh("which bun || echo NOT_FOUND")
			if bunCheck?.contains("NOT_FOUND") == true {
				throw InstallerError.message("bun is not installed on \(host). Install it first: https://bun.sh")
			}
			log("bun found.")

			log("Writing server files to ~/.pimux2000/server/...")
			try await ssh("mkdir -p ~/.pimux2000/server/src")

			for file in ServerFiles.all {
				try await writeRemoteFile(path: "~/.pimux2000/server/\(file.path)", content: file.content)
				log("  \(file.path)")
			}
			log("Server files written.")

			log("Installing server as system service...")
			let installOutput = try await ssh("cd ~/.pimux2000/server && bun run src/cli.ts install-server")
			for line in installOutput.split(separator: "\n") {
				log("  \(line)")
			}

			log("Waiting for server to start...")
			var attempts = 0
			while attempts < 10 {
				try? await Task.sleep(for: .seconds(1))
				if await checkServerRunning() {
					log("Server is running at \(serverURL)")
					isComplete = true
					isRunning = false
					return
				}
				attempts += 1
			}

			throw InstallerError.message("Server did not start after 10 seconds")
		} catch let e as InstallerError {
			let msg = switch e { case .message(let m): m }
			error = msg
			log("Error: \(msg)")
		} catch {
			self.error = error.localizedDescription
			log("Error: \(error.localizedDescription)")
		}

		isRunning = false
	}

	// MARK: - Helpers

	private func log(_ message: String) {
		logLines.append(message)
	}

	private nonisolated func ssh(_ command: String) async throws -> String {
		let config = PiHostConfiguration(sshTarget: sshTarget)
		return try await SSH.run(configuration: config, remoteCommand: command)
	}

	private nonisolated func writeRemoteFile(path: String, content: String) async throws {
		// Use heredoc to write file content over SSH
		let escaped = content.replacingOccurrences(of: "'", with: "'\\''")
		let command = "cat > \(path) << 'PIMUX2000_EOF'\n\(content)\nPIMUX2000_EOF"
		let config = PiHostConfiguration(sshTarget: sshTarget)
		_ = try await SSH.run(configuration: config, remoteCommand: command)
	}
}

private enum InstallerError: Error {
	case message(String)
}
