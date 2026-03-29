import Foundation
import GRDB
import GRDBQuery
import SwiftUI

@main
struct pimux2000App: App {
	let appDatabase: AppDatabase

	init() {
		let processInfo = ProcessInfo.processInfo

		if Self.isRunningForPreviews {
			appDatabase = AppDatabase.preview()
			return
		}

		let databaseURL = Self.databaseURL

		if processInfo.arguments.contains("--uitesting-reset-db") {
			try? FileManager.default.removeItem(at: databaseURL)
		}

		try! FileManager.default.createDirectory(
			at: databaseURL.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)

		appDatabase = try! AppDatabase(
			dbQueue: DatabaseQueue(path: databaseURL.path())
		)

		if processInfo.arguments.contains("--uitesting-use-fixtures") {
			try! UITestFixtures.install(in: appDatabase)
		}
	}

	var body: some Scene {
		WindowGroup {
			ContentView()
				.environment(\.appDatabase, appDatabase)
				.databaseContext(.readWrite { appDatabase.dbQueue })
		}
	}

	private static var isRunningForPreviews: Bool {
		ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
	}

	private static var databaseURL: URL {
		URL.documentsDirectory.appending(path: "db.sqlite")
	}
}
