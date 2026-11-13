import XCTest

final class CompanyResearchTests: XCTestCase {
    func testAppleResearchShowsLiveFilingEvidence() throws {
        let origin = ProcessInfo.processInfo.environment["RESEARCH_UI_TEST_ORIGIN"]
        try XCTSkipIf(origin == nil, "Set RESEARCH_UI_TEST_ORIGIN to the live research test server.")
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = [
            "-UITestFreshInstall", "-hasCompletedOnboarding", "YES",
            "-CompanyResearchURLOverride", try XCTUnwrap(origin),
        ]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 30))
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "stocktracker://asset/AAPL")))

        let research = app.buttons["detail.companyResearch"]
        XCTAssertTrue(research.waitForExistence(timeout: 20))
        for _ in 0..<5 where !research.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(research.isHittable)
        research.tap()

        let sheet = app.navigationBars["AAPL Research"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let apple = app.staticTexts.matching(NSPredicate(format: "label =[c] %@", "Apple Inc.")).firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: 50), "The live SEC issuer profile should render")
        XCTAssertTrue(app.staticTexts["Financial evidence"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["companyResearch.filingDate"].firstMatch.exists, "The report should show filing dates")
        XCTAssertTrue(app.descendants(matching: .any)["companyResearch.filingSource"].firstMatch.exists, "A financial fact should link to a source")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Apple research with live filing evidence"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        sheet.buttons["Done"].tap()
        XCTAssertFalse(sheet.exists)
        XCTAssertTrue(research.exists, "Done returns to the same stock")
    }
}
