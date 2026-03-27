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

	func install(updatingExistingServer: Bool = false) async {
		isRunning = true
		isComplete = false
		error = nil
		logLines = []

		do {
			if updatingExistingServer {
				log("Existing server detected. Updating it to the latest bundled version...")
			} else {
				log("Installing the bundled server and extensions...")
			}
			log("Connecting to \(sshTarget)...")
			// Verify SSH works
			let _ = try await ssh("echo ok")
			log("Connected.")

			log("Checking for bun...")
			let bunPath = try await discoverBunPath()
			log("bun found at \(bunPath).")

			log("Writing server files to ~/.pimux2000/server/...")
			try await ssh("mkdir -p ~/.pimux2000/server/src")

			for file in ServerFiles.all {
				try await writeRemoteFile(path: "~/.pimux2000/server/\(file.path)", content: file.content)
				log("  \(file.path)")
			}
			log("Server files written.")

			log("Installing pi extensions to ~/.pi/agent/extensions/...")
			try await ssh("mkdir -p ~/.pi/agent/extensions")

			for file in ServerFiles.extensions {
				try await writeRemoteFile(path: "~/.pi/agent/extensions/\(file.path)", content: file.content)
				log("  \(file.path)")
			}
			log("Extensions installed.")

			log("Installing server as system service...")
			let installOutput = try await ssh("export PATH=\"$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\" && cd ~/.pimux2000/server && \(shellQuote(bunPath)) run src/cli.ts install-server")
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

	private nonisolated func discoverBunPath() async throws -> String {
		let command = #"if command -v bun >/dev/null 2>&1; then command -v bun; elif [ -x "$HOME/.bun/bin/bun" ]; then echo "$HOME/.bun/bin/bun"; elif [ -x /opt/homebrew/bin/bun ]; then echo /opt/homebrew/bin/bun; elif [ -x /usr/local/bin/bun ]; then echo /usr/local/bin/bun; else echo NOT_FOUND; fi"#
		let output = try await ssh(command)
		let bunPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !bunPath.isEmpty, bunPath != "NOT_FOUND" else {
			throw InstallerError.message("bun is not installed on \(host), or it is not visible to non-interactive SSH sessions. If bun is installed in a custom location, add it to your shell PATH or install it at ~/.bun/bin/bun.")
		}
		return bunPath
	}

	private nonisolated func ssh(_ command: String) async throws -> String {
		let config = PiHostConfiguration(sshTarget: sshTarget, sshPassword: sshPassword)
		return try await SSH.run(configuration: config, remoteCommand: command)
	}

	private nonisolated func writeRemoteFile(path: String, content: String) async throws {
		// Use heredoc to write file content over SSH
		let command = "cat > \(path) << 'PIMUX2000_EOF'\n\(content)\nPIMUX2000_EOF"
		let config = PiHostConfiguration(sshTarget: sshTarget, sshPassword: sshPassword)
		_ = try await SSH.run(configuration: config, remoteCommand: command)
	}
}

private enum InstallerError: Error {
	case message(String)
}

private func shellQuote(_ string: String) -> String {
	if string.isEmpty { return "''" }
	return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
