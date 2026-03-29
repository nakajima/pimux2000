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
	func testSlashCommandMenuAppears() throws {
		let app = configuredApp()
		app.launch()

		let sessionCell = app.staticTexts["Shell session health"]
		XCTAssertTrue(sessionCell.waitForExistence(timeout: 5))
		sessionCell.tap()

		let textField = app.textFields["Send a message"]
		XCTAssertTrue(textField.waitForExistence(timeout: 5))
		textField.tap()
		textField.typeText("/")

		// The slash command menu should appear with commands
		let compactCommand = app.staticTexts["/compact"]
		XCTAssertTrue(compactCommand.waitForExistence(timeout: 3))

		// Take screenshot showing the slash command menu
		let screenshot = app.screenshot()
		let attachment = XCTAttachment(screenshot: screenshot)
		attachment.name = "SlashCommandMenu"
		attachment.lifetime = .keepAlways
		add(attachment)
	}

	@MainActor
	func testSlashCommandMenuFilters() throws {
		let app = configuredApp()
		app.launch()

		let sessionCell = app.staticTexts["Shell session health"]
		XCTAssertTrue(sessionCell.waitForExistence(timeout: 5))
		sessionCell.tap()

		let textField = app.textFields["Send a message"]
		XCTAssertTrue(textField.waitForExistence(timeout: 5))
		textField.tap()
		textField.typeText("/co")

		// Should show filtered commands matching "co"
		let compactCommand = app.staticTexts["/compact"]
		XCTAssertTrue(compactCommand.waitForExistence(timeout: 3))
		let copyCommand = app.staticTexts["/copy"]
		XCTAssertTrue(copyCommand.exists)

		// Should not show unrelated commands
		let quitCommand = app.staticTexts["/quit"]
		XCTAssertFalse(quitCommand.exists)

		let screenshot = app.screenshot()
		let attachment = XCTAttachment(screenshot: screenshot)
		attachment.name = "SlashCommandMenuFiltered"
		attachment.lifetime = .keepAlways
		add(attachment)
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
