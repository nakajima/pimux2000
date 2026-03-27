import Foundation

// MARK: - Server client that talks to the pimux2000 Bun server

public actor PiServerClient {
	private let serverURL: URL
	private var webSocket: URLSessionWebSocketTask?
	private let session: URLSession
	private var requestCounter = 0
	private var pendingRequests: [String: CheckedContinuation<JSONObject, Error>] = [:]
	private var onSessionsUpdated: (([JSONObject]) -> Void)?
	private var onMessagesUpdated: ((String, [JSONObject]) -> Void)?
	private var receiveTask: Task<Void, Never>?

	public init(serverURL: URL) {
		self.serverURL = serverURL
		self.session = Self.makeSession()
	}

	public init(serverURL: String) {
		self.serverURL = URL(string: serverURL)!
		self.session = Self.makeSession()
	}

	private static func makeSession() -> URLSession {
		let configuration = URLSessionConfiguration.default
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		configuration.urlCache = nil
		return URLSession(configuration: configuration)
	}

	// MARK: - Connection

	public func connect() async throws {
		if webSocket != nil { return }

		let wsURL: URL
		if serverURL.scheme == "http" || serverURL.scheme == "https" {
			var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
			components.scheme = serverURL.scheme == "https" ? "wss" : "ws"
			wsURL = components.url!
		} else {
			wsURL = serverURL
		}

		let ws = session.webSocketTask(with: wsURL)
		ws.resume()
		self.webSocket = ws
		self.receiveTask = Task { [weak self] in
			await self?.receiveLoop()
		}
	}

	public func disconnect() {
		receiveTask?.cancel()
		receiveTask = nil
		webSocket?.cancel(with: .normalClosure, reason: nil)
		webSocket = nil
		failAllPendingRequests(error: PiError.commandFailed("Connection closed"))
	}

	// MARK: - Push handlers

	public func setSessionsUpdateHandler(_ handler: @escaping @Sendable ([JSONObject]) -> Void) {
		self.onSessionsUpdated = handler
	}

	public func setMessagesUpdateHandler(_ handler: @escaping @Sendable (String, [JSONObject]) -> Void) {
		self.onMessagesUpdated = handler
	}

	// MARK: - API

	public func listSessions() async throws -> [JSONObject] {
		let response = try await sendHTTPGet(path: "/sessions")
		guard let data = response["data"]?.arrayValue else {
			throw PiError.invalidResponse("Missing sessions data")
		}
		return data.compactMap { $0.objectValue }
	}

	public func getMessages(sessionFile: String) async throws -> [JSONObject] {
		let response = try await sendHTTPGet(
			path: "/messages",
			queryItems: [URLQueryItem(name: "sessionFile", value: sessionFile)]
		)
		guard let data = response["data"]?.arrayValue else {
			throw PiError.invalidResponse("Missing messages data")
		}
		return data.compactMap { $0.objectValue }
	}

	public func getState(sessionId: String) async throws -> JSONObject? {
		let response = try await sendHTTPGet(
			path: "/state",
			queryItems: [URLQueryItem(name: "sessionId", value: sessionId)]
		)
		return response["data"]?.objectValue
	}

	public func getLastAssistantText(sessionFile: String) async throws -> String? {
		let response = try await sendHTTPGet(
			path: "/last_assistant_text",
			queryItems: [URLQueryItem(name: "sessionFile", value: sessionFile)]
		)
		return response["text"]?.stringValue
	}

	public func prompt(sessionFile: String, message: String, cwd: String? = nil) async throws -> JSONObject {
		var extra: JSONObject = [
			"sessionFile": .string(sessionFile),
			"message": .string(message),
		]
		if let cwd { extra["cwd"] = .string(cwd) }
		let response = try await sendRequest(type: "prompt", extra: extra)
		try validatePromptResponse(response)
		return response
	}

	// MARK: - HTTP

	private func sendHTTPGet(path: String, queryItems: [URLQueryItem] = []) async throws -> JSONObject {
		var components = URLComponents(url: httpBaseURL(), resolvingAgainstBaseURL: false)
		components?.path = path
		components?.queryItems = queryItems.isEmpty ? nil : queryItems

		guard let url = components?.url else {
			throw PiError.invalidResponse("Invalid server URL")
		}

		var request = URLRequest(url: url)
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
		request.setValue("no-cache", forHTTPHeaderField: "Pragma")

		let (data, response) = try await session.data(for: request)
		guard let httpResponse = response as? HTTPURLResponse else {
			throw PiError.invalidResponse("Invalid HTTP response")
		}

		guard (200..<300).contains(httpResponse.statusCode) else {
			let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
			if httpResponse.statusCode == 404 || message == "Expected WebSocket" {
				throw PiError.commandFailed("The remote server is too old. Please update it from pimux2000.")
			}

			throw PiError.commandFailed(message?.isEmpty == false ? message! : "Server returned HTTP \(httpResponse.statusCode)")
		}

		guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
			let object = value.objectValue else {
			throw PiError.invalidResponse("Invalid JSON response")
		}

		if let error = object["error"]?.stringValue {
			throw PiError.rpcFailure(error)
		}

		return object
	}

	private func httpBaseURL() -> URL {
		guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
			return serverURL
		}

		switch components.scheme {
		case "ws":
			components.scheme = "http"
		case "wss":
			components.scheme = "https"
		default:
			break
		}

		return components.url ?? serverURL
	}

	// MARK: - Request/response plumbing

	private func nextRequestId() -> String {
		requestCounter += 1
		return "req-\(requestCounter)"
	}

	private func sendRequest(type: String, extra: JSONObject = [:]) async throws -> JSONObject {
		guard let ws = webSocket else {
			throw PiError.commandFailed("Not connected")
		}

		let requestId = nextRequestId()
		var payload = extra
		payload["id"] = .string(requestId)
		payload["type"] = .string(type)

		let data = try JSONEncoder().encode(payload)
		guard let string = String(data: data, encoding: .utf8) else {
			throw PiError.invalidResponse("Failed to encode request")
		}

		return try await withCheckedThrowingContinuation { continuation in
			self.pendingRequests[requestId] = continuation
			ws.send(.string(string)) { error in
				if let error {
					Task { await self.failRequest(id: requestId, error: error) }
				}
			}
		}
	}

	private func failRequest(id: String, error: Error) {
		if let continuation = pendingRequests.removeValue(forKey: id) {
			continuation.resume(throwing: error)
		}
	}

	private func failAllPendingRequests(error: Error) {
		let pending = pendingRequests
		pendingRequests.removeAll()
		for (_, continuation) in pending {
			continuation.resume(throwing: error)
		}
	}

	private func validatePromptResponse(_ response: JSONObject) throws {
		guard let responses = response["responses"]?.arrayValue else { return }

		for item in responses {
			guard let object = item.objectValue else { continue }
			if object["success"]?.boolValue == false {
				throw PiError.rpcFailure(object["error"]?.stringValue ?? "Unknown RPC error")
			}
		}
	}

	// MARK: - Receive loop

	private func receiveLoop() async {
		guard let ws = webSocket else { return }

		while !Task.isCancelled {
			do {
				let message = try await ws.receive()
				let text: String
				switch message {
				case .string(let s): text = s
				case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
				@unknown default: continue
				}

				guard let data = text.data(using: .utf8),
					let value = try? JSONDecoder().decode(JSONValue.self, from: data),
					let object = value.objectValue else { continue }

				await handleServerMessage(object)
			} catch {
				if Task.isCancelled { break }
				webSocket = nil
				receiveTask = nil
				failAllPendingRequests(error: error)
				break
			}
		}
	}

	private func handleServerMessage(_ msg: JSONObject) async {
		let type = msg["type"]?.stringValue ?? ""

		// Check if this is a response to a pending request
		if let id = msg["id"]?.stringValue, let continuation = pendingRequests.removeValue(forKey: id) {
			if let error = msg["error"]?.stringValue {
				continuation.resume(throwing: PiError.rpcFailure(error))
			} else {
				continuation.resume(returning: msg)
			}
			return
		}

		// Push messages
		switch type {
		case "sessions_updated":
			if let data = msg["data"]?.arrayValue {
				onSessionsUpdated?(data.compactMap { $0.objectValue })
			}
		case "messages_updated":
			if let sessionFile = msg["sessionFile"]?.stringValue,
				let data = msg["data"]?.arrayValue {
				onMessagesUpdated?(sessionFile, data.compactMap { $0.objectValue })
			}
		default:
			break
		}
	}
}
