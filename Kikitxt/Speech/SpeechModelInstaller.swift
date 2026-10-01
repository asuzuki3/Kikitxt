import Foundation
import Speech

/// SpeechTranscriber（ja-JP）の対応確認と言語モデルのダウンロード。
nonisolated enum SpeechModelInstaller {
    static let requestedLocale = Locale(identifier: "ja-JP")

    enum Availability: Equatable {
        case unsupportedDevice
        case unsupportedLocale
        case needsDownload(Locale)
        case installed(Locale)
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    static func checkAvailability() async -> Availability {
        guard SpeechTranscriber.isAvailable else { return .unsupportedDevice }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return .unsupportedLocale
        }
        let status = await AssetInventory.status(forModules: [makeTranscriber(locale: locale)])
        switch status {
        case .installed: return .installed(locale)
        case .unsupported: return .unsupportedLocale
        case .supported, .downloading: return .needsDownload(locale)
        @unknown default: return .needsDownload(locale)
        }
    }

    /// 言語モデルをダウンロードする。progress には 0〜1 の進捗を渡す。
    static func download(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let modules: [any SpeechModule] = [makeTranscriber(locale: locale)]
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            return  // すでに導入済み
        }
        let watcher = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }
}
