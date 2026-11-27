//
//  MeetingCoachLandscapeUITests.swift
//  KurnUITests
//
//  Manual acceptance run for the meeting coach in landscape: the simulator
//  cannot be rotated from the command line, but XCUIDevice can. Needs a real
//  OpenAI key and an audio file, so it skips unless both are passed through
//  the test runner environment (TEST_RUNNER_MC_CAPTURE_FILE,
//  TEST_RUNNER_MC_OPENAI_API_KEY, TEST_RUNNER_MC_SHOT_DIR). It is not part
//  of CI.
//

import XCTest

@MainActor
final class MeetingCoachLandscapeUITests: XCTestCase {
    func testCoachPanelInLandscape() throws {
        let env = ProcessInfo.processInfo.environment
        guard let file = env["MC_CAPTURE_FILE"], let key = env["MC_OPENAI_API_KEY"], let dir = env["MC_SHOT_DIR"] else {
            throw XCTSkip("meeting-coach acceptance inputs not provided")
        }
        let app = XCUIApplication()
        app.launchEnvironment["KURN_DEBUG_CAPTURE_FILE"] = file
        app.launchEnvironment["KURN_DEBUG_OPENAI_API_KEY"] = key
        // The queries below use English labels; the simulator may run in zh-Hant or ja.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let record = app.buttons["Record"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        record.tap()
        let ask = app.buttons["What should I say?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 15))

        func shot(_ name: String) throws {
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }

        // Let a few 20 s windows finalize, then ask for a card.
        Thread.sleep(forTimeInterval: 65)
        try shot("landscape-transcript")
        ask.tap()
        Thread.sleep(forTimeInterval: 10)
        try shot("landscape-card")
        app.staticTexts["coach.card.text"].tap()
        Thread.sleep(forTimeInterval: 2)
        try shot("landscape-card-expanded")
        app.buttons["Wrap up"].tap()
        Thread.sleep(forTimeInterval: 12)
        try shot("landscape-wrapup")
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Stop"].tap()
        Thread.sleep(forTimeInterval: 8)
        XCUIDevice.shared.orientation = .portrait
    }
}
