import SwiftData
import SwiftUI

/// 準備状況に応じて、モデルのダウンロード → 声紋登録 → 文字起こし画面へ振り分ける。
struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Query(sort: \VoiceProfile.createdAt, order: .reverse) private var profiles: [VoiceProfile]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("kikitxt")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task { await appModel.bootstrap() }
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.phase {
        case .checking:
            ProgressView("準備しています…")
        case .unsupported(let message):
            MessageView(systemImage: "iphone.slash", title: "この端末では使えません", message: message)
        case .needsSpeechModel, .downloadingSpeechModel:
            ModelDownloadView()
        case .preparingVoiceModels(let fraction):
            VStack(spacing: 12) {
                ProgressView(value: fraction)
                Text("話者判別モデルを準備しています（初回のみダウンロード）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        case .failed(let message):
            MessageView(systemImage: "exclamationmark.triangle", title: "準備できませんでした", message: message) {
                Button("もう一度試す") { Task { await appModel.bootstrap() } }
            }
        case .ready:
            if let models = appModel.voiceModels, let locale = appModel.locale {
                if let profile = profiles.first {
                    TranscriptView(models: models, locale: locale, myVoice: profile.embedding)
                } else {
                    EnrollmentView(models: models)
                }
            }
        }
    }
}

struct MessageView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    init(systemImage: String, title: String, message: String, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            actions()
        }
    }
}
