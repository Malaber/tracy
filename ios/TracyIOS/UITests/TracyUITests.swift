import XCTest

final class TracyUITests: XCTestCase {
    @MainActor
    func testTodayAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["Today"].firstMatch.waitForExistence(timeout: 10))
        for appearance in ["Light", "Dark"] {
            app.buttons["Settings"].firstMatch.tap()
            app.buttons["appearancePicker"].tap()
            app.buttons[appearance].tap()
            app.buttons["Today"].firstMatch.tap()
            try app.performAccessibilityAudit(for: [
                .contrast, .hitRegion, .sufficientElementDescription, .textClipped, .trait,
            ]) { issue in
                print(
                    "Accessibility audit: \(issue.detailedDescription); element: \(String(describing: issue.element))"
                )
                return false
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Today-\(appearance)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testOfflineEntryAndReviewNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["TRACY_UI_JOURNAL"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["editToday"].waitForExistence(timeout: 10))
        app.buttons["editToday"].tap()
        let notes = app.textFields["entryNotes"]
        app.swipeUp()
        XCTAssertTrue(notes.waitForExistence(timeout: 3))
        notes.tap()
        notes.typeText("Offline project notes")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.staticTexts["Offline project notes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1 days waiting to sync"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Offline project notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 days waiting to sync"].exists)
        app.buttons["Recent Days"].firstMatch.tap()
        XCTAssertTrue(app.switches["Needs attention only"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testAppearanceAndAccessibility() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["appearancePicker"].waitForExistence(timeout: 3))
        app.buttons["appearancePicker"].tap()
        app.buttons["Dark"].tap()
        XCTAssertTrue(app.staticTexts["Dark"].exists)
    }
}
