import Foundation
import Observation

/// 起動時の準備（言語モデル・話者判別モデル・声紋）の進み具合を管理する。
@Observable
final class AppModel {
    enum Phase: Equatable {
        case checking
        case unsupported(String)
        case needsSpeechModel
        case downloadingSpeechModel(Double)
        case preparingVoiceModels(Double)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    private(set) var locale: Locale?
    private(set) var voiceModels: VoiceModels?

    func bootstrap() async {
        phase = .checking
        switch await SpeechModelInstaller.checkAvailability() {
        case .unsupportedDevice:
            phase = .unsupported("この端末は端末内の日本語文字起こし（SpeechTranscriber）に対応していません。")
        case .unsupportedLocale:
            phase = .unsupported("この端末では日本語（ja-JP）の文字起こしが使えません。")
        case .needsDownload(let locale):
            self.locale = locale
            phase = .needsSpeechModel
        case .installed(let locale):
            self.locale = locale
            await prepareVoiceModels()
        }
    }

    func downloadSpeechModel() async {
        guard let locale else { return }
        phase = .downloadingSpeechModel(0)
        do {
            try await SpeechModelInstaller.download(locale: locale) { fraction in
                Task { @MainActor in
                    if case .downloadingSpeechModel = self.phase {
                        self.phase = .downloadingSpeechModel(fraction)
                    }
                }
            }
            await prepareVoiceModels()
        } catch {
            phase = .failed("言語モデルをダウンロードできませんでした：\(error.localizedDescription)")
        }
    }

    private func prepareVoiceModels() async {
        if voiceModels != nil {
            phase = .ready
            return
        }
        phase = .preparingVoiceModels(0)
        do {
            voiceModels = try await VoiceModels.load { fraction in
                Task { @MainActor in
                    if case .preparingVoiceModels = self.phase {
                        self.phase = .preparingVoiceModels(fraction)
                    }
                }
            }
            phase = .ready
        } catch {
            phase = .failed("話者判別モデルを準備できませんでした：\(error.localizedDescription)")
        }
    }
}
