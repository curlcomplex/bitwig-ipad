import XCTest

final class NativeHostUITests: XCTestCase {
    private func compatibilityHost() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertEqual(app.frame.size, CGSize(width: 1133, height: 744),
                       "Open original 6.1.7 Tablet Demo in landscape before running this workflow")
        return app
    }

    private func compatibilityTap(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: x - app.frame.minX, dy: y - app.frame.minY))
    }

    private func compatibilityScreen(_ title: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCompatibilityFilePickerCancellation() {
        let app = compatibilityHost()
        let location = app.staticTexts["On My iPad"].firstMatch
        if location.exists {
            compatibilityTap(app, 118, 74).tap()
            XCTAssertTrue(location.waitForNonExistence(timeout: 8))
        }
        compatibilityTap(app, 24, 44).tap()
        compatibilityScreen("Original File menu")
        compatibilityTap(app, 55, 100).tap()
        XCTAssertTrue(location.waitForExistence(timeout: 12))
        compatibilityScreen("Native file picker")
        compatibilityTap(app, 118, 74).tap()
        XCTAssertTrue(location.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        compatibilityScreen("Original project after cancelling file picker")
    }

    func testFullScreenRotation() {
        let app=XCUIApplication(bundleIdentifier:TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation=orientation
            sleep(2)
            XCTAssertTrue(app.wait(for:.runningForeground,timeout:5))
            XCTAssertFalse(app.statusBars.firstMatch.exists)
            let capture=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
            capture.name=orientation == .portrait ? "Requested portrait" : "Requested landscape"
            capture.lifetime = .keepAlways;add(capture)
        }
    }

    func testDragNativeDevice() {
        let app=XCUIApplication(bundleIdentifier:TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        let start=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:195-app.frame.minX,dy:310-app.frame.minY))
        let end=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:600-app.frame.minX,dy:300-app.frame.minY))
        start.press(forDuration:0.2,thenDragTo:end)
        let capture=XCTAttachment(screenshot:XCUIScreen.main.screenshot());capture.name="Device drag completed";capture.lifetime = .keepAlways;add(capture)
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:5))
    }
    func testCancelNativeDeviceDrag() {
        let app=XCUIApplication(bundleIdentifier:TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        let start=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:195-app.frame.minX,dy:310-app.frame.minY))
        let end=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:50-app.frame.minX,dy:600-app.frame.minY))
        start.press(forDuration:0.2,thenDragTo:end)
        let capture=XCTAttachment(screenshot:XCUIScreen.main.screenshot());capture.name="Device drag released outside window";capture.lifetime = .keepAlways;add(capture)
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:5))
    }
    func testDragWelcomeWindow() {
        let app=XCUIApplication(bundleIdentifier:TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        let start=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:500-app.frame.minX,dy:104-app.frame.minY))
        let end=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:520-app.frame.minX,dy:124-app.frame.minY))
        start.press(forDuration:0.1,thenDragTo:end)
        let capture=XCTAttachment(screenshot:XCUIScreen.main.screenshot());capture.name="Window dragged";capture.lifetime = .keepAlways;add(capture)
        XCTAssertTrue(app.exists)
    }
    func testClearNativeText() {
        let app=XCUIApplication(bundleIdentifier:TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:700-app.frame.minX,dy:255-app.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout:5))
        let delete=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:1070-app.frame.minX,dy:420-app.frame.minY))
        for _ in 0..<10 { delete.tap() }
        let capture=XCTAttachment(screenshot:XCUIScreen.main.screenshot());capture.name="Text deleted";capture.lifetime = .keepAlways;add(capture)
        let dismiss=app.buttons["Done"].firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout:5));dismiss.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout:5))
        XCTAssertTrue(app.exists)
    }

    func testNativeFileImport() {
        let app=XCUIApplication(bundleIdentifier:TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        let location=app.staticTexts["On My iPad"].firstMatch
        XCTAssertTrue(location.waitForExistence(timeout:10));location.tap()
        let folder=app.staticTexts["Bitwig Native Host"].firstMatch
        if folder.waitForExistence(timeout:5) {
            folder.tap()
            let file=app.staticTexts["Native Open Test.bwproject"].firstMatch
            if file.waitForExistence(timeout:5) {
                app.cells.containing(.staticText,identifier:"Native Open Test.bwproject").firstMatch.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.3)).tap()
            }
            else { print(app.debugDescription);XCTFail("Test project file not visible") }
        } else { print(app.debugDescription);XCTFail("Native host Files folder not visible") }
        let settled=expectation(description:"Open project")
        DispatchQueue.main.asyncAfter(deadline:.now()+3){settled.fulfill()}
        wait(for:[settled],timeout:6)
        XCTAssertFalse(app.staticTexts["On My iPad"].firstMatch.exists,"Picker did not finish the import")
        let capture=XCTAttachment(screenshot:XCUIScreen.main.screenshot());capture.name="File import";capture.lifetime = .keepAlways;add(capture)
        XCTAssertTrue(app.exists)
    }

    func testNativeTextInput() {
        let app = XCUIApplication(bundleIdentifier: TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let frame=app.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: 500-frame.minX, dy: 255-frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        if app.keyboards.firstMatch.exists { app.typeText("ipad input") }
        let capture=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        capture.name="Native text input";capture.lifetime = .keepAlways;add(capture)
        XCTAssertTrue(app.exists)
    }

    func testChooseTabletProfile() {
        let app = XCUIApplication(bundleIdentifier: TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let frame = app.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: 610 - frame.minX, dy: 306 - frame.minY)).tap()
        let settled = expectation(description: "Apply display profile")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "After selecting Tablet profile"
        capture.lifetime = .keepAlways
        add(capture)
        XCTAssertTrue(app.exists)
    }

    func testResumeNativePolySynth() {
        let app = XCUIApplication(bundleIdentifier: TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let background = expectation(description: "Exercise actual background lifecycle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { background.fulfill() }
        wait(for: [background], timeout: 15)
        XCTAssertEqual(app.state, .runningBackground, "Host stopped while backgrounded")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        // Foreground state precedes completion of SpringBoard's return animation.
        // A touch during that transform lands at different content coordinates.
        let settled = expectation(description: "Allow return animation to finish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        let frame = app.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: 613 - frame.minX, dy: 550 - frame.minY))
            .press(forDuration: 1.5)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Poly Synth after Home and return"
        capture.lifetime = .keepAlways
        add(capture)
        XCTAssertTrue(app.exists, "Native host terminated after resuming")
    }

    func testPlayNativePolySynth() {
        let app = XCUIApplication(bundleIdentifier: TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        // Tablet profile C3 note pad, observed in assessment-synth-loaded.png.
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: 613 - app.frame.minX, dy: 550 - app.frame.minY))
            .press(forDuration: 1.5)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Physical iPad Poly Synth note"
        capture.lifetime = .keepAlways
        add(capture)
        XCTAssertTrue(app.exists, "Native host terminated during the piano-key touch")
    }
    func testCaptureNativeHost() {
        let app = XCUIApplication(bundleIdentifier: TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Native Bitwig screen"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testContinueDemoMode() {
        let app = XCUIApplication(bundleIdentifier: TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        // Continue button observed in native-host-demo-tap.png.
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: 358 - app.frame.minX, dy: 653 - app.frame.minY)).tap()
        let settled = expectation(description: "Allow Demo Mode startup")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { settled.fulfill() }
        wait(for: [settled], timeout: 15)
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "After Continue in Demo Mode"
        after.lifetime = .keepAlways
        add(after)
        XCTAssertTrue(app.exists, "Native host terminated while entering Demo Mode")
    }

    func testEnterDemoMode() {
        let app = XCUIApplication(bundleIdentifier: TestBuildConfiguration.hostBundleIdentifier)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "Before Demo Mode"
        before.lifetime = .keepAlways
        add(before)
        // The original Skia controls are not accessibility elements yet.
        // Position observed in native-host-current.png, 1488 x 2266 pixels.
        print("Native app accessibility frame: \(app.frame)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: 440 - app.frame.minX, dy: 814 - app.frame.minY)).tap()
        let settled = expectation(description: "Allow the real frontend to process touch input")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { settled.fulfill() }
        wait(for: [settled], timeout: 10)
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "After Demo Mode tap"
        after.lifetime = .keepAlways
        add(after)
        XCTAssertTrue(app.exists, "Native host terminated after the Demo Mode tap")
    }
}
