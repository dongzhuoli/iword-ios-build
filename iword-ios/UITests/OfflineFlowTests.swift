import XCTest

final class OfflineFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testSampleAssessmentLearningSpellingResumeAndWeakReview() {
        let app = XCUIApplication()
        app.launchEnvironment["IWORD_UI_TEST_SAMPLE"] = "1"
        app.launch()
        let dismiss = app.buttons["知道了"]
        if dismiss.waitForExistence(timeout: 30) { dismiss.tap() }
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Native home"; home.lifetime = .keepAlways; add(home)
        // Verify the new default, then use the real preference controls to prepare
        // five learned sample words for the later four-option practice test.
        tap(app, "tab-settings"); tap(app, "settings-学习偏好")
        XCTAssertTrue(app.staticTexts["早上 3 个 · 下午 3 个 · 晚上复习"].exists)
        for _ in 0..<4 { tap(app, "daily-new-increase") }
        tap(app, "保存学习偏好"); tap(app, "tab-home")
        tap(app, "开始这一组")
        for _ in 0..<5 { tap(app, "看看词义"); tap(app, "陌生") }
        tap(app, "开始学习")
        for index in 0..<5 {
            tap(app, "理解了，认一认")
            let word = studyWord(app)
            chooseMeaning(app, expected: sampleMeaning(for: word))
            if index == 0 {
                tap(app, "返回今天")
                XCTAssertTrue(app.buttons["继续学习"].waitForExistence(timeout: 10))
                app.terminate(); app.launch()
                tap(app, "继续学习")
                XCTAssertTrue(app.staticTexts["这个意思对上了"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons["继续下一个"].exists)
            }
            tap(app, "继续下一个")
        }
        tap(app, "揭晓答案")
        let letters = Array((app.buttons["开始拼写练习"].value as? String) ?? "radiate").map(String.init)
        tap(app, "开始拼写练习")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "字母 ")).count, 9)
        for letter in letters.prefix(2) { tap(app, "字母 " + letter) }
        // Every accepted letter has already committed before the next selection is enabled.
        tap(app, "返回今天")
        XCTAssertTrue(app.buttons["继续学习"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        tap(app, "继续学习")
        for letter in letters.dropFirst(2) { tap(app, "字母 " + letter) }
        XCTAssertTrue(app.buttons["再拼一次"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Native spelling complete"; attachment.lifetime = .keepAlways; add(attachment)
        tap(app, "返回单词"); tap(app, "想得慢")
        for _ in 0..<4 { tap(app, "揭晓答案"); tap(app, "很快想起") }
        tap(app, "合适")
        let review = app.buttons["start-review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.tap()
        XCTAssertTrue(app.staticTexts["这些词刚练过，先留一点回忆间隔。稍后再学，也可以主动选择遥远的记忆或听音串烧。"].waitForExistence(timeout: 10))
        tap(app, "知道了")
        let distant = app.buttons["start-distant-memory"]
        if !distant.isHittable { app.swipeUp() }
        tap(app, "start-distant-memory")
        for _ in 0..<5 {
            tap(app, "揭晓答案")
            XCTAssertTrue(app.buttons["开始拼写练习"].exists)
            tap(app, "很快想起")
        }
        tap(app, "结束")
        XCTAssertTrue(app.buttons["start-review"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["start-review"].isEnabled)
    }
    func testSAICoachEntryAndConfigurationAreAvailableWithoutNetwork() {
        let app = XCUIApplication(); app.launch()
        let entry = app.buttons["open-ai-coach"]
        if !entry.isHittable { app.swipeUp() }
        tap(app, "open-ai-coach")
        XCTAssertTrue(app.buttons["ai-coach-analyze"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["ai-coach-analyze"].isEnabled)
        tap(app, "更新配置")
        XCTAssertTrue(app.textFields["ai-config-phone"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ai-config-update"].exists)
        tap(app, "sheet-close-AI调用配置")
        tap(app, "sheet-close-AI学习教练")
    }
    func testSRecallMeaningBubbleOpensAndDismisses() {
        let app = XCUIApplication(); app.launch()
        tap(app, "tab-records")
        let word = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recall-word-")).firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 10))
        if !word.isHittable { app.swipeUp() }
        word.tap()
        XCTAssertTrue(app.buttons["recall-meaning-close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["朗读记录中的单词"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Recall meaning bubble"; capture.lifetime = .keepAlways; add(capture)
        tap(app, "recall-meaning-close")
        XCTAssertFalse(app.buttons["recall-meaning-close"].exists)
        word.tap()
        XCTAssertTrue(app.buttons["recall-meaning-close"].waitForExistence(timeout: 10))
        tap(app, "tab-home"); tap(app, "tab-records")
        XCTAssertFalse(app.buttons["recall-meaning-close"].exists)
    }
    func testSDistantMemoriesResumeWithoutNewWords() {
        let app = XCUIApplication(); app.launch()
        let start = app.buttons["start-distant-memory"]
        if !start.isHittable { app.swipeUp() }
        tap(app, "start-distant-memory")
        XCTAssertTrue(app.staticTexts["遥远的记忆"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["揭晓答案"].exists)
        XCTAssertFalse(app.buttons["理解了，下一个"].exists)
        tap(app, "揭晓答案"); tap(app, "很快想起")
        tap(app, "返回今天")
        app.terminate(); app.launch()
        tap(app, "继续遥远的记忆")
        for _ in 0..<4 { tap(app, "揭晓答案"); tap(app, "很快想起") }
        tap(app, "结束")
    }
    func testSListeningMedleyConfigurationAndCancel() {
        let app = XCUIApplication(); app.launch()
        let entry = app.buttons["open-medley"]
        if !entry.isHittable { app.swipeUp() }
        tap(app, "open-medley")
        XCTAssertTrue(app.staticTexts["闭上眼，也能再听一遍。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.steppers["medley-count"].exists)
        XCTAssertTrue(app.buttons["medley-start"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Listening medley configuration"; capture.lifetime = .keepAlways; add(capture)
        tap(app, "关闭串烧设置")
        XCTAssertFalse(app.buttons["medley-start"].exists)
    }
    func testTPreferencesAndOfflinePracticeResume() {
        let app = XCUIApplication(); app.launch()
        tap(app, "tab-settings"); tap(app, "settings-学习偏好")
        let increment = app.buttons["daily-new-increase"]
        XCTAssertTrue(increment.waitForExistence(timeout: 10))
        for _ in 0..<10 { increment.tap() }
        XCTAssertTrue(app.staticTexts["早上 10 个 · 下午 10 个 · 晚上复习"].exists)
        tap(app, "保存学习偏好")
        tap(app, "tab-practice")
        tap(app, "practice-kind"); tap(app, "英选中义")
        tap(app, "practice-start")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "practice-choice-")).firstMatch.waitForExistence(timeout: 15))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Offline meaning practice"; screenshot.lifetime = .keepAlways; add(screenshot)
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "practice-choice-")).allElementsBoundByIndex.map(\.identifier)
        for choice in choices {
            tap(app, choice)
            if app.buttons["practice-next"].waitForExistence(timeout: 1) { break }
        }
        XCTAssertTrue(app.buttons["practice-next"].waitForExistence(timeout: 10))
        let feedback = XCTAttachment(screenshot: app.screenshot()); feedback.name = "Practice answer feedback"; feedback.lifetime = .keepAlways; add(feedback)
        tap(app, "practice-next")
        tap(app, "practice-pause")
        app.terminate(); app.launch(); tap(app, "tab-practice")
        tap(app, "practice-resume")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "practice-choice-")).firstMatch.waitForExistence(timeout: 15))
        tap(app, "practice-pause"); tap(app, "结束这轮练习")
    }
    func testXReportsBackupAndManualSyncControls() {
        let app = XCUIApplication(); app.launch()
        tap(app, "tab-settings"); tap(app, "settings-七天报告")
        XCTAssertTrue(app.buttons["导出七天报告"].waitForExistence(timeout: 10))
        let report = XCTAttachment(screenshot: app.screenshot()); report.name = "Seven day report"; report.lifetime = .keepAlways; add(report)
        tap(app, "关闭"); tap(app, "settings-备份与恢复")
        XCTAssertTrue(app.buttons["创建完整备份"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["从文件恢复"].exists)
        tap(app, "关闭")
        app.swipeUp()
        tap(app, "settings-同步到服务器")
        XCTAssertTrue(app.textFields["backup-phone"].waitForExistence(timeout: 10))
        let sync = XCTAttachment(screenshot: app.screenshot()); sync.name = "Manual server backup"; sync.lifetime = .keepAlways; add(sync)
        tap(app, "关闭")
    }
    func testYVocabularyUnitNavigationAndGlobalSearch() {
        let app = XCUIApplication(); app.launch()
        tap(app, "tab-words")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vocabulary-word-")).firstMatch.exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Vocabulary units"; capture.lifetime = .keepAlways; add(capture)
        let unit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vocabulary-unit-")).firstMatch
        XCTAssertTrue(unit.waitForExistence(timeout: 10)); unit.tap()
        let word = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vocabulary-word-")).firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 10)); word.tap()
        tap(app, "关闭"); tap(app, "返回单元")
        let search = app.textFields["vocabulary-search"]; search.tap(); search.typeText("radiate")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vocabulary-word-")).firstMatch.waitForExistence(timeout: 10))
    }
    func testZManualUpdateControlsAndLocalValidation() {
        let app = XCUIApplication(); app.launch()
        tap(app, "tab-settings")
        tap(app, "settings-词库服务器地址")
        let address = app.textFields["server-base-url"]
        XCTAssertTrue(address.waitForExistence(timeout: 10)); address.tap(); address.typeText("https://example.invalid/")
        tap(app, "保存地址")
        tap(app, "settings-词库更新")
        XCTAssertTrue(app.textFields["update-phone"].waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "Manual content update"; capture.lifetime = .keepAlways; add(capture)
        tap(app, "检查更新")
        XCTAssertTrue(app.staticTexts["update-error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["update-progress"].exists)
        tap(app, "关闭")
    }
    private func tap(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "Missing \(title)", file: file, line: line)
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: button)
        waitForExpectations(timeout: 20)
        button.tap()
    }
    private func studyWord(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> String {
        let value = app.descendants(matching: .any)["study-word"]
        XCTAssertTrue(value.waitForExistence(timeout: 10), "Missing study word", file: file, line: line)
        return value.label
    }
    private func chooseMeaning(_ app: XCUIApplication, expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let choices = app.buttons.matching(NSPredicate(format: "identifier == %@", "study-meaning-choice"))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 10), "Missing meaning choices", file: file, line: line)
        guard let match = choices.allElementsBoundByIndex.first(where: { $0.label == expected }) else {
            XCTFail("Missing expected meaning \(expected)", file: file, line: line)
            return
        }
        match.tap()
    }
    private func sampleMeaning(for word: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let meanings = [
            "radiate": "发射",
            "radiant": "发光的",
            "radical": "根本的",
            "object": "物体",
            "objective": "客观的"
        ]
        guard let meaning = meanings[word] else {
            XCTFail("Unexpected sample word \(word)", file: file, line: line)
            return ""
        }
        return meaning
    }
}
