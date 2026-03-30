import Foundation

struct PimuxHostSessions: Decodable, Equatable, Sendable {
	let location: String
	let connected: Bool
	let missing: Bool
	let lastSeenAt: Date?
	let sessions: [PimuxActiveSession]
}

struct PimuxSessionContextUsage: Decodable, Equatable, Sendable {
	let usedTokens: Int?
	let maxTokens: Int?

	init(usedTokens: Int? = nil, maxTokens: Int? = nil) {
		self.usedTokens = usedTokens
		self.maxTokens = maxTokens
	}
}

struct PimuxActiveSession: Decodable, Equatable, Sendable {
	let id: String
	let summary: String
	let createdAt: Date
	let updatedAt: Date
	let lastUserMessageAt: Date
	let lastAssistantMessageAt: Date
	let cwd: String
	let model: String
	let contextUsage: PimuxSessionContextUsage?
	let supportsImages: Bool?

	init(
		id: String,
		summary: String,
		createdAt: Date,
		updatedAt: Date,
		lastUserMessageAt: Date,
		lastAssistantMessageAt: Date,
		cwd: String,
		model: String,
		contextUsage: PimuxSessionContextUsage? = nil,
		supportsImages: Bool? = nil
	) {
		self.id = id
		self.summary = summary
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.lastUserMessageAt = lastUserMessageAt
		self.lastAssistantMessageAt = lastAssistantMessageAt
		self.cwd = cwd
		self.model = model
		self.contextUsage = contextUsage
		self.supportsImages = supportsImages
	}
}

struct PimuxListedSession: Decodable, Equatable, Sendable {
	let hostLocation: String
	let hostConnected: Bool
	let id: String
	let summary: String
	let createdAt: Date
	let updatedAt: Date
	let lastUserMessageAt: Date
	let lastAssistantMessageAt: Date
	let cwd: String
	let model: String
	let contextUsage: PimuxSessionContextUsage?
	let supportsImages: Bool?

	init(
		hostLocation: String,
		hostConnected: Bool,
		id: String,
		summary: String,
		createdAt: Date,
		updatedAt: Date,
		lastUserMessageAt: Date,
		lastAssistantMessageAt: Date,
		cwd: String,
		model: String,
		contextUsage: PimuxSessionContextUsage? = nil,
		supportsImages: Bool? = nil
	) {
		self.hostLocation = hostLocation
		self.hostConnected = hostConnected
		self.id = id
		self.summary = summary
		self.createdAt = createdAt
		self.updatedAt = updatedAt
		self.lastUserMessageAt = lastUserMessageAt
		self.lastAssistantMessageAt = lastAssistantMessageAt
		self.cwd = cwd
		self.model = model
		self.contextUsage = contextUsage
		self.supportsImages = supportsImages
	}
}

struct PimuxSessionMessagesResponse: Decodable, Equatable, Sendable {
	let sessionId: String
	let messages: [PimuxTranscriptMessage]
	let freshness: PimuxTranscriptFreshness
	let activity: PimuxSessionActivity
	let warnings: [String]
}

struct PimuxTranscriptMessage: Decodable, Equatable, Sendable {
	let createdAt: Date
	let role: String
	let body: String
	let toolName: String?
	let blocks: [PimuxTranscriptMessageBlock]

	enum CodingKeys: String, CodingKey {
		case createdAt = "created_at"
		case role
		case body
		case toolName
		case blocks
	}

	init(createdAt: Date, role: String, body: String, toolName: String? = nil, blocks: [PimuxTranscriptMessageBlock]? = nil) {
		self.createdAt = createdAt
		self.role = role
		self.body = body
		self.toolName = toolName
		if let blocks {
			self.blocks = blocks
		} else if !body.isEmpty {
			self.blocks = [PimuxTranscriptMessageBlock(type: "text", text: body, toolCallName: nil, mimeType: nil, attachmentId: nil)]
		} else {
			self.blocks = []
		}
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let createdAt = try container.decode(Date.self, forKey: .createdAt)
		let role = try container.decode(String.self, forKey: .role)
		let body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
		let toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
		let blocks = try container.decodeIfPresent([PimuxTranscriptMessageBlock].self, forKey: .blocks)
		self.init(createdAt: createdAt, role: role, body: body, toolName: toolName, blocks: blocks)
	}
}

struct PimuxTranscriptMessageBlock: Decodable, Equatable, Sendable {
	let type: String
	let text: String?
	let toolCallName: String?
	let mimeType: String?
	let attachmentId: String?

	init(type: String, text: String?, toolCallName: String?, mimeType: String? = nil, attachmentId: String? = nil) {
		self.type = type
		self.text = text
		self.toolCallName = toolCallName
		self.mimeType = mimeType
		self.attachmentId = attachmentId
	}
}

struct PimuxSessionCommand: Decodable, Equatable, Identifiable, Sendable {
	let name: String
	let description: String?
	let source: String

	var id: String { name }
}

struct PimuxSessionCommandsResponse: Decodable, Sendable {
	let sessionId: String
	let commands: [PimuxSessionCommand]
}

struct PimuxTranscriptFreshness: Decodable, Equatable, Sendable {
	let state: String
	let source: String
	let asOf: Date
}

struct PimuxSessionActivity: Decodable, Equatable, Sendable {
	let active: Bool
	let attached: Bool
}

enum PimuxSessionStreamEvent: Decodable, Equatable, Sendable {
	case snapshot(sequence: UInt64, session: PimuxSessionMessagesResponse)
	case sessionState(sequence: UInt64, connected: Bool, missing: Bool, lastSeenAt: Date?)
	case keepalive(sequence: UInt64, timestamp: Date)

	private enum CodingKeys: String, CodingKey {
		case type
		case sequence
		case session
		case connected
		case missing
		case lastSeenAt = "last_seen_at"
		case timestamp
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)
		let sequence = try container.decode(UInt64.self, forKey: .sequence)

		switch type {
		case "snapshot":
			self = .snapshot(
				sequence: sequence,
				session: try container.decode(PimuxSessionMessagesResponse.self, forKey: .session)
			)
		case "sessionState":
			self = .sessionState(
				sequence: sequence,
				connected: try container.decode(Bool.self, forKey: .connected),
				missing: try container.decode(Bool.self, forKey: .missing),
				lastSeenAt: try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
			)
		case "keepalive":
			self = .keepalive(
				sequence: sequence,
				timestamp: try container.decode(Date.self, forKey: .timestamp)
			)
		default:
			throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown stream event type: \(type)")
		}
	}
}

struct PimuxInputImage: Encodable, Equatable, Sendable {
	let type: String
	let mimeType: String
	let data: String

	init(mimeType: String, data: String) {
		self.type = "image"
		self.mimeType = mimeType
		self.data = data
	}
}

private struct PimuxSendMessageRequest: Encodable {
	let body: String
	let images: [PimuxInputImage]
}


struct PimuxServerClient {
	private let baseURL: URL
	private let session: URLSession

	init(baseURL: String) throws {
		self.baseURL = try Self.normalizedBaseURL(from: baseURL)
		self.session = Self.makeSession()
	}

	func health() async throws {
		let response = try await requestText(path: "/health")
		guard response == "OK" else {
			throw PimuxServerError.invalidResponse("Unexpected health response: \(response)")
		}
	}

	func listHosts() async throws -> [PimuxHostSessions] {
		try await requestJSON([PimuxHostSessions].self, path: "/hosts")
	}


	func listSessions(count: Int? = nil, beforeID: String? = nil) async throws -> [PimuxListedSession] {
		var queryItems: [URLQueryItem] = []
		if let count { queryItems.append(URLQueryItem(name: "count", value: "\(count)")) }
		if let beforeID { queryItems.append(URLQueryItem(name: "before_id", value: beforeID)) }
		return try await requestJSON([PimuxListedSession].self, path: "/sessions", queryItems: queryItems)
	}

	func listAllSessions(pageSize: Int = 25) async throws -> [PimuxListedSession] {
		var all: [PimuxListedSession] = []
		var beforeID: String?
		while true {
			let page = try await listSessions(count: pageSize, beforeID: beforeID)
			all.append(contentsOf: page)
			guard page.count >= pageSize, let lastID = page.last?.id else { break }
			beforeID = lastID
		}
		return all
	}

	func getMessages(sessionID: String) async throws -> PimuxSessionMessagesResponse {
		try await requestJSON(PimuxSessionMessagesResponse.self, path: "/sessions/\(sessionID)/messages")
	}

	func attachmentURL(sessionID: String, attachmentID: String) -> URL {
		baseURL
			.appendingPathComponent("sessions")
			.appendingPathComponent(sessionID)
			.appendingPathComponent("attachments")
			.appendingPathComponent(attachmentID)
	}

	func streamMessages(
		sessionID: String,
		onEvent: @escaping @Sendable (PimuxSessionStreamEvent) async -> Void
	) async throws {
		let request = try makeRequest(
			path: "/sessions/\(sessionID)/stream",
			queryItems: [],
			method: "GET",
			bodyData: nil,
			contentType: nil,
			accept: "application/x-ndjson"
		)

		let (bytes, response) = try await session.bytes(for: request)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw PimuxServerError.invalidResponse("Invalid HTTP response from the server.")
		}

		guard (200..<300).contains(httpResponse.statusCode) else {
			let data = try await collectData(from: bytes)
			throw PimuxServerError.serverError(
				Self.errorMessage(from: data, statusCode: httpResponse.statusCode),
				statusCode: httpResponse.statusCode
			)
		}

		for try await line in bytes.lines {
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.isEmpty { continue }
			do {
				let event = try await Self.decodeJSON(PimuxSessionStreamEvent.self, from: Data(trimmed.utf8))
				await onEvent(event)
			} catch {
				let preview = String(trimmed.prefix(200))
				print("Skipping undecodable stream event: \(error) - raw: \(preview)")
				continue
			}
		}
	}

	func getCommands(sessionID: String) async throws -> [PimuxSessionCommand] {
		let response = try await requestJSON(
			PimuxSessionCommandsResponse.self,
			path: "/sessions/\(sessionID)/commands"
		)
		return response.commands
	}

	func interruptSession(sessionID: String) async throws {
		_ = try await performRequest(
			path: "/sessions/\(sessionID)/interrupt",
			queryItems: [],
			method: "POST"
		)
	}

	func sendMessage(sessionID: String, body: String, images: [PimuxInputImage] = []) async throws {
		let requestData: Data
		do {
			requestData = try JSONEncoder().encode(PimuxSendMessageRequest(body: body, images: images))
		} catch {
			throw PimuxServerError.invalidResponse("Couldn't encode the message request.")
		}

		_ = try await performRequest(
			path: "/sessions/\(sessionID)/messages",
			queryItems: [],
			method: "POST",
			bodyData: requestData,
			contentType: "application/json"
		)
	}

	static func normalizedBaseURLString(from rawValue: String) throws -> String {
		try normalizedBaseURL(from: rawValue).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
	}

	private static func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.default
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.urlCache = nil
		return URLSession(configuration: configuration)
	}

	private static func percentEncodedPathComponent(_ value: String) -> String {
		value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
	}

	private static func normalizedBaseURL(from rawValue: String) throws -> URL {
		let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw PimuxServerError.invalidServerURL("Enter a pimux server URL.")
		}

		let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
		guard var components = URLComponents(string: candidate) else {
			throw PimuxServerError.invalidServerURL("Invalid server URL: \(trimmed)")
		}

		guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
			throw PimuxServerError.invalidServerURL("The server URL must start with http:// or https://.")
		}
		components.scheme = scheme
		components.fragment = nil

		guard components.host?.isEmpty == false, let url = components.url else {
			throw PimuxServerError.invalidServerURL("Invalid server URL: \(trimmed)")
		}

		if url.path == "/" {
			let normalized = String(url.absoluteString.dropLast())
			guard let normalizedURL = URL(string: normalized) else {
				throw PimuxServerError.invalidServerURL("Invalid server URL: \(trimmed)")
			}
			return normalizedURL
		}

		return url
	}

	private nonisolated func requestJSON<Response: Decodable>(
		_ type: Response.Type,
		path: String,
		queryItems: [URLQueryItem] = []
	) async throws -> Response {
		let (data, _) = try await performRequest(path: path, queryItems: queryItems)
		do {
			return try await Self.decodeJSON(Response.self, from: data)
		} catch {
			throw PimuxServerError.invalidResponse("Invalid JSON response from the server.")
		}
	}

	private func requestText(path: String, queryItems: [URLQueryItem] = []) async throws -> String {
		let (data, _) = try await performRequest(path: path, queryItems: queryItems)
		guard let text = String(data: data, encoding: .utf8) else {
			throw PimuxServerError.invalidResponse("Invalid text response from the server.")
		}
		return text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func performRequest(
		path: String,
		queryItems: [URLQueryItem],
		method: String = "GET",
		bodyData: Data? = nil,
		contentType: String? = nil
	) async throws -> (Data, HTTPURLResponse) {
		let request = try makeRequest(
			path: path,
			queryItems: queryItems,
			method: method,
			bodyData: bodyData,
			contentType: contentType,
			accept: "application/json"
		)

		let (data, response) = try await session.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw PimuxServerError.invalidResponse("Invalid HTTP response from the server.")
		}

		guard (200..<300).contains(httpResponse.statusCode) else {
			throw PimuxServerError.serverError(
				Self.errorMessage(from: data, statusCode: httpResponse.statusCode),
				statusCode: httpResponse.statusCode
			)
		}

		return (data, httpResponse)
	}

	private func makeRequest(
		path: String,
		queryItems: [URLQueryItem],
		method: String,
		bodyData: Data?,
		contentType: String?,
		accept: String
	) throws -> URLRequest {
		guard let url = url(path: path, queryItems: queryItems) else {
			throw PimuxServerError.invalidServerURL("Invalid server URL.")
		}

		var request = URLRequest(url: url)
		request.httpMethod = method
		request.httpBody = bodyData
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
		request.setValue("no-cache", forHTTPHeaderField: "Pragma")
		request.setValue(accept, forHTTPHeaderField: "Accept")
		if let contentType {
			request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		}
		return request
	}

	private func url(path: String, queryItems: [URLQueryItem]) -> URL? {
		guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
			return nil
		}

		let basePath = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
		components.percentEncodedPath = basePath + path
		components.queryItems = queryItems.isEmpty ? nil : queryItems
		return components.url
	}

	private nonisolated static func decodeJSON<Response: Decodable>(
		_ type: Response.Type,
		from data: Data
	) async throws -> Response {
		try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				do {
					continuation.resume(returning: try Self.decoder.decode(Response.self, from: data))
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}

	private nonisolated static var decoder: JSONDecoder {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .custom { decoder in
			let container = try decoder.singleValueContainer()
			let string = try container.decode(String.self)

			let fractionalFormatter = ISO8601DateFormatter()
			fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
			if let date = fractionalFormatter.date(from: string) {
				return date
			}

			let formatter = ISO8601DateFormatter()
			formatter.formatOptions = [.withInternetDateTime]
			if let date = formatter.date(from: string) {
				return date
			}

			throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
		}
		return decoder
	}

	private static func errorMessage(from data: Data, statusCode: Int) -> String {
		if let errorResponse = try? decoder.decode(PimuxErrorResponse.self, from: data) {
			return errorResponse.error
		}

		if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
			!text.isEmpty {
			return text
		}

		return "Server returned HTTP \(statusCode)."
	}

	private func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
		var data = Data()
		for try await byte in bytes {
			data.append(byte)
		}
		return data
	}
}

private struct PimuxErrorResponse: Decodable {
	let error: String
}

enum PimuxServerError: LocalizedError {
	case invalidServerURL(String)
	case invalidResponse(String)
	case serverError(String, statusCode: Int)

	var errorDescription: String? {
		switch self {
		case .invalidServerURL(let message), .invalidResponse(let message), .serverError(let message, _):
			message
		}
	}

	var isNotFound: Bool {
		if case .serverError(_, let statusCode) = self {
			return statusCode == 404
		}
		return false
	}
}
