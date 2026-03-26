import Citadel
import Foundation
import NIO
@preconcurrency import NIOSSH
#if os(iOS)
	import Darwin
	import ios_system
#endif

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Codable, Sendable, Equatable {
	case string(String)
	case number(Double)
	case bool(Bool)
	case object(JSONObject)
	case array([JSONValue])
	case null

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()

		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([String: JSONValue].self) {
			self = .object(value)
		} else if let value = try? container.decode([JSONValue].self) {
			self = .array(value)
		} else {
			throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case let .string(value): try container.encode(value)
		case let .number(value): try container.encode(value)
		case let .bool(value): try container.encode(value)
		case let .object(value): try container.encode(value)
		case let .array(value): try container.encode(value)
		case .null: try container.encodeNil()
		}
	}

	public var stringValue: String? {
		if case let .string(value) = self { return value }
		return nil
	}

	public var doubleValue: Double? {
		if case let .number(value) = self { return value }
		return nil
	}

	public var intValue: Int? {
		guard case let .number(value) = self else { return nil }
		return Int(exactly: value)
	}

	public var boolValue: Bool? {
		if case let .bool(value) = self { return value }
		return nil
	}

	public var objectValue: JSONObject? {
		if case let .object(value) = self { return value }
		return nil
	}

	public var arrayValue: [JSONValue]? {
		if case let .array(value) = self { return value }
		return nil
	}
}

public struct PiModelInfo: Codable, Sendable, Equatable {
	public let provider: String
	public let id: String

	public init(provider: String, id: String) {
		self.provider = provider
		self.id = id
	}
}

public struct PiSessionRecord: Codable, Sendable, Equatable, Identifiable {
	public let pid: Int
	public let cwd: String
	public let sessionFile: String?
	public let sessionId: String
	public let sessionName: String?
	public let model: PiModelInfo?
	public let startedAt: String
	public let lastSeenAt: String
	public let mode: String
	public let workSummary: String?
	public let workSummaryUpdatedAt: String?
	public let lastMessage: String?
	public let lastMessageAt: String?
	public let lastMessageRole: String?
	public let registryFile: String?

	public var id: String { sessionId }

	enum CodingKeys: String, CodingKey {
		case pid
		case cwd
		case sessionFile
		case sessionId
		case sessionName
		case model
		case startedAt
		case lastSeenAt
		case mode
		case workSummary
		case workSummaryUpdatedAt
		case lastMessage
		case lastMessageAt
		case lastMessageRole
		case registryFile = "_registryFile"
	}

	public init(
		pid: Int,
		cwd: String,
		sessionFile: String?,
		sessionId: String,
		sessionName: String?,
		model: PiModelInfo?,
		startedAt: String,
		lastSeenAt: String,
		mode: String,
		workSummary: String?,
		workSummaryUpdatedAt: String?,
		lastMessage: String?,
		lastMessageAt: String?,
		lastMessageRole: String?,
		registryFile: String?
	) {
		self.pid = pid
		self.cwd = cwd
		self.sessionFile = sessionFile
		self.sessionId = sessionId
		self.sessionName = sessionName
		self.model = model
		self.startedAt = startedAt
		self.lastSeenAt = lastSeenAt
		self.mode = mode
		self.workSummary = workSummary
		self.workSummaryUpdatedAt = workSummaryUpdatedAt
		self.lastMessage = lastMessage
		self.lastMessageAt = lastMessageAt
		self.lastMessageRole = lastMessageRole
		self.registryFile = registryFile
	}
}

public struct PiHostConfiguration: Sendable, Equatable {
	public let sshTarget: String
	public let sshBinary: String
	public let sshOptions: [String]
	public let remotePiCommand: String
	public let remoteRegistryDirectory: String
	public let executesLocally: Bool

	public init(
		sshTarget: String,
		sshBinary: String = "/usr/bin/ssh",
		sshOptions: [String] = [],
		remotePiCommand: String = "pi",
		remoteRegistryDirectory: String = "~/.pi/agent/runtime/instances",
		executesLocally: Bool? = nil
	) {
		self.sshTarget = sshTarget
		self.sshBinary = sshBinary
		self.sshOptions = sshOptions
		self.remotePiCommand = remotePiCommand
		self.remoteRegistryDirectory = remoteRegistryDirectory
		self.executesLocally = executesLocally ?? Self.isImplicitLocalHost(sshTarget)
	}

	public static func local(
		piCommand: String = "pi",
		registryDirectory: String = "~/.pi/agent/runtime/instances"
	) -> Self {
		Self(
			sshTarget: "localhost",
			remotePiCommand: piCommand,
			remoteRegistryDirectory: registryDirectory,
			executesLocally: true
		)
	}

	static func isImplicitLocalHost(_ target: String) -> Bool {
		switch target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "localhost", "127.0.0.1", "::1":
			return true
		default:
			return false
		}
	}
}

public enum PiError: Error, LocalizedError, Sendable {
	case invalidResponse(String)
	case commandFailed(String)
	case rpcFailure(String)
	case processEnded(status: Int32, stderr: String)
	case missingSessionFile(String)
	case sessionBusy
	case sessionNotFound(String)
	case ambiguousSessionIdentifier(String, matches: [String])

	public var errorDescription: String? {
		switch self {
		case let .invalidResponse(message): return "Invalid response: \(message)"
		case let .commandFailed(message): return "Command failed: \(message)"
		case let .rpcFailure(message): return "RPC failure: \(message)"
		case let .processEnded(status, stderr): return "Process ended with status \(status): \(stderr)"
		case let .missingSessionFile(sessionId): return "Session \(sessionId) has no session file"
		case .sessionBusy: return "A prompt is already running on this RPC session"
		case let .sessionNotFound(identifier): return "No active pi session found for identifier: \(identifier)"
		case let .ambiguousSessionIdentifier(identifier, matches):
			return "Session identifier '\(identifier)' is ambiguous. Matches: \(matches.joined(separator: ", "))"
		}
	}
}

public struct PiRemoteSessionState: Sendable, Equatable {
	public let raw: JSONObject

	public init(raw: JSONObject) {
		self.raw = raw
	}

	public var sessionId: String? { raw["sessionId"]?.stringValue }
	public var sessionFile: String? { raw["sessionFile"]?.stringValue }
	public var sessionName: String? { raw["sessionName"]?.stringValue }
	public var isStreaming: Bool? { raw["isStreaming"]?.boolValue }
}

public final class PiClient: Sendable {
	public let configuration: PiHostConfiguration

	public init(configuration: PiHostConfiguration) {
		self.configuration = configuration
	}

	public func runCommand(_ command: String) async throws -> String {
		try await SSH.run(configuration: configuration, remoteCommand: command)
	}

	public func listSessions() async throws -> [PiSessionRecord] {
		let script = """
		import glob, json, os

		registry = os.path.expanduser(os.environ[\"REGISTRY_DIR\"])
		records = []
		for path in sorted(glob.glob(os.path.join(registry, \"*.json\"))):
		    try:
		        with open(path, \"r\", encoding=\"utf-8\") as f:
		            data = json.load(f)
		        data[\"_registryFile\"] = path
		        records.append(data)
		    except Exception:
		        pass

		print(json.dumps(records))
		"""

		let command = "REGISTRY_DIR=\(shellQuote(configuration.remoteRegistryDirectory)) python3 - <<'PY'\n\(script)\nPY"
		let output = try await SSH.run(configuration: configuration, remoteCommand: command)
		let data = Data(output.utf8)
		return try JSONDecoder().decode([PiSessionRecord].self, from: data)
	}

	public func connect(to session: PiSessionRecord) async throws -> PiRPCSession {
		guard let sessionFile = session.sessionFile else {
			throw PiError.missingSessionFile(session.sessionId)
		}
		let rpcSession = PiRPCSession(configuration: configuration, cwd: session.cwd, sessionPath: sessionFile)
		try await rpcSession.start()
		return rpcSession
	}

	public func connect(sessionId: String) async throws -> PiRPCSession {
		return try await connect(sessionIdentifier: sessionId)
	}

	public func connect(sessionIdentifier: String) async throws -> PiRPCSession {
		let session = try await resolveSession(identifier: sessionIdentifier)
		return try await connect(to: session)
	}

	public func resolveSession(identifier: String) async throws -> PiSessionRecord {
		let sessions = try await listSessions()
		return try Self.resolveSession(identifier: identifier, from: sessions)
	}

	public static func resolveSession(identifier: String, from sessions: [PiSessionRecord]) throws -> PiSessionRecord {
		if let exactID = sessions.first(where: { $0.sessionId == identifier }) {
			return exactID
		}

		let exactSummaryMatches = sessions.filter { $0.workSummary == identifier }
		if exactSummaryMatches.count == 1, let match = exactSummaryMatches.first {
			return match
		}
		if exactSummaryMatches.count > 1 {
			throw PiError.ambiguousSessionIdentifier(identifier, matches: exactSummaryMatches.map(describeMatch))
		}

		let prefixMatches = sessions.filter { $0.sessionId.hasPrefix(identifier) }
		if prefixMatches.count == 1, let match = prefixMatches.first {
			return match
		}
		if prefixMatches.count > 1 {
			throw PiError.ambiguousSessionIdentifier(identifier, matches: prefixMatches.map(describeMatch))
		}

		let needle = identifier.lowercased()
		let summarySubstringMatches = sessions.filter {
			guard let summary = $0.workSummary?.lowercased() else { return false }
			return summary.contains(needle)
		}
		if summarySubstringMatches.count == 1, let match = summarySubstringMatches.first {
			return match
		}
		if summarySubstringMatches.count > 1 {
			throw PiError.ambiguousSessionIdentifier(identifier, matches: summarySubstringMatches.map(describeMatch))
		}

		throw PiError.sessionNotFound(identifier)
	}
}

public actor PiRPCSession {
	private let configuration: PiHostConfiguration
	private let cwd: String?
	private var sessionPath: String?
	private var nextRequestNumber = 0

	public init(configuration: PiHostConfiguration, cwd: String? = nil, sessionPath: String? = nil) {
		self.configuration = configuration
		self.cwd = cwd
		self.sessionPath = sessionPath
	}

	public func start() async throws {
		_ = try await getState()
	}

	public func stop() async {
		// Stateless transport; nothing to tear down.
	}

	public func getState() async throws -> PiRemoteSessionState {
		let response = try await sendRPCCommand(type: "get_state")
		guard let data = response["data"]?.objectValue else {
			throw PiError.invalidResponse("Missing state payload")
		}
		return PiRemoteSessionState(raw: data)
	}

	public func switchSession(to sessionPath: String) async throws -> Bool {
		self.sessionPath = sessionPath
		let result = try await sendRawRPCCommands([
			makeCommand(type: "switch_session", extra: ["sessionPath": .string(sessionPath)]),
		], prependStoredSessionSwitch: false)
		guard let response = result.responses.last(where: { $0["command"]?.stringValue == "switch_session" }) else {
			throw PiError.invalidResponse("Missing response for command switch_session")
		}
		return response["data"]?.objectValue?["cancelled"]?.boolValue ?? false
	}

	public func getMessages() async throws -> [JSONObject] {
		let response = try await sendRPCCommand(type: "get_messages")
		guard let messages = response["data"]?.objectValue?["messages"]?.arrayValue else {
			throw PiError.invalidResponse("Missing messages payload")
		}
		return messages.compactMap { $0.objectValue }
	}

	public func getLastAssistantText() async throws -> String? {
		let response = try await sendRPCCommand(type: "get_last_assistant_text")
		return response["data"]?.objectValue?["text"]?.stringValue
	}

	public func prompt(_ message: String) async throws {
		_ = try await promptAndWait(message)
	}

	public func promptAndWait(_ message: String) async throws -> [JSONObject] {
		let result = try await sendRawRPCCommands([
			makeCommand(type: "prompt", extra: ["message": .string(message)]),
		])
		return result.events
	}

	private func sendRPCCommand(type: String, extra: JSONObject = [:]) async throws -> JSONObject {
		let result = try await sendRawRPCCommands([makeCommand(type: type, extra: extra)])
		guard let response = result.responses.last(where: { $0["command"]?.stringValue == type }) else {
			throw PiError.invalidResponse("Missing response for command \(type)")
		}
		return response
	}

	private func sendRawRPCCommands(
		_ commands: [JSONObject],
		prependStoredSessionSwitch: Bool = true
	) async throws -> (responses: [JSONObject], events: [JSONObject]) {
		let preparedCommands = try commandsWithSessionSwitchIfNeeded(commands, prependStoredSessionSwitch: prependStoredSessionSwitch)
		let output = try await SSH.run(configuration: configuration, remoteCommand: makeRPCInvocation(commands: preparedCommands))
		return try parseRPCOutput(output)
	}

	private func commandsWithSessionSwitchIfNeeded(
		_ commands: [JSONObject],
		prependStoredSessionSwitch: Bool
	) throws -> [JSONObject] {
		guard prependStoredSessionSwitch, let sessionPath else { return commands }
		if commands.contains(where: { $0["type"]?.stringValue == "switch_session" }) {
			return commands
		}
		return [makeCommand(type: "switch_session", extra: ["sessionPath": .string(sessionPath)])] + commands
	}

	private func makeCommand(type: String, extra: JSONObject = [:]) -> JSONObject {
		nextRequestNumber += 1
		var command = extra
		command["id"] = .string("req-\(nextRequestNumber)")
		command["type"] = .string(type)
		return command
	}

	private func makeRPCInvocation(commands: [JSONObject]) throws -> String {
		let encoder = JSONEncoder()
		let jsonLines = try commands.map { command -> String in
			let data = try encoder.encode(command)
			guard let string = String(data: data, encoding: .utf8) else {
				throw PiError.invalidResponse("Failed to encode RPC command")
			}
			return string
		}

		let stdinPayload = jsonLines.map(shellQuote).joined(separator: " ")
		let changeDirectory = cwd.map { "cd \(shellQuote($0)) && " } ?? ""
		return "\(changeDirectory)printf '%s\\n' \(stdinPayload) | \(configuration.remotePiCommand) --mode rpc"
	}

	private func parseRPCOutput(_ output: String) throws -> (responses: [JSONObject], events: [JSONObject]) {
		var responses: [JSONObject] = []
		var events: [JSONObject] = []

		for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
			let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[rawLine.startIndex...]
			let data = Data(line.utf8)
			let value = try JSONDecoder().decode(JSONValue.self, from: data)
			guard let object = value.objectValue else {
				throw PiError.invalidResponse("RPC line was not a JSON object")
			}

			if object["type"]?.stringValue == "response" {
				if object["success"]?.boolValue == false {
					throw PiError.rpcFailure(object["error"]?.stringValue ?? "Unknown RPC error")
				}
				responses.append(object)
			} else {
				events.append(object)
			}
		}

		return (responses, events)
	}
}

private func describeMatch(_ session: PiSessionRecord) -> String {
	if let summary = session.workSummary, !summary.isEmpty {
		return "\(session.sessionId) [\(summary)]"
	}
	return session.sessionId
}

private final class SSHNoneAuth: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
	let username: String

	init(username: String) {
		self.username = username
	}

	nonisolated func nextAuthenticationType(
		availableMethods: NIOSSHAvailableUserAuthenticationMethods,
		nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
	) {
		nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .none))
	}
}

enum SSH {
	static func run(configuration: PiHostConfiguration, remoteCommand: String) async throws -> String {
		if configuration.executesLocally {
			return try runLocally(command: remoteCommand)
		}
		return try await runRemote(configuration: configuration, remoteCommand: remoteCommand)
	}

	// MARK: - Remote (Citadel)

	private static func runRemote(configuration: PiHostConfiguration, remoteCommand: String) async throws -> String {
		let (username, host) = parseSSHTarget(configuration.sshTarget)

		let client = try await SSHClient.connect(
			host: host,
			port: 22,
			authenticationMethod: .custom(SSHNoneAuth(username: username)),
			hostKeyValidator: .acceptAnything(),
			reconnect: .never
		)

		do {
			let output = try await client.executeCommand(remoteCommand)
			try await client.close()
			return String(buffer: output)
		} catch {
			try? await client.close()
			throw error
		}
	}

	private static func parseSSHTarget(_ target: String) -> (username: String, host: String) {
		let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
		if let atSign = trimmed.firstIndex(of: "@") {
			let username = String(trimmed[..<atSign])
			let host = String(trimmed[trimmed.index(after: atSign)...])
			return (username, host)
		}
		return ("root", trimmed)
	}

	// MARK: - Local

	private static func runLocally(command: String) throws -> String {
		#if os(iOS)
			return try runLocallyWithIOSSystem(command: command)
		#else
			return try runLocallyWithProcess(command: command)
		#endif
	}

	#if os(iOS)
		private static let iosSystemBootstrap: Void = {
			initializeEnvironment()
		}()

		private static func runLocallyWithIOSSystem(command: String) throws -> String {
			_ = iosSystemBootstrap

			let homeDirectory = NSHomeDirectory()
			setenv("HOME", homeDirectory, 1)

			let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
			try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
			defer { try? FileManager.default.removeItem(at: tempDirectory) }

			let stdoutURL = tempDirectory.appendingPathComponent("stdout.txt")
			let stderrURL = tempDirectory.appendingPathComponent("stderr.txt")
			let redirectedCommand = "\(command) > \(shellQuote(stdoutURL.path)) 2> \(shellQuote(stderrURL.path))"

			let status = redirectedCommand.withCString { ios_system($0) }
			let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
			let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

			guard status == 0 else {
				throw PiError.commandFailed(stderr.isEmpty ? "local command failed with status \(status)" : stderr)
			}

			return stdout
		}
	#else
		private static func runLocallyWithProcess(command: String) throws -> String {
			let process = Process()
			let stdoutPipe = Pipe()
			let stderrPipe = Pipe()

			process.executableURL = URL(fileURLWithPath: "/bin/sh")
			process.arguments = ["-lc", command]
			process.standardOutput = stdoutPipe
			process.standardError = stderrPipe

			try process.run()
			process.waitUntilExit()

			let stdout = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
			let stderr = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()

			guard process.terminationStatus == 0 else {
				throw PiError.commandFailed(
					String(data: stderr, encoding: .utf8) ?? "local command failed with status \(process.terminationStatus)"
				)
			}

			return String(data: stdout, encoding: .utf8) ?? ""
		}
	#endif
}

private func shellQuote(_ string: String) -> String {
	if string.isEmpty { return "''" }
	return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
