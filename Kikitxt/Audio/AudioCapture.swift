import AVFAudio

/// マイク入力を 16kHz・モノラル・Float32 のサンプル列として流す。
nonisolated final class AudioCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case unsupportedInputFormat

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "マイクの使用が許可されていません。設定アプリで許可してください。"
            case .unsupportedInputFormat: "マイクの音声形式を変換できませんでした。"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<[Float]>.Continuation?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// 録音を開始し、変換済みサンプルのストリームを返す。stop() でストリームが終わる。
    func start() throws -> AsyncStream<[Float]> {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw CaptureError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = PCMConverter(from: inputFormat, to: PCM.workingFormat) else {
            throw CaptureError.unsupportedInputFormat
        }

        // 処理が詰まっても最新の約20秒分は保持する
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(200))
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let converted = converter.convert(buffer) else { return }
            continuation.yield(PCM.samples(of: converted))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
