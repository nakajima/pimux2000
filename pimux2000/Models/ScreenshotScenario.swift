import Foundation

enum ScreenshotScenario: String {
	case overview
	case transcript
	case slashCommands = "slash-commands"

	static func current(from processInfo: ProcessInfo = .processInfo) -> Self? {
		guard let rawValue = processInfo.arguments.value(after: "--screenshot-scenario") else {
			return nil
		}
		return Self(rawValue: rawValue)
	}
}

private extension Array where Element == String {
	func value(after flag: String) -> String? {
		guard let index = firstIndex(of: flag) else { return nil }
		let valueIndex = self.index(after: index)
		guard valueIndex < endIndex else { return nil }
		return self[valueIndex]
	}
}
