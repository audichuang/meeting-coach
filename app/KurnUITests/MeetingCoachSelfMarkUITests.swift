//
//  MeetingCoachSelfMarkUITests.swift
//  KurnUITests
//
//  Exercises tapping a live transcript segment in the iPad meeting coach panel
//  to mark "這是我" (updating all segments of that anonymous speaker label to "我")
//  and clearing it via "不是我", using the zero-network DEBUG preview.
//

import XCTest

@MainActor
final class MeetingCoachSelfMarkUITests: XCTestCase {

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testTapSegmentMarksAllTurnsOfSpeakerAndClears() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Self-mark iPad layout test runs on iPad simulators")
        }

        let env = ProcessInfo.processInfo.environment
        let shotDir = env["MC_SHOT_DIR"]

        let app = XCUIApplication()
        app.launchArguments += [
            "UI-Testing-Screenshots",
            "UI-Testing-DisableAnimations",
            "-AppleLanguages", "(zh-Hant)",
            "-AppleLocale", "zh_TW"
        ]
        app.launchEnvironment["KURN_DEBUG_COACH_PREVIEW"] = "1"
        if let captureFile = env["MC_CAPTURE_FILE"], !captureFile.isEmpty {
            app.launchEnvironment["KURN_DEBUG_CAPTURE_FILE"] = captureFile
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        // Skip the first-launch Sign in with Apple screen.
        app.launchArguments += ["-settings.coachSignInPromptShown", "YES"]
        app.launch()

        let recordButton = app.buttons["meetings.record"].firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 15), "Record button should be reachable")
        recordButton.tap()

        let firstSegment = app.buttons["coach.segment.4"].firstMatch
        XCTAssertTrue(firstSegment.waitForExistence(timeout: 15), "First live transcript segment should appear")
        let thirdSegment = app.buttons["coach.segment.29"].firstMatch
        XCTAssertTrue(thirdSegment.waitForExistence(timeout: 10), "Third live transcript segment should appear")

        try saveScreenshot(named: "self-mark-before", to: shotDir)

        // Tap segment A (t=4s) -> menu shows "這是我".
        firstSegment.tap()
        let markMe = app.buttons["這是我"].firstMatch
        XCTAssertTrue(markMe.waitForExistence(timeout: 5), "Menu should offer 這是我")
        try saveScreenshot(named: "self-mark-menu", to: shotDir)
        markMe.tap()

        // Both segments with label A now show "我" and tapping the third segment offers "不是我".
        let selfBadge = app.staticTexts["我"].firstMatch
        XCTAssertTrue(selfBadge.waitForExistence(timeout: 5), "Marked speaker should display 我")
        try saveScreenshot(named: "self-mark-marked", to: shotDir)

        thirdSegment.tap()
        let notMe = app.buttons["不是我"].firstMatch
        XCTAssertTrue(notMe.waitForExistence(timeout: 5), "Menu on already-marked speaker should offer 不是我")
        try saveScreenshot(named: "self-mark-clear-menu", to: shotDir)
        notMe.tap()

        // After clearing, tapping first segment offers "這是我" again.
        firstSegment.tap()
        XCTAssertTrue(app.buttons["這是我"].firstMatch.waitForExistence(timeout: 5), "After clearing, menu should offer 這是我 again")
    }

    private func saveScreenshot(named name: String, to directory: String?) throws {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory, !directory.isEmpty else { return }
        let dirURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try shot.pngRepresentation.write(to: dirURL.appendingPathComponent("\(name).png"))
    }
}
