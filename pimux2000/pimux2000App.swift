import Foundation
import GRDB
import GRDBQuery
import SwiftUI

@main
struct pimux2000App: App {
	let appDatabase: AppDatabase

	init() {
		let processInfo = ProcessInfo.processInfo
		let databaseURL = URL.documentsDirectory.appending(path: "db.sqlite")

		if processInfo.arguments.contains("--uitesting-reset-db") {
			try? FileManager.default.removeItem(at: databaseURL)
		}

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
}
