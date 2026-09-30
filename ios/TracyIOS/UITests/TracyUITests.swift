import XCTest

final class TracyUITests: XCTestCase {
    private var testArguments: [String] {
        [
            "--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
    }

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
        app.launchArguments = testArguments + ["-appearance", appearance]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["editToday"].waitForExistence(timeout: 15))
        // Application screenshots resolve an accessibility snapshot. After an audit the
        // hosted iPad service can stop answering those queries. Screen capture does not
        // query the app hierarchy; collect evidence before handing control to the audit.
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Today-\(appearance)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try app.performAccessibilityAudit(for: [
            .contrast, .hitRegion, .sufficientElementDescription, .textClipped, .trait,
        ]) { issue in
            // Do not resolve issue.element: that performs another accessibility query
            // while the audit service is handling a finding.
            print("Accessibility audit: \(issue.detailedDescription)")
            return false
        }
    }

    @MainActor
    func testOfflineEntryAndReviewNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = testArguments
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
            "--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
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
