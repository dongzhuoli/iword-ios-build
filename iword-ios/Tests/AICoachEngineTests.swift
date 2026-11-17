import XCTest
import IWordStorage
@testable import IWord

final class AICoachEngineTests: XCTestCase {
    func testConfigurationRejectsPlaceholderAndUnsafeEndpoint() {
        var value = configuration()
        value.apiKey = "xxxxxxxx"
        XCTAssertThrowsError(try value.validate())
        value.apiKey = "valid-secret-key"
        value.endpoint = "https://user:pass@example.com/v1/responses"
        XCTAssertThrowsError(try value.validate())
    }

    func testInputUsesOnlyStudiedWordsAndStableDailyFingerprint() {
        var state = LocalState()
        let studied = word("studied", "study", "学习")
        state.words = [studied, word("unused", "unused", "未学")]
        state.progress[studied.id] = WordProgress(id: studied.id, learned: true, studyCount: 1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [JournalEvent(kind: "RATE", fields: ["wordID": studied.id, "source": "standard", "rating": "forgot", "retry": "0"], occurredAt: now),
                      JournalEvent(kind: "RATE", fields: ["wordID": "unknown", "phone": "13800138000"], occurredAt: now)]
        let first = AICoachEngine.makeInput(state: state, events: events, now: now, previousAnalysis: "上次建议")
        let second = AICoachEngine.makeInput(state: state, events: events, now: now.addingTimeInterval(30), previousAnalysis: "另一段上次建议")
        XCTAssertEqual(first.words.map(\.wordID), [studied.id])
        XCTAssertEqual(first.words[0].evidence.recentForgottenRecalls, 1)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertFalse(String(data: try! JSONEncoder().encode(first), encoding: .utf8)!.contains("13800138000"))
    }

    func testValidationRemovesUnknownWordsAndUnsafePlan() {
        let input = coachInput()
        let report = AICoachReport(analysisSummary: "摘要", findings: [],
            priorityWords: [AICoachPriorityWord(wordID: "unknown", reason: "x", method: "复习")],
            tomorrowPlan: AICoachTomorrowPlan(morning: AICoachTimePlan(message: "早", newWordCount: 99, reviewWordIDs: ["w"]),
                                               afternoon: AICoachTimePlan(message: "午", newWordCount: 99, reviewWordIDs: ["unknown"]),
                                               evening: AICoachTimePlan(message: "晚", newWordCount: 2, reviewWordIDs: ["w"])),
            exercises: [AICoachExercise(kind: .spelling, wordID: "unknown", answer: "no")], proposedDailyNewWords: 99)
        let result = AICoachEngine.validate(report: report, against: input)
        XCTAssertTrue(result.report.priorityWords.isEmpty)
        XCTAssertEqual(result.report.tomorrowPlan.morning.newWordCount + result.report.tomorrowPlan.afternoon.newWordCount, 4)
        XCTAssertEqual(result.report.tomorrowPlan.evening.newWordCount, 0)
        XCTAssertNil(result.report.proposedDailyNewWords)
        XCTAssertFalse(result.report.exercises.isEmpty)
    }

    func testRequestParsesJSONAndKeepsCredentialOutOfBody() async throws {
        let input = coachInput()
        let report = fixtureReport()
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        let body = try JSONSerialization.data(withJSONObject: ["output_text": text])
        let transport = StubCoachTransport(response: AICoachHTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], body: body))
        let result = try await AICoachEngine.request(configuration: configuration(), input: input, transport: transport)
        XCTAssertEqual(result.analysisSummary, report.analysisSummary)
        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer valid-secret-key")
        let requestBody = try XCTUnwrap(request.httpBody)
        XCTAssertFalse(String(decoding: requestBody, as: UTF8.self).contains("valid-secret-key"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["store"] as? Bool, false)
    }

    func testRequestRequiresCompletedStreamAndRejectsFailedEvent() async throws {
        let text = String(decoding: try JSONEncoder().encode(fixtureReport()), as: UTF8.self)
        func frame(_ object: [String: Any]) throws -> String {
            "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
        }
        let delta = try frame(["type": "response.output_text.delta", "delta": text])
        let completed = try frame(["type": "response.completed", "response": ["output_text": text]])
        let transport = StubCoachTransport(response: AICoachHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"], body: Data((delta + completed).utf8)))
        let result = try await AICoachEngine.request(configuration: configuration(), input: coachInput(), transport: transport)
        XCTAssertEqual(result.analysisSummary, "本地测试报告")
        transport.response.body = Data(delta.utf8)
        do {
            _ = try await AICoachEngine.request(configuration: configuration(), input: coachInput(), transport: transport)
            XCTFail("An interrupted stream must not save a report")
        } catch { XCTAssertEqual(error as? AICoachFailure, .incompleteStream) }
        transport.response.body = Data((try frame(["type": "response.failed", "error": ["message": "private-response-detail"]])).utf8)
        do {
            _ = try await AICoachEngine.request(configuration: configuration(), input: coachInput(), transport: transport)
            XCTFail("A failed event must not produce a report")
        } catch {
            XCTAssertEqual(error as? AICoachFailure, .serviceUnavailable)
            XCTAssertFalse(error.localizedDescription.contains("private-response-detail"))
        }
    }

    func testValidationRejectsInventedEvidenceAndDuplicateQuestionIDs() {
        var report = fixtureReport()
        report.findings = [AICoachFinding(id: "bad", text: "伪造证据", evidence: [AICoachEvidence(wordID: "w", metric: "studyCount", value: 999, note: nil)])]
        report.exercises.append(report.exercises[0])
        report.tomorrowPlan.morning.newWordCount = 0
        report.tomorrowPlan.afternoon.newWordCount = 3
        let result = AICoachEngine.validate(report: report, against: coachInput())
        XCTAssertTrue(result.report.findings.isEmpty)
        XCTAssertEqual(result.report.exercises.count, 1)
        XCTAssertEqual(result.report.tomorrowPlan.morning.newWordCount, 2)
        XCTAssertEqual(result.report.tomorrowPlan.afternoon.newWordCount, 1)
    }

    func testCrossDayEvidenceDoesNotReplaceFirstAttemptWithLaterEligibleSuccess() {
        var state = LocalState()
        state.words = [word("w", "word", "词")]
        state.progress["w"] = WordProgress(id: "w", learned: true, studyCount: 2)
        let now = ISO8601DateFormatter().date(from: "2026-11-17T08:00:00Z")!
        let first = JournalEvent(kind: "RATE", fields: ["wordID": "w", "source": "standard", "retry": "0", "rating": "forgot", "meaningEvidenceVersion": "3", "actualIntervalMs": "1000"], occurredAt: now.addingTimeInterval(-120))
        let later = JournalEvent(kind: "RATE", fields: ["wordID": "w", "source": "standard", "retry": "0", "rating": "easy", "meaningIndependent": "true", "meaningEvidenceVersion": "3", "actualIntervalMs": "86400000"], occurredAt: now)
        let input = AICoachEngine.makeInput(state: state, events: [first, later], now: now)
        XCTAssertEqual(input.longTerm.firstCrossDayRecallSamples, 0)
        XCTAssertFalse(input.words[0].evidence.firstCrossDayRecallObserved)
    }

    private func fixtureReport() -> AICoachReport {
        let slot = AICoachTimePlan(message: "复习", newWordCount: 0, reviewWordIDs: ["w"])
        return AICoachReport(analysisSummary: "本地测试报告", findings: [], priorityWords: [],
                            tomorrowPlan: AICoachTomorrowPlan(morning: slot, afternoon: slot, evening: slot),
                            exercises: [AICoachExercise(id: "q1", kind: .meaningRecall, wordID: "w")], proposedDailyNewWords: nil)
    }

    private func configuration() -> AICoachConfiguration {
        AICoachConfiguration(schemaVersion: 1, version: "v1", updatedAt: "2026-11-17T00:00:00Z", endpoint: "https://example.com/v1/responses", model: "test", reasoningEffort: "low", timeoutSeconds: 600, apiKey: "valid-secret-key")
    }
    private func word(_ id: String, _ english: String, _ meaning: String) -> MobileWord {
        MobileWord(id: id, revision: "r1", catalogID: "catalog", word: english, meaning: meaning, pos: "n.", phonetic: "", category: "required", unit: "Unit 1", printedPage: 1, order: 1, usages: [], parts: [], audioHash: nil, audioUsageKey: nil, audioNote: nil, packageID: nil, inactive: nil)
    }
    private func coachInput() -> CoachInput {
        let evidence = CoachWordEvidence(recentMeaningRecallAttempts: 1, recentIndependentMeaningRecalls: 0, recentRecognitionAttempts: 0, recentRecognitionCorrect: 0, recentSpellingAttempts: 0, recentSpellingErrors: 0, recentReviewAttempts: 0, recentHintedRecalls: 1, recentForgottenRecalls: 0, recentPracticeAttempts: 0, recentPracticeCorrect: 0, lastStudiedDay: nil, studyCount: 1, firstCrossDayRecallObserved: false, firstCrossDayIndependent: false)
        return CoachInput(analysisDay: "2026-11-17", generatedAt: "", fingerprint: "", previousAnalysis: nil, recentDays: [], processSamples: [], longTerm: CoachLongTermSummary(observedDays: 1, learnedWords: 1, meaningRecallAttempts: 1, independentMeaningRecalls: 0, recognitionAttempts: 0, recognitionCorrect: 0, spellingAttempts: 0, spellingErrors: 0, firstCrossDayRecallSamples: 0, firstCrossDayIndependentSuccesses: 0), words: [CoachWordReference(wordID: "w", word: "word", meaning: "词", partOfSpeech: "n", personalCue: nil, personalStory: nil, lexicalNotes: [], evidence: evidence)], priorityWordIDs: ["w"], limits: AICoachInputLimits(recentDayCount: 3, maximumRecentEvents: 400, maximumWordReferences: 60, maximumPriorityWords: 40, maximumDailyNewWords: 4), truncated: false, omittedRecentEventCount: 0, elementaryLearner: true, associationPreference: "personal")
    }
}

private final class StubCoachTransport: AICoachTransport {
    var response: AICoachHTTPResponse
    var request: URLRequest?
    init(response: AICoachHTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> AICoachHTTPResponse {
        self.request = request
        return response
    }
}
