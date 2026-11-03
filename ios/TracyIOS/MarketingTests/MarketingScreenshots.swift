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
        func selectTab(_ title: String) {
            // Native navigation has different AX containers on iPhone, iPad and
            // Duo. Resolve a complete exact-label snapshot, not lazy firstMatch
            // traversal (which stalled in XCT's first-matching-snapshot iterator).
            let tabs = app.buttons.matching(NSPredicate(format: "label == %@", title))
                .allElementsBoundByIndex.filter { $0.isHittable }
            guard let tab = tabs.first else {
                XCTFail("No visible navigation tab \(title)")
                return
            }
            // iPad can expose multiple visible representations of the same tab.
            // Destination assertions below verify the selected screen.
            tab.tap()
        }
        func scrollToday(up: Bool, summary: Bool = false) {
            let lists = app.collectionViews.allElementsBoundByIndex
            let identifier = summary ? "todaySummary" : "todayDetails"
            let surface = lists.first(where: { $0.identifier == identifier }) ?? lists.first ?? app
            if up { surface.swipeUp() } else { surface.swipeDown() }
        }
        func showTodayTop() {
            selectTab("Today")
            // Scroll both split columns to their start. Hittable alone is not
            // sufficient: controls behind the translucent toolbar can match.
            for summary in [true, false] {
                for _ in 0..<4 { scrollToday(up: false, summary: summary) }
            }
            XCTAssertTrue(app.staticTexts["heroBillable"].isHittable)
        }
        app.launchArguments = [
            "--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
        app.launch()
        if innerDisplay { XCUIDevice.shared.orientation = .landscapeLeft }
        XCTAssertTrue(app.staticTexts["heroBillable"].waitForExistence(timeout: 15))
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
        try await capture("01-today")
        for _ in 0..<6 {
            if app.buttons["editToday"].isHittable { break }
            scrollToday(up: true)
        }
        app.buttons["editToday"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 5))
        try await capture("02-entry")
        app.buttons["Cancel"].tap()
        selectTab("Recent Days")
        XCTAssertTrue(app.switches["Needs attention only"].waitForExistence(timeout: 5))
        try await capture("03-recent-days")
        showTodayTop()
        if innerDisplay {
            for _ in 0..<6 {
                if app.buttons["editToday"].isHittable { break }
                scrollToday(up: true)
            }
            app.buttons["editToday"].tap()
            let notes = app.textFields["entryNotes"]
            let form = app.collectionViews["entryForm"]
            for _ in 0..<8 {
                if notes.exists && notes.isHittable { break }
                form.swipeUp()
            }
            XCTAssertTrue(notes.isHittable)
            notes.tap()
            notes.typeText("Duo transition draft")
            let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-port", withExtension: "txt"))
            let port = try String(contentsOf: config, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            for (index, angle) in [0, 180, 90, 180, 0, 180].enumerated() {
                let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/pose/\(angle)"))
                let (_, response) = try await URLSession.shared.data(from: url)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                // Area is orientation-independent; wait for the actual display
                // switch instead of assuming the injected hinge event has settled.
                let expectedArea: CGFloat = angle == 0 ? 466 * 678 : 669 * 951
                let displayChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    abs(app.frame.width * app.frame.height - expectedArea) < 2
                }, object: nil)
                await fulfillment(of: [displayChanged], timeout: 15)
                XCTAssertTrue(app.buttons["saveEntry"].waitForExistence(timeout: 10))
                // Form rows are virtualized. Folding can move Notes outside
                // the visible viewport, so reveal it before reading its value.
                for _ in 0..<8 {
                    if notes.exists && notes.isHittable { break }
                    form.swipeUp()
                }
                XCTAssertTrue(notes.isHittable)
                XCTAssertTrue((notes.value as? String)?.contains("Duo transition draft") == true)
                let imageURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/pose-image/\(angle)"))
                let (imageData, imageResponse) = try await URLSession.shared.data(from: imageURL)
                XCTAssertEqual((imageResponse as? HTTPURLResponse)?.statusCode, 200)
                let evidence = XCTAttachment(data: imageData, uniformTypeIdentifier: "public.png")
                evidence.name = "Duo-editor-pose-\(index)-\(angle)"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
            XCUIDevice.shared.orientation = .landscapeLeft
            app.buttons["saveEntry"].tap()
            for _ in 0..<6 {
                if app.buttons["quickAction"].isHittable { break }
                scrollToday(up: false, summary: true)
            }
            XCTAssertEqual(app.buttons["quickAction"].label, "Check out now")
        }
        selectTab("Settings")
        app.buttons["appearancePicker"].tap()
        app.buttons["Dark"].tap()
        showTodayTop()
        try await capture("05-dark")
        let checkout = app.buttons["quickAction"]
        XCTAssertEqual(checkout.label, "Check out now")
        XCTAssertTrue(checkout.isHittable)
        checkout.tap()
        let checkedOut = NSPredicate(format: "label CONTAINS %@", "Checked out")
        let status = app.staticTexts["workingStatus"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: checkedOut, object: status)], timeout: 10)
        try await capture("09-completed-day")
        let syncStatus = app.descendants(matching: .any).matching(identifier: "syncStatusTitle").firstMatch
        for _ in 0..<8 {
            if syncStatus.exists && syncStatus.isHittable { break }
            scrollToday(up: true)
        }
        XCTAssertTrue(syncStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(syncStatus.label, "1 day waiting to sync")
        try await capture("04-offline")
        selectTab("Statistics")
        XCTAssertTrue(app.staticTexts["statisticsBillable"].waitForExistence(timeout: 5))
        try await capture("06-statistics")
        app.buttons["Month"].tap()
        let forecast = app.staticTexts["monthForecastTotal"]
        let statisticsContent = app.collectionViews["statisticsContent"]
        for _ in 0..<6 {
            if forecast.isHittable { break }
            statisticsContent.swipeUp()
        }
        XCTAssertTrue(forecast.isHittable, app.debugDescription)
        try await capture("10-month-forecast")
        selectTab("Settings")
        XCTAssertTrue(app.buttons["appearancePicker"].waitForExistence(timeout: 5))
        try await capture("07-settings")
        // Empty-day scene uses the real editor, with no process relaunch or
        // test-only reset API. Remove the break explicitly before clearing times.
        showTodayTop()
        for _ in 0..<6 {
            if app.buttons["editToday"].isHittable { break }
            scrollToday(up: true)
        }
        app.buttons["editToday"].tap()
        let form = app.collectionViews["entryForm"]
        let removeBreak = app.buttons["removeBreak1"]
        for _ in 0..<8 {
            if removeBreak.exists && removeBreak.isHittable { break }
            form.swipeUp()
        }
        XCTAssertTrue(removeBreak.isHittable)
        removeBreak.tap()
        XCTAssertTrue(removeBreak.waitForNonExistence(timeout: 5))
        for _ in 0..<4 { form.swipeDown() }
        for title in ["Check-out entered", "Check-in entered"] {
            let toggle = app.switches[title]
            for _ in 0..<8 {
                if toggle.exists && toggle.isHittable { break }
                form.swipeUp()
            }
            XCTAssertTrue(toggle.isHittable)
            XCTAssertEqual(toggle.value as? String, "1")
            // SwiftUI can expose the entire row as the Switch. Tap its
            // trailing control instead of the noninteractive label centre.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            let disabled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "0"), object: toggle)
            await fulfillment(of: [disabled], timeout: 5)
        }
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["saveEntry"].waitForNonExistence(timeout: 5))
        showTodayTop()
        XCTAssertEqual(app.buttons["quickAction"].label, "Check in now")
        XCTAssertTrue(app.staticTexts["Today's billable time, 0h 0m"].waitForExistence(timeout: 5))
        try await capture("08-empty-day")
        // Dedicated simulator cleanup belongs to the capture task's finally.
    }
}
