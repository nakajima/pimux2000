import XCTest

final class pimux2000UITests: XCTestCase {
	override func setUpWithError() throws {
		continueAfterFailure = false
	}

	override func tearDownWithError() throws {}

	@MainActor
	func testSelectingFixtureSessionShowsTranscript() throws {
		let app = configuredApp()
		app.launch()

		let sessionCell = app.staticTexts["Shell session health"]
		XCTAssertTrue(sessionCell.waitForExistence(timeout: 5))
		sessionCell.tap()

		let userMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Run the health check")).firstMatch
		XCTAssertTrue(userMessage.waitForExistence(timeout: 5))

		let assistantMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Everything looks healthy")).firstMatch
		XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5))
	}

	@MainActor
	func testLaunchPerformance() throws {
		measure(metrics: [XCTApplicationLaunchMetric()]) {
			let app = configuredApp()
			app.launch()
		}
	}

	private func configuredApp() -> XCUIApplication {
		let app = XCUIApplication()
		app.terminate()
		app.launchArguments += ["--uitesting-reset-db", "--uitesting-use-fixtures"]
		return app
	}
}
