import XCTest

final class TracyUITests: XCTestCase {
    private var testArguments: [String] {
        [
            "--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        _ = element.waitForExistence(timeout: 3)
        // Lists are collection views. A broad `.any` identifier lookup also resolves
        // labels throughout the SwiftUI tree, even when the compact layout has no
        // split columns. CI spindumps showed that query monopolizing the AX service.
        let summary = app.collectionViews.matching(NSPredicate(format: "identifier == %@", "todaySummary")).firstMatch
        let details = app.collectionViews.matching(NSPredicate(format: "identifier == %@", "todayDetails")).firstMatch
        let surfaces = summary.exists ? [summary, details] : [app]
        for surface in surfaces {
            for _ in 0..<8 {
                if element.exists && element.isHittable { return true }
                surface.swipeUp()
            }
            for _ in 0..<8 {
                if element.exists && element.isHittable { return true }
                surface.swipeDown()
            }
        }
        return element.exists && element.isHittable
    }

    @MainActor
    func testEmptyAndCompletedDayHierarchy() {
        let app = XCUIApplication()
        app.launchArguments = testArguments + ["--ui-empty-day"]
        app.launch()
        XCTAssertTrue(self.reveal(app.staticTexts["No entries yet"], in: app))
        XCTAssertTrue(self.reveal(app.buttons["quickAction"], in: app))
        XCTAssertEqual(app.buttons["quickAction"].label, "Check in now")
        XCTAssertFalse(app.buttons["undoCheckout"].exists)
        app.terminate()
        app.launchArguments = testArguments + ["--ui-completed-day"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["workingStatus"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["heroBreaks"].label.contains("0h 30m"))
        XCTAssertTrue(self.reveal(app.staticTexts["Goal exceeded by 1h 0m"], in: app))
        for _ in 0..<5 {
            if app.buttons["undoCheckout"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["undoCheckout"].isHittable)
        XCTAssertEqual(app.buttons["quickAction"].label, "Check in again")
    }

    @MainActor
    func testMonthForecastAppearsOnlyForMonth() {
        let app = XCUIApplication()
        app.launchArguments = testArguments
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Statistics"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["Statistics"].firstMatch.tap()
        app.buttons["Month"].tap()
        let forecast = app.descendants(matching: .any).matching(identifier: "monthForecastTotal").firstMatch
        XCTAssertTrue(self.reveal(forecast, in: app))
        XCTAssertTrue(app.staticTexts["Projected balance"].exists)
    }

    @MainActor
    func testTodayLargeTextLayout() {
        verifyTodayLayout(appearance: "dark", largeText: true)
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
    func testContrastAuditRejectsVisibleLowContrast() throws {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { issue in
            issue.compactDescription.contains("Visible contrast failure")
                && issue.compactDescription.contains("Deliberately low contrast")
        }
        try XCTExpectFailure("Visible low-contrast text must still fail the viewport audit", options: options) {
            try auditToday(appearance: "light", category: .contrast, name: "NegativeControl", negativeControl: true)
        }
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
        guard text.waitForExistence(timeout: 15) else {
            XCTFail("Missing clipping negative control. \(app.debugDescription)")
            return
        }
        // Resolve the settled accessibility snapshot directly, as the positive
        // layout checks do. A predicate expectation adds a five-second wall
        // deadline around a remote query that can itself take that long on CI.
        // Pending, missing, and fits values must all fail this negative control.
        let measurement = text.value as? String
        XCTAssertTrue(
            measurement?.hasPrefix("clipped:") == true,
            "Expected truncated text; measured \(measurement ?? "missing"). \(text.debugDescription)"
        )
    }

    @MainActor
    private func verifyTodayLayout(appearance: String, largeText: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = testArguments + ["--ui-layout-checks", "-appearance", appearance]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        defer { app.terminate() }
        for key in [
            "date", "billable", "headline", "breaks", "action", "section", "label.Check-in", "value.Check-in",
            "label.Check-out", "value.Check-out", "edit", "review",
        ] {
            // Buttons retain their existing identifiers and inherit their label value.
            let identifier = key == "action" ? "quickAction" : key == "edit" ? "editToday"
                : key == "billable" ? "heroBillable" : key == "breaks" ? "heroBreaks" : "layout.\(key)"
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
    private func auditToday(appearance: String, category: XCUIAccessibilityAuditType, name: String, negativeControl: Bool = false) throws {
        let app = XCUIApplication()
        // Launch directly in the audited appearance, without a live scheme transition.
        app.launchArguments = testArguments + ["-appearance", appearance]
        if negativeControl { app.launchArguments.append("--ui-contrast-negative-control") }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["heroBillable"].waitForExistence(timeout: 15))
        // Application screenshots resolve an accessibility snapshot. After an audit the
        // hosted iPad service can stop answering those queries. Screen capture does not
        // query the app hierarchy; collect evidence before handing control to the audit.
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Today-\(appearance)-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if category == .contrast {
            try auditVisibleContrast(app)
        } else {
            try app.performAccessibilityAudit(for: category) { issue in
                print("Accessibility audit: \(issue.detailedDescription)")
                return false
            }
        }
    }

    @MainActor
    private func auditVisibleContrast(_ app: XCUIApplication) throws {
        // Apple's contrast audit also samples text underneath floating system bars.
        // Defer only occluded findings; each must pass again fully onscreen. Visible
        // failures fail immediately. Never query the hierarchy inside the callback.
        var verified = Set<String>()
        var pending = Set<String>()
        var gestures: [(String, Bool)] = []
        func key(_ element: XCUIElement) -> String {
            // Repeated values elsewhere on the page must not validate one another.
            "\(element.elementType.rawValue)|\(element.identifier)|\(element.label)|\(Int(element.frame.minX.rounded()))|\(Int(element.frame.width.rounded()))"
        }
        func unobscured(_ element: XCUIElement, bars: [CGRect]) -> Bool {
            let frame = element.frame
            return !frame.isEmpty && app.frame.contains(frame)
                && !bars.contains { $0.intersects(frame) }
        }
        for viewport in 0..<12 {
            var findings: [XCUIAccessibilityAuditIssue] = []
            try app.performAccessibilityAudit(for: .contrast) { issue in
                findings.append(issue)
                return true // Process every finding below, outside the audit service callback.
            }
            let bounds = app.frame
            let topBars = app.navigationBars.allElementsBoundByIndex.filter { $0.exists }.map { element in
                var frame = element.frame
                // UIKit reports the split detail bar across the entire iPad window.
                // Constrain it to the content column it actually decorates.
                let columnID = element.identifier == "Day details" ? "todayDetails"
                    : element.identifier == "Today" ? "todaySummary" : ""
                if !columnID.isEmpty {
                    let column = app.descendants(matching: .any).matching(identifier: columnID).firstMatch
                    if column.exists {
                        frame.origin.x = column.frame.minX
                        frame.size.width = column.frame.width
                    }
                    if columnID == "todayDetails" {
                        let sidebar = app.descendants(matching: .any).matching(identifier: "todaySummary").firstMatch
                        if sidebar.exists && sidebar.frame.width < bounds.width * 0.8 {
                            // In portrait iPad the sidebar overlays the full-width
                            // detail navigation stack, including its reported bar.
                            let visibleMinX = max(frame.minX, sidebar.frame.maxX)
                            frame = CGRect(x: visibleMinX, y: frame.minY,
                                           width: max(0, frame.maxX - visibleMinX), height: frame.height)
                        }
                    }
                }
                return frame.width > frame.height
                    ? CGRect(x: frame.minX, y: bounds.minY, width: frame.width, height: frame.maxY - bounds.minY)
                    : frame
            }
            let bottomBars = app.tabBars.allElementsBoundByIndex.filter { $0.exists }.map { element in
                let frame = element.frame
                guard frame.width > frame.height else { return frame }
                // iPad places its horizontal tab bar at the top; Duo can use a
                // vertical bar. Only extend toward the nearest screen edge.
                return frame.midY < bounds.midY
                    ? CGRect(x: frame.minX, y: bounds.minY, width: frame.width, height: frame.maxY - bounds.minY)
                    : CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: bounds.maxY - frame.minY)
            }
            let bars = topBars + bottomBars
            print("Contrast viewport bounds: \(bounds); navigation: \(topBars); tabs: \(bottomBars)")
            var failing = Set<String>()
            for issue in findings {
                guard let element = issue.element, element.exists else {
                    XCTFail("Unresolved contrast finding: \(issue.detailedDescription)")
                    return
                }
                let identity = key(element)
                print("Contrast finding: \(identity); frame: \(element.frame)")
                failing.insert(identity)
                if unobscured(element, bars: bars) {
                    XCTFail("Visible contrast failure for \(identity): \(issue.detailedDescription)")
                    return
                }
                pending.insert(identity)
            }
            // The audit can identify a containing button instead of its text label.
            // Resolve and verify the same element type; a child label cannot clear it.
            let candidates = app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex
            for element in candidates where unobscured(element, bars: bars) {
                let identity = key(element)
                if !failing.contains(identity) { verified.insert(identity) }
            }
            pending.subtract(verified)
            if pending.isEmpty { return }
            let identity = pending.sorted()[0]
            guard let target = candidates.first(where: { key($0) == identity }) else {
                XCTFail("Cannot reveal deferred contrast finding: \(identity)")
                return
            }
            let details = app.descendants(matching: .any).matching(identifier: "todayDetails").firstMatch
            let summary = app.descendants(matching: .any).matching(identifier: "todaySummary").firstMatch
            let surfaceID = details.exists && details.frame.intersects(target.frame) ? "todayDetails"
                : summary.exists ? "todaySummary" : ""
            gestures.append((surfaceID, target.frame.midY > app.frame.midY))
            // A second audit in one automation session can time out in Apple's
            // service. Recreate the same deterministic fixture and replay scrolling.
            app.terminate()
            app.launch()
            XCTAssertTrue(app.staticTexts["heroBillable"].waitForExistence(timeout: 15))
            for (identifier, upward) in gestures {
                let surface = identifier.isEmpty ? app
                    : app.descendants(matching: .any).matching(identifier: identifier).firstMatch
                let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                if upward { start.press(forDuration: 0.05, thenDragTo: end) }
                else { end.press(forDuration: 0.05, thenDragTo: start) }
            }
            let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            evidence.name = "Contrast-revealed-viewport-\(viewport)"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTFail("Contrast findings never verified fully onscreen: \(pending.sorted())")
    }

    @MainActor
    func testOfflineEntryAndReviewNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = testArguments
        app.launchEnvironment["TRACY_UI_JOURNAL"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(self.reveal(app.buttons["editToday"], in: app))
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
        XCTAssertTrue(self.reveal(app.staticTexts["Offline project notes"], in: app))
        for _ in 0..<6 {
            if app.staticTexts["1 day waiting to sync"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["1 day waiting to sync"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(self.reveal(app.staticTexts["Offline project notes"], in: app))
        for _ in 0..<6 {
            if app.staticTexts["1 day waiting to sync"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["1 day waiting to sync"].exists)
        app.buttons["Recent Days"].firstMatch.tap()
        XCTAssertTrue(app.switches["Needs attention only"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testResumeAndUndoCheckout() {
        let app = XCUIApplication()
        app.launchArguments = testArguments
        app.launchEnvironment["TRACY_UI_JOURNAL"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["heroBillable"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["heroBreaks"].label.contains("breaks deducted"))
        app.buttons["quickAction"].tap()
        XCTAssertTrue(self.reveal(app.buttons["quickAction"], in: app))
        XCTAssertEqual(app.buttons["quickAction"].label, "Check in again")
        app.buttons["sessionActionOptions"].tap()
        XCTAssertTrue(app.buttons["saveSessionAction"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(self.reveal(app.buttons["undoCheckout"], in: app))
        app.buttons["undoCheckout"].tap()
        XCTAssertTrue(self.reveal(app.buttons["quickAction"], in: app))
        XCTAssertTrue(app.staticTexts["heroBillable"].exists)
    }

    @MainActor
    func testBreakRemovalPersistsAndSupportsSwipeAndZero() {
        let app = XCUIApplication()
        app.launchArguments = testArguments
        app.launchEnvironment["TRACY_UI_JOURNAL"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        func relaunchPersistedEntry() {
            // Finish the sheet transition before ending the process. Backgrounding
            // lets SpringBoard detach its accessibility session before termination.
            XCTAssertTrue(app.buttons["saveEntry"].waitForNonExistence(timeout: 10))
            let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            home.activate()
            XCTAssertTrue(home.wait(for: .runningForeground, timeout: 10))
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
            app.launch()
            XCTAssertTrue(app.staticTexts["heroBillable"].waitForExistence(timeout: 15))
        }
        XCTAssertTrue(app.staticTexts["heroBillable"].waitForExistence(timeout: 15))
        XCTAssertTrue(self.reveal(app.buttons["quickAction"], in: app))
        app.buttons["quickAction"].tap()
        XCTAssertTrue(self.reveal(app.buttons["editToday"], in: app))
        app.buttons["editToday"].tap()
        let form = app.collectionViews.matching(NSPredicate(format: "identifier == %@", "entryForm")).firstMatch
        func reveal(_ element: XCUIElement) {
            for _ in 0..<8 {
                if element.exists && element.isHittable { return }
                form.swipeUp()
            }
            XCTAssertTrue(element.isHittable)
        }
        let remove = app.buttons["removeBreak1"]
        reveal(remove)
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(self.reveal(app.staticTexts["heroBreaks"], in: app))
        XCTAssertEqual(app.staticTexts["heroBreaks"].label, "0h 0m breaks deducted")
        relaunchPersistedEntry()
        XCTAssertTrue(self.reveal(app.buttons["editToday"], in: app))
        app.buttons["editToday"].tap()
        let add = app.buttons["Add break"]
        reveal(add)
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        add.tap()
        reveal(add)
        add.tap()
        reveal(app.buttons["removeBreak2"])
        app.buttons["removeBreak2"].swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["removeBreak2"].waitForNonExistence(timeout: 5))
        let duration = app.steppers["breakDuration1"]
        reveal(duration)
        XCTAssertEqual(duration.value as? String, "30 minutes")
        for _ in 0..<30 { duration.buttons["breakDuration1-Decrement"].tap() }
        XCTAssertTrue(app.buttons["Remove break"].waitForExistence(timeout: 3))
        app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.last!.tap()
        XCTAssertEqual(duration.value as? String, "1 minutes")
        duration.buttons["breakDuration1-Decrement"].tap()
        app.buttons["Remove break"].tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(self.reveal(app.staticTexts["heroBreaks"], in: app))
        XCTAssertEqual(app.staticTexts["heroBreaks"].label, "0h 0m breaks deducted")
        relaunchPersistedEntry()
        XCTAssertTrue(self.reveal(app.buttons["editToday"], in: app))
        app.buttons["editToday"].tap()
        reveal(add)
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testProjectBookingPersistsAndProjectArchiveRestores() {
        let app = XCUIApplication()
        app.launchArguments = testArguments + ["--ui-projects"]
        app.launchEnvironment["TRACY_UI_JOURNAL"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(self.reveal(app.buttons["editToday"], in: app))
        app.buttons["editToday"].tap()
        let form = app.descendants(matching: .any).matching(identifier: "entryForm").firstMatch
        let add = app.buttons["addProjectBooking"]
        for _ in 0..<8 {
            if add.exists && add.isHittable { break }
            form.swipeUp()
        }
        add.tap()
        XCTAssertTrue(app.textFields["Booking minutes"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Booking minutes"].value as? String, "120")
        app.buttons["saveEntry"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(self.reveal(app.buttons["editToday"], in: app))
        app.buttons["editToday"].tap()
        for _ in 0..<8 {
            if app.textFields["Booking minutes"].exists && app.textFields["Booking minutes"].isHittable { break }
            form.swipeUp()
        }
        XCTAssertEqual(app.textFields["Booking minutes"].value as? String, "120")
        app.buttons["saveEntry"].tap()
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Projects"].tap()
        let archive = app.buttons["projectArchive1"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        archive.tap()
        XCTAssertEqual(archive.label, "Unarchive")
        archive.tap()
        XCTAssertEqual(archive.label, "Archive")
        app.buttons["projectDefault1"].tap()
        XCTAssertTrue(app.staticTexts["Default project"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testVacationFromTodayAndEntryEditor() {
        let app = XCUIApplication()
        app.launchArguments = testArguments
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["manageVacation"].waitForExistence(timeout: 15))
        app.buttons["manageVacation"].tap()
        XCTAssertTrue(app.buttons["saveVacation"].waitForExistence(timeout: 10))
        app.buttons["saveVacation"].tap()
        XCTAssertTrue(self.reveal(app.buttons["editToday"], in: app))
        app.buttons["editToday"].tap()
        XCTAssertTrue(app.buttons["entryVacation"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["entryVacation"].label, "Manage vacation")
        XCTAssertFalse(app.staticTexts["Saved on this device first"].exists)
        app.buttons["entryVacation"].tap()
        XCTAssertTrue(app.buttons["saveVacation"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testNotificationOpensCheckoutCorrection() {
        let app = XCUIApplication()
        app.launchArguments = testArguments + ["--ui-notification-checkout"]
        app.launchEnvironment["TRACY_UI_JOURNAL"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["applyActualCheckout"].waitForExistence(timeout: 15))
        app.buttons["applyActualCheckout"].tap()
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(self.reveal(app.buttons["undoCheckout"], in: app))
    }

    @MainActor
    func testProjectSessionCheckInOptionsAndEditor() {
        let app = XCUIApplication()
        app.launchArguments = testArguments + ["--ui-projects", "--ui-sessions"]
        app.launchEnvironment["TRACY_UI_JOURNAL"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(self.reveal(app.buttons["sessionActionOptions"], in: app))
        app.buttons["sessionActionOptions"].tap()
        XCTAssertTrue(app.buttons["saveSessionAction"].waitForExistence(timeout: 10))
        app.buttons["sessionProject"].tap()
        app.buttons["Project Y"].tap()
        app.buttons["saveSessionAction"].tap()
        XCTAssertTrue(self.reveal(app.buttons["quickAction"], in: app))
        XCTAssertEqual(app.buttons["quickAction"].label, "Check out now")
        XCTAssertTrue(self.reveal(app.staticTexts["Project Y"].firstMatch, in: app))
        XCTAssertTrue(self.reveal(app.buttons["editToday"], in: app))
        app.buttons["editToday"].tap()
        XCTAssertTrue(app.staticTexts["Session 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["saveEntry"].exists)
        let remove = app.buttons["Remove session"]
        for _ in 0..<6 {
            if remove.exists && remove.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertTrue(app.staticTexts["Session 1"].waitForNonExistence(timeout: 5))
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(self.reveal(app.buttons["quickAction"], in: app))
        XCTAssertEqual(app.buttons["quickAction"].label, "Check in now")
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
