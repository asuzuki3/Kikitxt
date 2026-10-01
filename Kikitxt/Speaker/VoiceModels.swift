import FluidAudio
import Foundation

/// FluidAudio の VAD と話者埋め込みモデル。初回のみモデルファイルをダウンロードし、以降は端末内で動く。
/// 音声データは外部へ送らない（ダウンロードはモデルファイルの取得だけ）。
actor VoiceModels {
    /// VAD が発話とみなす確率のしきい値。PoCの実測で調整する
    static let vadThreshold: Float = 0.6
    /// 話者埋め込みモデルの入力窓（10秒）
    private static let embeddingWindow = 160_000

    let vad: VadManager
    private let diarizer: DiarizerManager

    private init(vad: VadManager, diarizer: DiarizerManager) {
        self.vad = vad
        self.diarizer = diarizer
    }

    /// progress には 0〜1 の進捗を渡す（VAD 分を前半、話者モデル分を後半として合算）
    static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> VoiceModels {
        let vad = try await VadManager(config: VadConfig(defaultThreshold: vadThreshold)) { p in
            progress(p.fractionCompleted * 0.3)
        }
        let models = try await DiarizerModels.downloadIfNeeded { p in
            progress(0.3 + p.fractionCompleted * 0.7)
        }
        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)
        progress(1)
        return VoiceModels(vad: vad, diarizer: diarizer)
    }

    /// 16kHz・モノラルの音声から話者埋め込みを作る。10秒を超える音声は10秒ごとに区切って平均する。
    func embedding(for samples: [Float]) throws -> [Float]? {
        guard !samples.isEmpty else { return nil }
        let window = Self.embeddingWindow
        var embeddings: [[Float]] = []
        var start = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            // 2つ目以降の窓が3秒未満なら、短すぎて特徴が不安定なので使わない
            if start > 0 && end - start < 48_000 { break }
            embeddings.append(try diarizer.extractSpeakerEmbedding(from: Array(samples[start..<end])))
            start = end
        }
        return SpeakerIdentifier.average(embeddings)
    }

    /// 無音を除いた発話部分だけをつなげて返す（声紋登録用）
    func speechOnly(_ samples: [Float]) async throws -> [Float] {
        try await vad.segmentSpeechAudio(samples).flatMap { $0 }
    }
}
