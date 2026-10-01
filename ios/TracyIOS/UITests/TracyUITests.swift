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
        verifyTodayLayout(appearance: "light")
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
        verifyTodayLayout(appearance: "dark")
    }

    @MainActor
    func testTodayDarkTraits() throws {
        try auditToday(appearance: "dark", category: .trait, name: "Traits")
    }

    @MainActor
    func testClippingMeasurementRejectsTruncation() {
        let app = XCUIApplication()
        app.launchArguments = testArguments + ["--ui-layout-checks", "--ui-clipping-negative-control"]
        app.launch()
        defer { app.terminate() }
        let text = app.descendants(matching: .any).matching(identifier: "layout.negative").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        let clipped = NSPredicate(format: "value BEGINSWITH %@", "clipped:")
        expectation(for: clipped, evaluatedWith: text)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func verifyTodayLayout(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = testArguments + ["--ui-layout-checks", "-appearance", appearance]
        app.launch()
        defer { app.terminate() }
        for key in [
            "date", "headline", "action", "section", "label.Check-in", "value.Check-in",
            "label.Check-out", "value.Check-out", "label.Breaks", "value.Breaks", "edit", "review",
        ] {
            // Buttons retain their existing identifiers and inherit their label value.
            let identifier = key == "action" ? "quickAction" : key == "edit" ? "editToday" : "layout.\(key)"
            let text = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
            for _ in 0..<6 {
                if text.exists { break }
                app.swipeUp()
            }
            guard text.waitForExistence(timeout: 5) else {
                XCTFail("Missing measured label: \(key). \(app.debugDescription)")
                return
            }
            XCTAssertEqual(text.value as? String, "fits", "\(key): \(text.debugDescription)")
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Today-layout-\(appearance)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
        let form = app.descendants(matching: .any).matching(identifier: "entryForm").firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 15))
        // SwiftUI's multiline field can expose TextField or TextView across OS versions.
        let notes = app.descendants(matching: .any).matching(identifier: "entryNotes").firstMatch
        // Scroll only the editor, and only until the target is visible. The iPad sheet
        // doesn't cover the whole app, so a full-application swipe can hit its backdrop.
        for _ in 0..<6 {
            if notes.exists && notes.isHittable { break }
            form.swipeUp()
        }
        guard notes.waitForExistence(timeout: 15), notes.isHittable else {
            XCTFail("Notes control did not become visible inside the editor")
            return
        }
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
