import AVFAudio
import Foundation
import Observation
import Speech
import UIKit

/// Speech to text for the composer, on this device: Apple's DictationTranscriber, biased toward
/// the user's known terms, when there are any; otherwise SpeechTranscriber, or
/// DictationTranscriber where that model isn't offered. One session app-wide, owned by one
/// composer. The words go into the draft once, at Stop; what the model is still revising
/// only shows in the owner's preview.
@MainActor @Observable
final class DictationController {
    enum State: Equatable {
        case idle, preparing, recording, finishing, failed(String)
        /// Sending waits until the words are in the draft.
        var blocksSending: Bool { self == .preparing || self == .recording || self == .finishing }
    }

    private(set) var state = State.idle
    /// Settled words, in order: what the draft gets at Stop.
    private(set) var finalizedText = ""
    /// The model's current guess at the words after `finalizedText`: shown, never inserted.
    private(set) var volatileText = ""
    /// The composer this session (or its failure) belongs to.
    private(set) var owner: UUID?
    private(set) var permissionDenied = false
    /// The first use in a language fetches the system's speech model.
    private(set) var downloading = false
    private var session = UUID()
    private let microphone = Microphone()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var preparing: Task<Void, Never>?
    private var results: Task<Void, Never>?
    private var insertion: ((String) -> Void)?
    private var interruption: NSObjectProtocol?
    /// The screen stays on while words keep coming; after `quietLimit` without any, auto-lock
    /// is back to the user's setting (locking stops the session and keeps what was heard).
    private var lastHeard = ContinuousClock.now
    private var awake: Task<Void, Never>?
    private static let quietLimit = Duration.seconds(30)

    private enum Transcriber {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)
    }

    /// What the recognizer should expect: `terms` as they are, then folder, agent and file
    /// names (and their stems) from `paths`, within the analyzer's limits.
    static func vocabulary(from paths: [String], after terms: [String] = []) -> [String] {
        let candidates = terms.map { [$0] } + paths.map { path in
            let name = (path as NSString).lastPathComponent
            return [name, (name as NSString).deletingPathExtension]
        }
        var vocabulary: [String] = []
        var seen = Set<String>()
        var total = 0
        for term in candidates.joined() {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 64, !term.contains(where: \.isNewline),
                  total + term.count <= 2048, seen.insert(term.lowercased()).inserted else { continue }
            vocabulary.append(term)
            total += term.count
            if vocabulary.count == 50 { break }
        }
        return vocabulary
    }

    /// `terms` are the user's known terms, `names` the folder, agent and file names around the
    /// composer; both become the recognizer's hints.
    func start(owner token: UUID, terms: [String], names: [String], insert: @escaping (String) -> Void) {
        guard !state.blocksSending else { return }
        teardown()
        permissionDenied = false
        owner = token
        insertion = insert
        state = .preparing
        keepAwake()
        let id = session
        let hinted = terms.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let context = Self.vocabulary(from: names, after: terms)
        preparing = Task { await prepare(id: id, context: context, hinted: hinted) }
    }

    /// Ends listening and inserts everything heard, once the model has settled it.
    func stop(owner token: UUID) {
        guard owner == token, state == .recording, let analyzer else { return }
        state = .finishing
        endAudio()
        input?.finish()
        input = nil
        let id = session
        let results = results
        Task {
            // Stopped is stopped: if the model can't settle the rest (nothing was said), keep
            // what it already settled rather than report an error.
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { await analyzer.cancelAndFinishNow() }
            await results?.value
            finish(id: id)
        }
    }

    /// Ends the session without inserting anything; also dismisses a failure.
    func cancel(owner token: UUID) {
        guard owner == token else { return }
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        teardown()
        state = .idle
        owner = nil
    }

    func clearError() {
        guard case .failed = state, let owner else { return }
        cancel(owner: owner)
    }

    /// No recording in the background: keep what was heard.
    func backgrounded() {
        guard let owner else { return }
        if state == .recording { stop(owner: owner) } else if state == .preparing { cancel(owner: owner) }
    }

    private func prepare(id: UUID, context: [String], hinted: Bool) async {
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                permissionDenied = true
                throw DictationError.microphoneDenied
            }
            let transcriber: Transcriber
            var modules: [any SpeechModule]
            // Only DictationTranscriber takes hints (SpeechTranscriber ignores them), so the
            // user's known terms choose it; without them, SpeechTranscriber where offered.
            if !hinted, SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
                let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                transcriber = .speech(module)
                // Skips silence, so a pause isn't sent through the model.
                modules = [module, SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false)]
            } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
                let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
                transcriber = .dictation(module)
                modules = [module]
            } else {
                throw DictationError.unsupportedLocale
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                guard session == id else { return }
                downloading = true
                defer { downloading = false }
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                throw DictationError.modelUnavailable
            }
            let analyzer = SpeechAnalyzer(modules: modules)
            if case .dictation = transcriber, !context.isEmpty {
                let hints = AnalysisContext()
                hints.contextualStrings[.general] = context
                try await analyzer.setContext(hints)
            }
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(256))
            try await analyzer.start(inputSequence: stream)
            guard session == id else {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                return
            }
            // Kept from here on: a cancel while the microphone starts tears these down.
            self.analyzer = analyzer
            input = continuation
            results = Task {
                do {
                    switch transcriber {
                    case .speech(let module):
                        for try await result in module.results { receive(result.text, final: result.isFinal, id: id) }
                    case .dictation(let module):
                        for try await result in module.results { receive(result.text, final: result.isFinal, id: id) }
                    }
                } catch {
                    // After Stop the results can end in an error (silence alone is rejected);
                    // `stop` then finishes with what was settled.
                    if state != .finishing { fail(id: id, error: error) }
                }
            }
            try await beginAudio(id: id, format: format, into: continuation)
            guard session == id else { return }
            state = .recording
        } catch {
            fail(id: id, error: error)
        }
    }

    private func beginAudio(id: UUID, format: AVAudioFormat, into stream: AsyncStream<AnalyzerInput>.Continuation) async throws {
        try await microphone.open(format: format, into: stream) { [weak self] in
            Task { @MainActor in self?.fail(id: id, error: DictationError.overflow) }
        } lost: { [weak self] in
            // A new route (the engine stops itself): keep what was heard.
            Task { @MainActor in self?.endRecording(id: id) }
        }
        guard session == id else { return }
        // A call or Siri: keep what was heard.
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            let began = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated { if began { self?.endRecording(id: id) } }
        }
    }

    private func endRecording(id: UUID) {
        guard session == id, let owner else { return }
        stop(owner: owner)
    }

    private func receive(_ text: AttributedString, final: Bool, id: UUID) {
        guard session == id else { return }
        // Each final result settles the next stretch of audio; a volatile one replaces the guess.
        if final {
            finalizedText += String(text.characters)
            volatileText = ""
        } else {
            volatileText = String(text.characters)
        }
        keepAwake()
    }

    /// Holds auto-lock off from now until `quietLimit` passes with no new words. Cheap per word:
    /// one timestamp; the watcher wakes at most once per `quietLimit`.
    private func keepAwake() {
        lastHeard = .now
        guard awake == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        awake = Task { [weak self] in
            while let deadline = self?.lastHeard.advanced(by: Self.quietLimit) {
                guard (try? await Task.sleep(until: deadline)) != nil, let self else { return }
                if deadline == self.lastHeard.advanced(by: Self.quietLimit) { return self.releaseAwake() }
            }
        }
    }

    private func releaseAwake() {
        awake?.cancel()
        awake = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func finish(id: UUID) {
        guard session == id else { return }
        let text = finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let insert = insertion
        teardown()
        state = .idle
        owner = nil
        if !text.isEmpty { insert?(text) }
    }

    /// Keeps the owner, so only its composer reports the failure.
    private func fail(id: UUID, error: Error) {
        guard session == id else { return }
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        teardown()
        state = .failed(error.localizedDescription)
    }

    /// Ends audio and tasks and orphans every callback still in flight.
    private func teardown() {
        session = UUID()
        preparing?.cancel()
        preparing = nil
        results?.cancel()
        results = nil
        endAudio()
        input?.finish()
        input = nil
        analyzer = nil
        insertion = nil
        finalizedText = ""
        volatileText = ""
        downloading = false
        releaseAwake()
    }

    private func endAudio() {
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        microphone.close()
    }
}

private enum DictationError: LocalizedError {
    case microphoneDenied, unsupportedLocale, modelUnavailable, noMicrophone, audioFormat, overflow

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Allow it in Settings to dictate."
        case .unsupportedLocale: "Dictation isn't available in your language on this device."
        case .modelUnavailable: "The speech model isn't ready on this device."
        case .noMicrophone: "No microphone is available."
        case .audioFormat: "The microphone's audio format isn't supported."
        case .overflow: "Dictation fell behind the microphone. Try again."
        }
    }
}

/// The audio session and engine, off the main thread: activating the one and starting the
/// other are slow, blocking calls, which on the main thread stalled the card's opening (and
/// deactivating, its closing). Every call runs in order on one queue, so a close never
/// overtakes the open before it; the state is only touched there, hence unchecked.
private final class Microphone: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.btuckerc.herdwick.microphone", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var active = false
    private var configuration: NSObjectProtocol?

    /// Taps the microphone into `stream`. `lost`: the route changed and the engine stopped.
    func open(format: AVAudioFormat, into stream: AsyncStream<AnalyzerInput>.Continuation,
              overflow: @escaping @Sendable () -> Void, lost: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    let audio = AVAudioSession.sharedInstance()
                    try audio.setCategory(.record, mode: .default)
                    try audio.setActive(true)
                    active = true
                    let engine = AVAudioEngine()
                    self.engine = engine
                    try Self.tap(engine.inputNode, format: format, into: stream, overflow: overflow)
                    configuration = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in lost() }
                    try engine.start()
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Stops the engine and lets other audio resume; a no-op when closed.
    func close() {
        queue.async { [self] in
            if let configuration { NotificationCenter.default.removeObserver(configuration) }
            configuration = nil
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            if active {
                active = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// The tap runs on the audio thread.
    private static func tap(_ node: AVAudioInputNode, format: AVAudioFormat,
                            into stream: AsyncStream<AnalyzerInput>.Continuation,
                            overflow: @escaping @Sendable () -> Void) throws {
        let source = node.outputFormat(forBus: 0)
        guard source.channelCount > 0, source.sampleRate > 0 else { throw DictationError.noMicrophone }
        guard let converter = AVAudioConverter(from: source, to: format) else { throw DictationError.audioFormat }
        node.installTap(onBus: 0, bufferSize: 4_096, format: source) { buffer, _ in
            guard let converted = convert(buffer, with: converter) else { return }
            // The analyzer can't keep up: stop rather than leave a gap in the words.
            if case .dropped = stream.yield(AnalyzerInput(buffer: converted)) {
                stream.finish()
                overflow()
            }
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
