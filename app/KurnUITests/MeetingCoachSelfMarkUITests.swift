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

    func testFollowUpDownloadHintAndLiveSortformer() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MC_LIVE_SORTFORMER_TEST"] == "1" else {
            throw XCTSkip("Set MC_LIVE_SORTFORMER_TEST=1 to exercise live Hugging Face Sortformer download and diarization")
        }
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Self-mark iPad layout test runs on iPad simulators")
        }
        guard let captureFile = env["MC_CAPTURE_FILE"], !captureFile.isEmpty else {
            XCTFail("MC_CAPTURE_FILE must point to a synthetic multi-speaker WAV")
            return
        }
        let shotDir = env["MC_SHOT_DIR"]

        try verifyUninstalledHint(captureFile: captureFile, shotDir: shotDir)
        try downloadSortformerInSettings(shotDir: shotDir)
        try verifyLiveSortformerDiarization(captureFile: captureFile, shotDir: shotDir)
    }

    private func verifyUninstalledHint(captureFile: String, shotDir: String?) throws {
        let app = makeLocalizedApp()
        app.launchEnvironment["KURN_DEBUG_COACH_PREVIEW"] = "1"
        app.launchEnvironment["KURN_DEBUG_COACH_PREVIEW_UNINSTALLED"] = "1"
        app.launchEnvironment["KURN_DEBUG_CAPTURE_FILE"] = captureFile
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()

        let recordButton = app.buttons["meetings.record"].firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 15), "Record button should be reachable")
        recordButton.tap()

        let hintText = app.staticTexts["coach.speaker.hint"].firstMatch
        XCTAssertTrue(hintText.waitForExistence(timeout: 15), "Hint should appear when model is not installed")
        XCTAssertEqual(hintText.label, "到設定下載講者標記模型，即可標記「這是我」")
        XCTAssertFalse(app.buttons["coach.segment.4"].exists, "Unlabeled segment must not offer self-mark menu")
        try saveScreenshot(named: "followup-uninstalled-hint", to: shotDir)
        app.terminate()
    }

    private func downloadSortformerInSettings(shotDir: String?) throws {
        let app = makeLocalizedApp()
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        let settingsButton = app.buttons["nav.settings"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15), "Settings button should exist")
        settingsButton.tap()

        XCTAssertTrue(app.buttons["settings.link.providers"].waitForExistence(timeout: 10), "Settings hub should appear")
        let recordingLink = app.buttons["settings.link.recording"].firstMatch
        for _ in 0..<4 where !recordingLink.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(recordingLink.waitForExistence(timeout: 10), "Recording settings link should exist")
        for _ in 0..<2 {
            recordingLink.tap()
            if app.navigationBars["錄音"].waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(app.navigationBars["錄音"].waitForExistence(timeout: 5), "Recording settings screen should push")

        let statusText = app.staticTexts["settings.coach.speaker_model.status"].firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !statusText.exists || !statusText.isHittable {
            if list.exists {
                list.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(statusText.waitForExistence(timeout: 10), "Speaker model status row should be visible")

        let deleteButton = app.buttons["settings.coach.speaker_model.delete"].firstMatch
        if deleteButton.exists {
            deleteButton.tap()
            let confirmDelete = app.buttons["刪除模型"].firstMatch
            XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5), "Delete confirmation should appear")
            confirmDelete.tap()
        }

        let downloadButton = app.buttons["settings.coach.speaker_model.download"].firstMatch
        XCTAssertTrue(downloadButton.waitForExistence(timeout: 10), "Download button should appear when not installed")
        XCTAssertEqual(statusText.label, "未下載")
        try saveScreenshot(named: "followup-settings-before", to: shotDir)

        downloadButton.tap()
        let allowButton = app.buttons["允許並下載"].firstMatch
        XCTAssertTrue(allowButton.waitForExistence(timeout: 10), "Consent dialog should appear")
        allowButton.tap()

        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 240),
            "Delete button should appear once Sortformer finishes downloading and compiling"
        )
        XCTAssertNotEqual(statusText.label, "未下載", "Status should show real on-disk size after download")
        XCTAssertFalse(statusText.label.isEmpty, "Status should display formatted size")
        print("FOLLOWUP_SETTINGS_STATUS=\(statusText.label)")
        try saveScreenshot(named: "followup-settings-installed", to: shotDir)
        app.terminate()
    }

    private func verifyLiveSortformerDiarization(captureFile: String, shotDir: String?) throws {
        let app = makeLocalizedApp()
        app.launchEnvironment["KURN_DEBUG_COACH_PREVIEW"] = "1"
        app.launchEnvironment["KURN_DEBUG_COACH_PREVIEW_LIVE_DIARIZER"] = "1"
        app.launchEnvironment["KURN_DEBUG_CAPTURE_FILE"] = captureFile
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()

        let recordButton = app.buttons["meetings.record"].firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 15), "Record button should exist")
        recordButton.tap()

        sleep(2)
        XCTAssertFalse(app.staticTexts["coach.speaker.hint"].exists, "Hint must be hidden when Sortformer is installed")

        for start in [0, 6, 12, 18] {
            let seg = app.descendants(matching: .any)["coach.segment.\(start)"].firstMatch
            XCTAssertTrue(seg.waitForExistence(timeout: 15), "Turn at \(start)s should appear")
        }
        sleep(3)

        XCTAssertTrue(app.staticTexts["A"].firstMatch.waitForExistence(timeout: 10), "Real Sortformer should assign label A")
        XCTAssertTrue(app.staticTexts["B"].firstMatch.waitForExistence(timeout: 10), "Real Sortformer should assign label B")

        for start in [0, 6, 12, 18] {
            let elem = app.buttons["coach.segment.\(start)"].firstMatch
            print("FOLLOWUP_SEG_\(start)_EXISTS=\(elem.exists) LABEL=\(elem.label)")
        }
        try saveScreenshot(named: "followup-live-sortformer-ab", to: shotDir)

        let firstLabeled = app.buttons["coach.segment.0"].firstMatch
        XCTAssertTrue(firstLabeled.waitForExistence(timeout: 5), "First segment should be tappable with a speaker label")
        firstLabeled.tap()
        let markMe = app.buttons["這是我"].firstMatch
        XCTAssertTrue(markMe.waitForExistence(timeout: 5), "Tapping Sortformer-labeled segment should offer 這是我")
        markMe.tap()
        XCTAssertTrue(app.staticTexts["我"].waitForExistence(timeout: 5), "Marked Sortformer speaker should show 我")
        try saveScreenshot(named: "followup-live-sortformer-marked", to: shotDir)
        app.terminate()
    }

    private func makeLocalizedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "UI-Testing-Screenshots",
            "UI-Testing-DisableAnimations",
            "-AppleLanguages", "(zh-Hant)",
            "-AppleLocale", "zh_TW"
        ]
        return app
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
