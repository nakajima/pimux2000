import Combine
import Foundation

struct SSHHostKeyPrompt: Identifiable, Equatable {
	let hostID: Int64
	let sshTarget: String
	let details: String
	let retryAction: SSHHostKeyRetryAction

	var id: String { "\(hostID):\(sshTarget):\(retryAction.id)" }

	var message: String {
		"SSH could not verify the host key for \(sshTarget).\n\n\(details)\n\nTrust this host and continue? This relaxes host key checking for the rest of this app session."
	}
}

enum SSHHostKeyRetryAction: Equatable {
	case refresh
	case transcript(sessionID: String)
	case send(sessionID: String, message: String)

	var id: String {
		switch self {
		case .refresh:
			return "refresh"
		case let .transcript(sessionID):
			return "transcript:\(sessionID)"
		case let .send(sessionID, message):
			return "send:\(sessionID):\(message)"
		}
	}
}
