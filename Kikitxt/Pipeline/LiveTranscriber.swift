@preconcurrency import AVFAudio
import CoreMedia
import FluidAudio
import Foundation
import Speech

/// マイク音声を VAD で発話区間に分け、発話区間だけを SpeechAnalyzer に渡して文字起こしし、
/// 区間ごとに話者を判別する。無音区間では文字起こし・話者判別を動かさない。
actor LiveTranscriber {
    enum Event: Sendable {
        /// 確定した文
        case line(id: UUID, segmentID: Int, date: Date, text: String)
        /// 認識途中の文（空文字で消去）
        case volatile(String)
        /// 発話区間の話者が決まった
        case speaker(segmentID: Int, decision: SpeakerIdentifier.Decision)
        /// 発話中かどうか
        case speaking(Bool)
        case failure(String)
    }

    private static let chunkSize = VadManager.chunkSize  // 4096サンプル = 256ms
    /// 話者判別の単位を区切る最大長。話者埋め込みモデルの窓（10秒）に合わせる
    private static let maxSegmentSamples = 160_000
    private static let sampleRate = Int(PCM.sampleRate)

    private let models: VoiceModels
    private var identifier: SpeakerIdentifier
    private let locale: Locale
    private let startDate: Date
    private let events: AsyncStream<Event>.Continuation
    nonisolated let eventStream: AsyncStream<Event>

    private let segmentation = VadSegmentationConfig(minSilenceDuration: 0.6, speechPadding: 0.1)
    private var vadState = VadStreamState.initial()

    private var analyzer: SpeechAnalyzer?
    private var analyzerInput: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerConverter: PCMConverter?
    private var resultsTask: Task<Void, Never>?

    private var pending: [Float] = []
    private var previousChunk: [Float] = []
    private var capturedSamples = 0
    private var fedSamples = 0
    private var timeline = SpeechTimeline()
    private var current: (id: Int, samples: [Float])?
    private var nextSegmentID = 0

    init(models: VoiceModels, myVoice: [Float], locale: Locale, startDate: Date = .now) {
        self.models = models
        self.identifier = SpeakerIdentifier(me: myVoice)
        self.locale = locale
        self.startDate = startDate
        (eventStream, events) = AsyncStream<Event>.makeStream()
    }

    /// 音声ストリームが終わるまで処理を続け、最後に残りを確定させてイベントストリームを閉じる。
    func run(audio: AsyncStream<[Float]>) async {
        do {
            try await startAnalyzer()
            for await samples in audio {
                await ingest(samples)
            }
            await closeSegment()
            analyzerInput?.finish()
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            events.yield(.failure("文字起こしでエラーが発生しました：\(error.localizedDescription)"))
        }
        await resultsTask?.value
        events.finish()
    }

    // MARK: - SpeechAnalyzer

    private func startAnalyzer() async throws {
        let transcriber = SpeechModelInstaller.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? PCM.workingFormat
        if format != PCM.workingFormat {
            analyzerConverter = PCMConverter(from: PCM.workingFormat, to: format)
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        analyzerInput = continuation
        try await analyzer.start(inputSequence: input)
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    await self?.handle(result)
                }
            } catch {
                await self?.report(error)
            }
        }
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.isFinal else {
            events.yield(.volatile(text))
            return
        }
        events.yield(.volatile(""))
        guard !text.isEmpty else { return }

        let feedSample = Int(result.range.start.seconds * Double(Self.sampleRate))
        let segment = timeline.segment(atFeedSample: feedSample)
        let captureSample = timeline.captureSample(forFeedSample: feedSample) ?? 0
        let date = startDate.addingTimeInterval(Double(captureSample) / Double(Self.sampleRate))
        events.yield(.line(id: UUID(), segmentID: segment?.id ?? -1, date: date, text: text))
    }

    private func report(_ error: any Error) {
        events.yield(.failure("文字起こし結果の受信でエラーが発生しました：\(error.localizedDescription)"))
    }

    private func feedAnalyzer(_ samples: [Float]) {
        guard !samples.isEmpty, var buffer = PCM.buffer(from: samples) else { return }
        if let analyzerConverter {
            guard let converted = analyzerConverter.convert(buffer) else { return }
            buffer = converted
        }
        let start = CMTime(value: CMTimeValue(fedSamples), timescale: CMTimeScale(Self.sampleRate))
        analyzerInput?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
        fedSamples += samples.count
    }

    // MARK: - VAD と発話区間

    private func ingest(_ samples: [Float]) async {
        pending.append(contentsOf: samples)
        while pending.count >= Self.chunkSize {
            let chunk = Array(pending.prefix(Self.chunkSize))
            pending.removeFirst(Self.chunkSize)
            await process(chunk)
        }
    }

    private func process(_ chunk: [Float]) async {
        let chunkStart = capturedSamples
        capturedSamples += chunk.count

        let result: VadStreamResult
        do {
            result = try await models.vad.processStreamingChunk(chunk, state: vadState, config: segmentation)
        } catch {
            events.yield(.failure("発話検出でエラーが発生しました：\(error.localizedDescription)"))
            return
        }
        vadState = result.state

        if result.event?.isStart == true, current == nil {
            // 発話の立ち上がりを取りこぼさないよう、直前のチャンクも含める
            openSegment(captureStart: chunkStart - previousChunk.count)
            append(previousChunk)
            events.yield(.speaking(true))
        }
        if current != nil {
            append(chunk)
        }
        if result.event?.isEnd == true {
            await closeSegment()
            events.yield(.speaking(false))
        } else if let current, current.samples.count >= Self.maxSegmentSamples {
            // 長い発話は区切って、話者の交代を拾えるようにする
            await closeSegment()
            openSegment(captureStart: capturedSamples)
        }
        previousChunk = chunk
    }

    private func openSegment(captureStart: Int) {
        let id = nextSegmentID
        nextSegmentID += 1
        current = (id, [])
        timeline.begin(id: id, captureStart: max(0, captureStart), feedStart: fedSamples)
    }

    private func append(_ samples: [Float]) {
        current?.samples.append(contentsOf: samples)
        feedAnalyzer(samples)
    }

    private func closeSegment() async {
        guard let segment = current else { return }
        current = nil
        timeline.end(id: segment.id, feedEnd: fedSamples)

        // この区間までの文を確定させる
        let through = CMTime(value: CMTimeValue(fedSamples), timescale: CMTimeScale(Self.sampleRate))
        try? await analyzer?.finalize(through: through)

        guard !segment.samples.isEmpty else { return }
        do {
            guard let embedding = try await models.embedding(for: segment.samples) else { return }
            let seconds = Double(segment.samples.count) / Double(Self.sampleRate)
            let decision = identifier.identify(embedding, seconds: seconds)
            events.yield(.speaker(segmentID: segment.id, decision: decision))
        } catch {
            events.yield(.failure("話者判別でエラーが発生しました：\(error.localizedDescription)"))
        }
    }
}
