import SwiftUI

/// 日本語の言語モデルが未導入のときに、ダウンロードを促す。
struct ModelDownloadView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("日本語の音声モデルが必要です")
                .font(.title3.weight(.semibold))
            Text("端末内で文字起こしするために、初回だけモデルをダウンロードします。Wi‑Fi接続をおすすめします。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if case .downloadingSpeechModel(let fraction) = appModel.phase {
                ProgressView(value: fraction)
                    .padding(.top, 8)
                Text("ダウンロード中 \(Int(fraction * 100))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                Task { await appModel.downloadSpeechModel() }
            } label: {
                Text("ダウンロード")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isDownloading)
        }
        .padding(24)
    }

    private var isDownloading: Bool {
        if case .downloadingSpeechModel = appModel.phase { return true }
        return false
    }
}
