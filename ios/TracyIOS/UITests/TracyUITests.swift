import XCTest

final class TracyUITests: XCTestCase {
    @MainActor
    func testTodayAccessibilityLight() throws {
        try auditToday(appearance: "light")
    }

    @MainActor
    func testTodayAccessibilityDark() throws {
        try auditToday(appearance: "dark")
    }

    @MainActor
    private func auditToday(appearance: String) throws {
        let app = XCUIApplication()
        // Launch directly in the audited appearance, without a live scheme transition.
        app.launchArguments = ["--ui-testing", "-appearance", appearance]
        app.launch()
        defer {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Today-\(appearance)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
        XCTAssertTrue(app.buttons["editToday"].waitForExistence(timeout: 15))
        for attempt in 0..<2 {
            do {
                try app.performAccessibilityAudit(for: [
                    .contrast, .hitRegion, .sufficientElementDescription, .textClipped, .trait,
                ]) { issue in
                    print(
                        "Accessibility audit: \(issue.detailedDescription); element: \(String(describing: issue.element))"
                    )
                    return false
                }
                return
            } catch {
                let failure = error as NSError
                // Hosted iPad accessibility service sometimes times out. Never retry findings
                // or unrelated failures, and propagate a repeated timeout to CI.
                guard attempt == 0,
                    failure.domain == "com.apple.xcode.xctest.accessibilityAudit",
                    failure.code == -56
                else { throw error }
                let diagnostic = XCTAttachment(string: "Retrying audit infrastructure timeout: \(failure)")
                diagnostic.lifetime = .keepAlways
                add(diagnostic)
                app.terminate()
                app.launch()
                XCTAssertTrue(app.buttons["editToday"].waitForExistence(timeout: 15))
            }
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
