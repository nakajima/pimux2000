//
//  pimux2000UITests.swift
//  pimux2000UITests
//
//  Created by Pat Nakajima on 3/22/26.
//

import XCTest

final class pimux2000UITests: XCTestCase {
	override func setUpWithError() throws {
		continueAfterFailure = false
	}

	override func tearDownWithError() throws {}

	@MainActor
	func testFixtureHostShowsSessions() throws {
		let app = configuredApp()
		app.launch()

		let hostField = app.textFields["hostTextField"]
		XCTAssertTrue(hostField.waitForExistence(timeout: 5))
		hostField.tap()
		hostField.typeText("demo@fixture")

		let addButton = app.buttons["addHostButton"]
		XCTAssertTrue(addButton.isEnabled)
		addButton.tap()

		let hostCell = app.staticTexts["demo@fixture"]
		XCTAssertTrue(hostCell.waitForExistence(timeout: 10))
		let shellSummary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Shell session health")).firstMatch
		XCTAssertTrue(shellSummary.waitForExistence(timeout: 15))

		let logsSummary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Watching logs")).firstMatch
		XCTAssertTrue(logsSummary.waitForExistence(timeout: 15))
		XCTAssertFalse(app.staticTexts["Couldn’t Load Sessions"].exists)
	}

	@MainActor
	func testBrokenFixtureHostShowsRecoverableError() throws {
		let app = configuredApp()
		app.launch()

		let hostField = app.textFields["hostTextField"]
		XCTAssertTrue(hostField.waitForExistence(timeout: 5))
		hostField.tap()
		hostField.typeText("broken@fixture")

		let addButton = app.buttons["addHostButton"]
		XCTAssertTrue(addButton.isEnabled)
		addButton.tap()

		XCTAssertTrue(app.staticTexts["broken@fixture"].waitForExistence(timeout: 5))
		XCTAssertTrue(app.staticTexts["Couldn’t Load Sessions"].waitForExistence(timeout: 5))

		let fixtureMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "configured to fail")).firstMatch
		XCTAssertTrue(fixtureMessage.waitForExistence(timeout: 5))
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
