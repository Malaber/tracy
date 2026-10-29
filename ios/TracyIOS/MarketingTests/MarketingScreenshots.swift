import XCTest

final class MarketingScreenshots: XCTestCase {
    @MainActor
    func testCapture() async throws { try await captureScenes(innerDisplay: false) }

    @MainActor
    func testCaptureDuoInner() async throws { try await captureScenes(innerDisplay: true) }

    @MainActor
    private func captureScenes(innerDisplay: Bool) async throws {
        continueAfterFailure = false
        // The capture task creates fresh portrait simulators. Avoid a device-orientation
        // RPC before launching the app: it can hang in XCTest on CI.
        let app = XCUIApplication()
        func scrollToday(up: Bool, summary: Bool = false) {
            let column = app.descendants(matching: .any).matching(identifier: summary ? "todaySummary" : "todayDetails").firstMatch
            let surface = column.exists ? column : app
            if up { surface.swipeUp() } else { surface.swipeDown() }
        }
        func launch(_ appearance: String, state: String? = nil) {
            app.launchArguments = [
                "--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                "-appearance", appearance,
            ]
            if let state { app.launchArguments.append(state) }
            app.launch()
            if innerDisplay { XCUIDevice.shared.orientation = .landscapeLeft }
            XCTAssertTrue(app.staticTexts["heroBillable"].waitForExistence(timeout: 15))
        }
        func capture(_ name: String) async throws {
            let attachment: XCTAttachment
            if innerDisplay {
                // XCTest rounds the odd inner-panel dimensions down by one pixel.
                // The local capture task returns the native simctl PNG at this exact scene.
                let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-port", withExtension: "txt"))
                let port = try String(contentsOf: config, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(name)"))
                let (data, response) = try await URLSession.shared.data(from: url)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            } else {
                attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            }
            attachment.name = "marketing-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        launch("light")
        try await capture("01-today")
        for _ in 0..<6 {
            if app.buttons["editToday"].isHittable { break }
            scrollToday(up: true)
        }
        app.buttons["editToday"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 5))
        try await capture("02-entry")
        app.buttons["Cancel"].tap()
        app.buttons["Recent Days"].firstMatch.tap()
        XCTAssertTrue(app.switches["Needs attention only"].waitForExistence(timeout: 5))
        try await capture("03-recent-days")
        app.buttons["Today"].firstMatch.tap()
        for _ in 0..<6 {
            if app.buttons["quickAction"].isHittable { break }
            scrollToday(up: false, summary: true)
        }
        app.buttons["quickAction"].tap()
        let syncStatus = app.descendants(matching: .any).matching(identifier: "syncStatusTitle").firstMatch
        for _ in 0..<8 {
            if syncStatus.exists && syncStatus.isHittable { break }
            scrollToday(up: true)
        }
        XCTAssertTrue(syncStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(syncStatus.label, "1 day waiting to sync")
        try await capture("04-offline")
        app.terminate()
        launch("dark")
        try await capture("05-dark")
        app.buttons["Statistics"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["statisticsBillable"].waitForExistence(timeout: 5))
        try await capture("06-statistics")
        app.buttons["Month"].tap()
        let forecast = app.descendants(matching: .any).matching(identifier: "monthForecastTotal").firstMatch
        let statisticsContent = app.descendants(matching: .any).matching(identifier: "statisticsContent").firstMatch
        for _ in 0..<6 {
            if forecast.isHittable { break }
            statisticsContent.swipeUp()
        }
        XCTAssertTrue(forecast.isHittable, app.debugDescription)
        try await capture("10-month-forecast")
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.buttons["appearancePicker"].waitForExistence(timeout: 5))
        try await capture("07-settings")
        app.terminate()
        launch("dark", state: "--ui-empty-day")
        try await capture("08-empty-day")
        app.terminate()
        launch("dark", state: "--ui-completed-day")
        try await capture("09-completed-day")
        app.terminate()
    }
}
