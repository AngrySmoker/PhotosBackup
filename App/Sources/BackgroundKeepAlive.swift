import AVFoundation
import Foundation

/// Plays the silent audio that keeps the process alive. A protocol so the
/// keep-alive state machine can be exercised offline without audio hardware.
@MainActor
protocol KeepAliveEngine: AnyObject {
    /// Called when iOS takes background playback away — an interruption the
    /// session cannot resume from, or the media services resetting. The owner
    /// responds by stopping, so the app never claims audio it is not playing.
    var onLost: (() -> Void)? { get set }
    /// Activates the audio session and begins looping the silent track.
    /// Throws when iOS refuses, e.g. the category is unavailable.
    func start() throws
    /// Ends playback and releases the session. Safe to call when not running.
    func stop()
}

/// The real engine. Loops a generated near-silent WAV through a `.playback`
/// session that mixes with other audio, so it neither stops the user's music
/// nor needs a bundled asset. iOS keeps a process with an active playback
/// session alive in the background; when that claim is taken away, `onLost`
/// tells the owner so it can decide whether background draining is worth
/// continuing at all.
@MainActor
final class SilentAudioKeepAliveEngine: KeepAliveEngine {
    /// Not zero: some iOS builds optimise away digital silence, while a 1%
    /// volume track is inaudible but always "real" playback.
    static let volume: Float = 0.01

    var onLost: (() -> Void)?

    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // `.mixWithOthers` keeps this from interrupting Music or Podcasts.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        player = try AVAudioPlayer(contentsOf: silentTrackURL())
        player?.numberOfLoops = -1
        player?.volume = Self.volume
        player?.prepareToPlay()
        guard player?.play() == true else {
            throw Failure("iOS did not start the silent audio track.")
        }
        registerObservers()
    }

    func stop() {
        player?.stop()
        player = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        // `notifyOthers` lets Music resume whatever this had ducked.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func registerObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in self?.handleInterruption(note) })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onLost?() })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onLost?()
        case .ended:
            // Resume only when iOS says the session may continue; otherwise the
            // background claim is gone and the owner has to know.
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                player?.play()
            } else {
                onLost?()
            }
        @unknown default:
            onLost?()
        }
    }
}

extension SilentAudioKeepAliveEngine {
    /// Writes the silent track into Caches and returns its URL.
    fileprivate func silentTrackURL() -> URL {
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("keep-alive-silence.wav")
        try? Self.makeSilentWAV().write(to: url)
        return url
    }

    /// A minimal RIFF/WAVE file: 44-byte header plus one second of 8 kHz
    /// 16-bit mono PCM silence. Generated in code rather than bundled so the
    /// asset cannot go missing and the format is visible to review. Reads no
    /// isolated state, so it stays callable from any context.
    nonisolated static func makeSilentWAV(durationSeconds: Int = 1, sampleRate: Int = 8000) -> Data {
        let bytesPerSample = 2
        let channels = 1
        let dataBytes = sampleRate * bytesPerSample * channels * durationSeconds
        var data = Data()
        func append(_ string: String) { data.append(string.data(using: .ascii)!) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append(UInt32(36 + dataBytes)); append("WAVE")
        append("fmt "); append(UInt32(16))
        append(UInt16(1))                                      // PCM
        append(UInt16(channels)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * bytesPerSample)) // byte rate
        append(UInt16(channels * bytesPerSample))              // block align
        append(UInt16(16))                                     // bits per sample
        append("data"); append(UInt32(dataBytes))
        data.append(contentsOf: [UInt8](repeating: 0, count: dataBytes))
        return data
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }
}

/// Owns the "keep uploading after you leave the app" feature: starts the
/// silent-audio engine when the app is backgrounded with work on the queue,
/// and publishes its state for Settings. Each start is bounded by `maxRuntime`
/// so a wedged queue cannot pay for audio playback all day; the coordinator
/// stops it as soon as the queue has nothing workable left.
@MainActor
final class BackgroundKeepAlive: ObservableObject {
    /// The longest a single run may last, whatever the user picked: a queue
    /// that needs longer than this should be finished by iOS's own processing
    /// windows instead.
    static let maxRuntime: TimeInterval = 12 * 60 * 60
    /// The shortest sensible run; shorter than this and the normal
    /// processing-window path is the better tool.
    static let minRuntime: TimeInterval = 15 * 60

    @Published private(set) var isRunning = false
    /// Why it last stopped, so Settings can explain an unexpected end.
    @Published private(set) var lastStopReason: String?

    private let engine: KeepAliveEngine
    private var timeoutTask: Task<Void, Never>?

    init(engine: KeepAliveEngine) {
        self.engine = engine
    }

    /// Starts the engine for one run of at most `duration`. Returns whether
    /// keep-alive is running; `false` means iOS refused and the caller should
    /// fall back to the normal processing-window path. No default duration:
    /// default arguments are evaluated outside the main actor, where neither
    /// this class's initialiser nor `Self` may be referenced.
    @discardableResult
    func start(duration: TimeInterval) -> Bool {
        guard !isRunning else { return true }
        lastStopReason = nil
        engine.onLost = { [weak self] in
            self?.stop(reason: "iOS took the audio session away")
        }
        do {
            try engine.start()
        } catch {
            engine.onLost = nil
            isRunning = false
            lastStopReason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
        isRunning = true
        let limit = Self.clampedDuration(duration)
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop(reason: "Reached its \(Self.limitLabel(for: limit)) run limit")
        }
        return true
    }

    /// Keeps a requested run inside the safety bounds. MainActor-isolated like
    /// the stored bounds it reads; every caller, including the tests, already
    /// runs on the main actor.
    static func clampedDuration(_ duration: TimeInterval) -> TimeInterval {
        min(max(duration, minRuntime), maxRuntime)
    }

    /// "6-hour" / "30-minute", for the stop reason shown in Settings.
    static func limitLabel(for duration: TimeInterval) -> String {
        duration >= 3600 ? "\(Int(duration / 3600))-hour" : "\(Int(duration / 60))-minute"
    }

    func stop(reason: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        engine.onLost = nil
        let wasRunning = isRunning
        isRunning = false
        lastStopReason = reason
        guard wasRunning else { return }
        engine.stop()
    }
}