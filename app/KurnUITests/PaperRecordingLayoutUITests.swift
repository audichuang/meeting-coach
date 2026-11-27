//
//  PaperRecordingLayoutUITests.swift
//  KurnUITests
//
//  Verifies the iPad mini "paper" recording screen in both portrait and
//  landscape:
//  - The paper canvas fills most of the screen in both orientations.
//  - In portrait, the coach collapses to a single-line bar (never ~30% of
//    writing area) and expands on tap.
//  - In landscape, the coach sits in a column beside the paper without
//    overlapping it.
//  - Drawing strokes with the simulator pointer enables undo, survives
//    rotation, and renders read-only in meeting detail after stopping.
//
//  Uses the DEBUG-only local coach preview (`KURN_DEBUG_COACH_PREVIEW=1`) and
//  optional `MC_CAPTURE_FILE` / `MC_SHOT_DIR` test runner env vars; never
//  makes network or paid API calls.
//

import XCTest

@MainActor
final class PaperRecordingLayoutUITests: XCTestCase {

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testPaperDominatesScreenInPortraitAndLandscapeOnIPadMini() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Paper iPad layout test runs on iPad simulators")
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

        XCUIDevice.shared.orientation = .portrait
        app.launch()

        // Open the recording screen from the primary Record button.
        let recordButton = app.buttons["meetings.record"].firstMatch
        XCTAssertTrue(recordButton.waitForExistence(timeout: 15), "Record button should be reachable")
        recordButton.tap()

        // Wait for the paper canvas (PKCanvasView is a UIScrollView) and the collapsed portrait coach bar.
        let canvas = app.scrollViews["paper.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "Paper canvas should appear")

        let collapsedBar = app.buttons["coach.portrait.bar"].firstMatch
        XCTAssertTrue(collapsedBar.waitForExistence(timeout: 15), "Portrait coach should collapse to a single-line bar")

        // Wait for the local preview suggestion card headline to appear in the collapsed bar.
        let cardPredicate = NSPredicate(format: "label CONTAINS %@", "下週交付範圍")
        let cardExpectation = XCTNSPredicateExpectation(predicate: cardPredicate, object: collapsedBar)
        XCTAssertEqual(XCTWaiter.wait(for: [cardExpectation], timeout: 15), .completed, "Preview suggestion card should appear in collapsed portrait bar")

        // Portrait layout assertions: paper dominates, coach collapses to a single line.
        let windowFrame = app.windows.firstMatch.frame
        let portraitCanvasFrame = canvas.frame
        let portraitAreaRatio = (portraitCanvasFrame.width * portraitCanvasFrame.height)
            / max(1, windowFrame.width * windowFrame.height)
        XCTAssertGreaterThan(portraitAreaRatio, 0.75, "Paper should occupy >75% of screen area in portrait (got \(portraitAreaRatio))")

        XCTAssertLessThanOrEqual(collapsedBar.frame.height, 64, "Collapsed coach bar must stay single-line (height \(collapsedBar.frame.height))")
        XCTAssertLessThan(collapsedBar.frame.height / max(1, windowFrame.height), 0.08, "Collapsed bar must take <8% of height")

        // Draw a few strokes on the paper canvas using simulator pointer drags.
        drawStroke(on: canvas, from: CGVector(dx: 0.16, dy: 0.28), to: CGVector(dx: 0.72, dy: 0.30))
        drawStroke(on: canvas, from: CGVector(dx: 0.18, dy: 0.35), to: CGVector(dx: 0.60, dy: 0.37))

        // Switch to blue ink and draw a third stroke.
        let blueInk = app.buttons["paper.color.blue"].firstMatch
        if blueInk.exists { blueInk.tap() }
        drawStroke(on: canvas, from: CGVector(dx: 0.20, dy: 0.43), to: CGVector(dx: 0.76, dy: 0.45))

        // Switch to highlighter and mark an accent stroke.
        let highlighter = app.buttons["paper.tool.highlighter"].firstMatch
        if highlighter.exists { highlighter.tap() }
        drawStroke(on: canvas, from: CGVector(dx: 0.16, dy: 0.51), to: CGVector(dx: 0.56, dy: 0.51))

        // Return to pen.
        let pen = app.buttons["paper.tool.pen"].firstMatch
        if pen.exists { pen.tap() }

        let undoButton = app.buttons["paper.tool.undo"].firstMatch
        XCTAssertTrue(undoButton.exists && undoButton.isEnabled, "Undo should be enabled after drawing strokes")

        // Give debounced save a moment, then capture portrait screenshot (collapsed).
        Thread.sleep(forTimeInterval: 1.0)
        try saveScreenshot(named: "portrait-paper-collapsed", to: shotDir)

        // Expand portrait coach bar, verify drawer + card appear, capture, then collapse.
        collapsedBar.tap()
        let drawer = app.otherElements["coach.portrait.drawer"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "Tapping collapsed bar should expand coach drawer")
        let cardText = app.staticTexts["coach.card.text"].firstMatch
        XCTAssertTrue(cardText.waitForExistence(timeout: 5), "Expanded drawer should show suggestion card")
        try saveScreenshot(named: "portrait-paper-expanded", to: shotDir)
        let collapseButton = app.buttons["coach.portrait.collapse"].firstMatch
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 5))
        collapseButton.tap()
        XCTAssertTrue(collapsedBar.waitForExistence(timeout: 5), "Coach should collapse back to a single line")

        // Rotate to landscape and verify side-by-side layout.
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.0)

        let landscapeWindow = app.windows.firstMatch.frame
        let landscapeCanvasFrame = canvas.frame
        let coachColumn = app.otherElements["coach.landscape.column"].firstMatch
        XCTAssertTrue(coachColumn.waitForExistence(timeout: 10), "Coach column should sit beside paper in landscape")
        XCTAssertTrue(cardText.waitForExistence(timeout: 5), "Suggestion card should be visible in landscape column")

        let landscapeAreaRatio = (landscapeCanvasFrame.width * landscapeCanvasFrame.height)
            / max(1, landscapeWindow.width * landscapeWindow.height)
        XCTAssertGreaterThan(landscapeAreaRatio, 0.55, "Paper should occupy >55% of screen area in landscape (got \(landscapeAreaRatio))")
        XCTAssertLessThanOrEqual(
            landscapeCanvasFrame.maxX,
            coachColumn.frame.minX + 2,
            "Landscape coach column must sit beside the paper, not overlap it"
        )

        // Draw one more stroke in landscape to verify rotated drawing works.
        drawStroke(on: canvas, from: CGVector(dx: 0.18, dy: 0.60), to: CGVector(dx: 0.72, dy: 0.63))
        Thread.sleep(forTimeInterval: 1.0)
        try saveScreenshot(named: "landscape-paper-coach", to: shotDir)

        // Stop recording (if capture file was running >0.5s, recording + notes persist).
        let stopButton = app.buttons["recorder.stop"].firstMatch
        if stopButton.exists && stopButton.isEnabled {
            stopButton.tap()
            Thread.sleep(forTimeInterval: 1.5)
        }

        // Verify the saved notes page appears read-only in meeting detail when a recording saved.
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 0.8)
        let meetingPredicate = NSPredicate(format: "label CONTAINS '2026-' OR label CONTAINS '會議 –' OR label CONTAINS 'Meeting –'")
        let recordedMeetingRow = app.buttons.matching(meetingPredicate).firstMatch
        let meetingTarget = recordedMeetingRow.waitForExistence(timeout: 5)
            ? recordedMeetingRow
            : app.staticTexts.matching(meetingPredicate).firstMatch
        XCTAssertTrue(meetingTarget.waitForExistence(timeout: 5), "Recorded meeting should appear in the meetings list")
        meetingTarget.tap()
        // Post-meeting auto-transcription surfaces an expected "missing API key" dialog when running offline.
        let okButton = app.buttons.matching(NSPredicate(format: "label == '好' OR label == 'OK'")).firstMatch
        if okButton.waitForExistence(timeout: 3) {
            okButton.tap()
        }
        let savedNote = app.buttons["detail.paper.note"].firstMatch
        XCTAssertTrue(savedNote.waitForExistence(timeout: 8), "Saved handwritten notes should appear read-only in meeting detail")
        try saveScreenshot(named: "detail-paper-notes", to: shotDir)
        savedNote.tap()
        let readonlyCanvas = app.scrollViews["paper.canvas.readonly"].firstMatch
        XCTAssertTrue(readonlyCanvas.waitForExistence(timeout: 5), "Read-only full-page note viewer should open")
        try saveScreenshot(named: "detail-paper-viewer", to: shotDir)
    }

    private func drawStroke(on element: XCUIElement, from start: CGVector, to end: CGVector) {
        let startCoord = element.coordinate(withNormalizedOffset: start)
        let endCoord = element.coordinate(withNormalizedOffset: end)
        startCoord.press(forDuration: 0.05, thenDragTo: endCoord)
    }

    private func saveScreenshot(named name: String, to directory: String?) throws {
        guard let directory, !directory.isEmpty else { return }
        let dirURL = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let image = XCUIScreen.main.screenshot().image
        // Normalize orientation so landscape screenshots render upright in viewers.
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = image.scale
        let normalized = UIGraphicsImageRenderer(size: image.size, format: rendererFormat).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let data = normalized.pngData() else { return }
        try data.write(to: dirURL.appendingPathComponent("\(name).png"))
    }
}
