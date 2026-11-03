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
            let column = app.descendants(matching: .any).matching(identifier: summary ? "todaySummary" : "todayDetails").firstMatch
            let surface = column.exists ? column : app
            if up { surface.swipeUp() } else { surface.swipeDown() }
        }
        func stopForRelaunch() async throws {
            // Detach foreground accessibility before ending a scene's process.
            let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            home.activate()
            XCTAssertTrue(home.wait(for: .runningForeground, timeout: 10))
            let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-port", withExtension: "txt"))
            let port = try String(contentsOf: config, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/terminate"))
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "POST"
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            guard status == 204 else {
                XCTFail("Simulator termination failed: HTTP \(status ?? 0): \(String(decoding: data, as: UTF8.self))")
                throw URLError(.badServerResponse)
            }
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
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
        selectTab("Recent Days")
        XCTAssertTrue(app.switches["Needs attention only"].waitForExistence(timeout: 5))
        try await capture("03-recent-days")
        // Returning from Recent Days preserves Today’s scroll offset. XCTest may
        // report a button hidden behind the translucent navigation bar as hittable.
        // Start this independent scene at a known scroll position and verify the
        // checkout transition before searching for its pending-sync status.
        try await stopForRelaunch()
        launch("light")
        let checkout = app.buttons["quickAction"]
        XCTAssertEqual(checkout.label, "Check out now")
        XCTAssertTrue(checkout.isHittable)
        checkout.tap()
        let checkedOut = NSPredicate(format: "label CONTAINS %@", "Checked out")
        let status = app.staticTexts["workingStatus"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: checkedOut, object: status)], timeout: 10)
        let syncStatus = app.descendants(matching: .any).matching(identifier: "syncStatusTitle").firstMatch
        for _ in 0..<8 {
            if syncStatus.exists && syncStatus.isHittable { break }
            scrollToday(up: true)
        }
        XCTAssertTrue(syncStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(syncStatus.label, "1 day waiting to sync")
        try await capture("04-offline")
        try await stopForRelaunch()
        launch("dark")
        try await capture("05-dark")
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
        try await stopForRelaunch()
        launch("dark", state: "--ui-empty-day")
        try await capture("08-empty-day")
        try await stopForRelaunch()
        launch("dark", state: "--ui-completed-day")
        try await capture("09-completed-day")
        // The capture task deletes its dedicated simulator in finally. No final
        // terminate RPC: all scenes are already captured and it can fail on Duo.
        if innerDisplay {
            try await stopForRelaunch()
            launch("light")
            for _ in 0..<6 {
                if app.buttons["editToday"].isHittable { break }
                scrollToday(up: true)
            }
            app.buttons["editToday"].tap()
            let notes = app.descendants(matching: .any).matching(identifier: "entryNotes").firstMatch
            let form = app.descendants(matching: .any).matching(identifier: "entryForm").firstMatch
            for _ in 0..<8 {
                if notes.exists && notes.isHittable { break }
                form.swipeUp()
            }
            XCTAssertTrue(notes.isHittable)
            notes.tap()
            notes.typeText("Duo transition draft")
            let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "capture-port", withExtension: "txt"))
            let port = try String(contentsOf: config, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            for (index, angle) in [0, 180, 90, 180, 0].enumerated() {
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
                XCTAssertTrue((notes.value as? String)?.contains("Duo transition draft") == true)
                let imageURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/pose-image/\(angle)"))
                let (imageData, imageResponse) = try await URLSession.shared.data(from: imageURL)
                XCTAssertEqual((imageResponse as? HTTPURLResponse)?.statusCode, 200)
                let evidence = XCTAttachment(data: imageData, uniformTypeIdentifier: "public.png")
                evidence.name = "Duo-editor-pose-\(index)-\(angle)"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
            app.buttons["saveEntry"].tap()
            for _ in 0..<6 {
                if app.buttons["quickAction"].isHittable { break }
                scrollToday(up: false, summary: true)
            }
            XCTAssertEqual(app.buttons["quickAction"].label, "Check out now")
        }
    }
}
