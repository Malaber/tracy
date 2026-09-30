import XCTest

final class TracyUITests: XCTestCase {
    private var testArguments: [String] {
        [
            "--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
    }

    @MainActor
    func testTodayLightContrast() throws {
        try auditToday(appearance: "light", category: .contrast, name: "Contrast")
    }

    @MainActor
    func testTodayLightHitRegions() throws {
        try auditToday(appearance: "light", category: .hitRegion, name: "HitRegions")
    }

    @MainActor
    func testTodayLightDescriptions() throws {
        try auditToday(appearance: "light", category: .sufficientElementDescription, name: "Descriptions")
    }

    @MainActor
    func testTodayLightClipping() throws {
        try auditToday(appearance: "light", category: .textClipped, name: "Clipping")
    }

    @MainActor
    func testTodayLightTraits() throws {
        try auditToday(appearance: "light", category: .trait, name: "Traits")
    }

    @MainActor
    func testTodayDarkContrast() throws {
        try auditToday(appearance: "dark", category: .contrast, name: "Contrast")
    }

    @MainActor
    func testTodayDarkHitRegions() throws {
        try auditToday(appearance: "dark", category: .hitRegion, name: "HitRegions")
    }

    @MainActor
    func testTodayDarkDescriptions() throws {
        try auditToday(appearance: "dark", category: .sufficientElementDescription, name: "Descriptions")
    }

    @MainActor
    func testTodayDarkClipping() throws {
        try auditToday(appearance: "dark", category: .textClipped, name: "Clipping")
    }

    @MainActor
    func testTodayDarkTraits() throws {
        try auditToday(appearance: "dark", category: .trait, name: "Traits")
    }

    @MainActor
    private func auditToday(appearance: String, category: XCUIAccessibilityAuditType, name: String) throws {
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
        screenshot.name = "Today-\(appearance)-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // One category per fresh launch reduces work under the service's fixed
        // timeout and identifies the failing category without retries.
        try app.performAccessibilityAudit(for: category) { issue in
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
