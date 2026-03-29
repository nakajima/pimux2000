import Foundation
import os.signpost

enum SessionSelectionPerformanceTrace {
	private static let log = OSLog(subsystem: "fm.folder.pimux2000", category: "PointsOfInterest")
	private static let lock = NSLock()
	private static var activeSelection: ActiveSelection?

	private struct ActiveSelection {
		let sessionID: String
		let token: String
		let signpostID: OSSignpostID
	}

	struct Interval {
		fileprivate let name: StaticString
		fileprivate let signpostID: OSSignpostID
		fileprivate let sessionID: String
		fileprivate let token: String?
	}

	static func beginSelection(sessionID: String, source: String) {
		let nextSelection = ActiveSelection(
			sessionID: sessionID,
			token: UUID().uuidString,
			signpostID: OSSignpostID(log: log)
		)

		let previousSelection: ActiveSelection?
		lock.lock()
		previousSelection = activeSelection
		activeSelection = nextSelection
		lock.unlock()

		if let previousSelection {
			finish(previousSelection, reason: "superseded source=\(source)")
		}

		os_signpost(
			.begin,
			log: log,
			name: "SessionOpen",
			signpostID: nextSelection.signpostID,
			"%{public}s",
			payload(sessionID: sessionID, token: nextSelection.token, message: "source=\(source)")
		)

		emitEvent(sessionID: sessionID, name: "SelectionChanged", message: "source=\(source)")
	}

	static func endSelection(sessionID: String, reason: String) {
		let finishedSelection: ActiveSelection?
		lock.lock()
		if activeSelection?.sessionID == sessionID {
			finishedSelection = activeSelection
			activeSelection = nil
		} else {
			finishedSelection = nil
		}
		lock.unlock()

		guard let finishedSelection else { return }
		finish(finishedSelection, reason: reason)
	}

	static func emitEvent(sessionID: String, name: StaticString, message: String = "") {
		let activeSelection = activeSelection(for: sessionID)
		let signpostID = activeSelection?.signpostID ?? OSSignpostID(log: log)
		os_signpost(
			.event,
			log: log,
			name: name,
			signpostID: signpostID,
			"%{public}s",
			payload(sessionID: sessionID, token: activeSelection?.token, message: message)
		)
	}

	static func beginInterval(name: StaticString, sessionID: String, message: String = "") -> Interval {
		let activeSelection = activeSelection(for: sessionID)
		let interval = Interval(
			name: name,
			signpostID: OSSignpostID(log: log),
			sessionID: sessionID,
			token: activeSelection?.token
		)

		os_signpost(
			.begin,
			log: log,
			name: name,
			signpostID: interval.signpostID,
			"%{public}s",
			payload(sessionID: sessionID, token: activeSelection?.token, message: message)
		)

		return interval
	}

	static func endInterval(_ interval: Interval, message: String = "") {
		os_signpost(
			.end,
			log: log,
			name: interval.name,
			signpostID: interval.signpostID,
			"%{public}s",
			payload(sessionID: interval.sessionID, token: interval.token, message: message)
		)
	}

	private static func activeSelection(for sessionID: String) -> ActiveSelection? {
		lock.lock()
		defer { lock.unlock() }
		guard activeSelection?.sessionID == sessionID else { return nil }
		return activeSelection
	}

	private static func finish(_ selection: ActiveSelection, reason: String) {
		os_signpost(
			.end,
			log: log,
			name: "SessionOpen",
			signpostID: selection.signpostID,
			"%{public}s",
			payload(sessionID: selection.sessionID, token: selection.token, message: "reason=\(reason)")
		)
	}

	private static func payload(sessionID: String, token: String?, message: String) -> String {
		let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
		let tokenDescription = token ?? "none"
		if trimmedMessage.isEmpty {
			return "session=\(sessionID) token=\(tokenDescription)"
		}
		return "session=\(sessionID) token=\(tokenDescription) \(trimmedMessage)"
	}
}
