import XCTest

final class MarketingScreenshots: XCTestCase {
    @MainActor
    func testCapture() {
        continueAfterFailure = false
        // The capture task creates fresh portrait simulators. Avoid a device-orientation
        // RPC before launching the app: it can hang in XCTest on CI.
        let app = XCUIApplication()
        func launch(_ appearance: String) {
            app.launchArguments = [
                "--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                "-appearance", appearance,
            ]
            app.launch()
            XCTAssertTrue(app.buttons["editToday"].waitForExistence(timeout: 15))
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "marketing-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        launch("light")
        capture("01-today")
        app.buttons["editToday"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 5))
        capture("02-entry")
        app.buttons["Cancel"].tap()
        app.buttons["Recent Days"].firstMatch.tap()
        XCTAssertTrue(app.switches["Needs attention only"].waitForExistence(timeout: 5))
        capture("03-recent-days")
        app.buttons["Today"].firstMatch.tap()
        app.buttons["quickAction"].tap()
        XCTAssertTrue(app.staticTexts["1 days waiting to sync"].waitForExistence(timeout: 5))
        capture("04-offline")
        app.terminate()
        launch("dark")
        capture("05-dark")
        app.terminate()
    }
}
