import XCTest

@testable import PhotosBackup

@MainActor
final class BackgroundKeepAliveTests: XCTestCase {

    /// Records calls and can refuse `start`, the way iOS refuses a session.
    @MainActor
    private final class StubEngine: KeepAliveEngine {
        var onLost: (() -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var shouldFail = false

        func start() throws {
            if shouldFail { throw SilentAudioKeepAliveEngine.Failure("iOS refused the audio session") }
            startCount += 1
        }

        func stop() { stopCount += 1 }
    }

    func testStartRunsTheEngineOnceAndStopReleasesIt() {
        let engine = StubEngine()
        let keepAlive = BackgroundKeepAlive(engine: engine)
        XCTAssertTrue(keepAlive.start())
        XCTAssertTrue(keepAlive.isRunning)
        keepAlive.start()
        XCTAssertEqual(engine.startCount, 1)
        keepAlive.stop(reason: "done")
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(keepAlive.lastStopReason, "done")
    }

    func testStopWithoutStartRecordsTheReasonWithoutTouchingTheEngine() {
        let engine = StubEngine()
        let keepAlive = BackgroundKeepAlive(engine: engine)
        keepAlive.stop(reason: "never ran")
        XCTAssertEqual(engine.stopCount, 0)
        XCTAssertEqual(keepAlive.lastStopReason, "never ran")
        XCTAssertFalse(keepAlive.isRunning)
    }

    func testARefusedStartIsReportedAndNotRunning() {
        let engine = StubEngine()
        engine.shouldFail = true
        let keepAlive = BackgroundKeepAlive(engine: engine)
        XCTAssertFalse(keepAlive.start())
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertEqual(keepAlive.lastStopReason, "iOS refused the audio session")
    }

    func testLosingTheAudioSessionStopsKeepAlive() {
        let engine = StubEngine()
        let keepAlive = BackgroundKeepAlive(engine: engine)
        keepAlive.start()
        engine.onLost?()
        XCTAssertFalse(keepAlive.isRunning)
        XCTAssertEqual(keepAlive.lastStopReason, "iOS took the audio session away")
        XCTAssertEqual(engine.stopCount, 1)
    }

    func testSilentWAVIsValidPCMWithTheRightLengths() {
        let data = SilentAudioKeepAliveEngine.makeSilentWAV()
        XCTAssertEqual(data.count, 44 + 8000 * 2)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual([UInt8](data.subdata(in: 20..<22)), [1, 0])   // PCM format code
        XCTAssertEqual([UInt8](data.subdata(in: 22..<24)), [1, 0])   // one channel
        XCTAssertEqual([UInt8](data.subdata(in: 34..<36)), [16, 0])  // 16-bit samples
        XCTAssertTrue(data.dropFirst(44).allSatisfy { $0 == 0 }, "the payload must be silence")
    }

    func testKeepAlivePreferenceIsOffByDefaultAndPersists() {
        let suite = "test.backgroundKeepAlive"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let first = BackupPreferences(defaults: defaults)
        XCTAssertFalse(first.backgroundKeepAlive)
        first.backgroundKeepAlive = true
        let second = BackupPreferences(defaults: defaults)
        XCTAssertTrue(second.backgroundKeepAlive)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testBatterySafetyLimitIsSane() {
        XCTAssertGreaterThan(BackgroundKeepAlive.maxRuntime, 6 * 60 * 60)
        XCTAssertLessThanOrEqual(BackgroundKeepAlive.maxRuntime, 24 * 60 * 60)
        XCTAssertLessThan(BackgroundKeepAlive.minRuntime, BackgroundKeepAlive.maxRuntime)
    }

    func testClampedDurationStaysInsideTheSafetyBounds() {
        XCTAssertEqual(BackgroundKeepAlive.clampedDuration(2 * 60 * 60), 2 * 60 * 60)
        XCTAssertEqual(BackgroundKeepAlive.clampedDuration(0), BackgroundKeepAlive.minRuntime)
        XCTAssertEqual(BackgroundKeepAlive.clampedDuration(100 * 60 * 60), BackgroundKeepAlive.maxRuntime)
    }

    func testLimitLabelSpeaksInHoursOrMinutes() {
        XCTAssertEqual(BackgroundKeepAlive.limitLabel(for: 30 * 60), "30-minute")
        XCTAssertEqual(BackgroundKeepAlive.limitLabel(for: 90 * 60), "90-minute")
        XCTAssertEqual(BackgroundKeepAlive.limitLabel(for: 2 * 60 * 60), "2-hour")
        XCTAssertEqual(BackgroundKeepAlive.limitLabel(for: 12 * 60 * 60), "12-hour")
    }

    func testRunLengthDefaultsToSixHoursAndPersists() {
        let suite = "test.backgroundRunLength"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let first = BackupPreferences(defaults: defaults)
        XCTAssertEqual(first.backgroundRunLength, .hours6)
        first.backgroundRunLength = .minutes30
        let second = BackupPreferences(defaults: defaults)
        XCTAssertEqual(second.backgroundRunLength, .minutes30)
        UserDefaults().removePersistentDomain(forName: suite)
    }
}