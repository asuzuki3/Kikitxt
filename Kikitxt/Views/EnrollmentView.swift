import SwiftData
import SwiftUI

/// 自分の声を約30秒録音して声紋を作り、端末内に保存する。
struct EnrollmentView: View {
    let models: VoiceModels
    var onFinish: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var recorder = EnrollmentRecorder()

    private let script = """
        今日はいい天気ですね。朝はコーヒーを飲みながら、一日の予定を確認しています。\
        午前中は打合せが二つあって、午後は資料をまとめる予定です。\
        帰りに本屋に寄って、気になっていた新刊を探してみようと思います。\
        週末は家族と近くの公園まで散歩に出かけるつもりです。
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自分の声を登録")
                .font(.title3.weight(.semibold))
            Text("下の文章を普段の声で読み上げてください。約30秒で終わります。読み終わったら、時間まで自由に話してください。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(script)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))

            LevelMeter(levels: recorder.levels)
                .frame(height: 40)
                .frame(maxWidth: .infinity)

            ProgressView(value: recorder.progress)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            if let message = recorder.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button {
                Task { await primaryAction() }
            } label: {
                Text(buttonTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(recorder.state == .processing)
        }
        .padding(24)
        .onDisappear { recorder.cancel() }
    }

    private var statusText: String {
        switch recorder.state {
        case .idle: "準備ができたら録音を始めてください"
        case .recording: "\(Int(recorder.elapsed)) / \(Int(EnrollmentRecorder.duration))秒"
        case .processing: "声の特徴を計算しています…"
        }
    }

    private var buttonTitle: String {
        switch recorder.state {
        case .idle: recorder.errorMessage == nil ? "録音を始める" : "やり直す"
        case .recording: "やり直す"
        case .processing: "計算中…"
        }
    }

    private func primaryAction() async {
        if recorder.state == .recording {
            recorder.cancel()
            return
        }
        guard let result = await recorder.record(using: models) else { return }
        let existing = (try? modelContext.fetch(FetchDescriptor<VoiceProfile>())) ?? []
        existing.forEach(modelContext.delete)
        modelContext.insert(VoiceProfile(embedding: result.embedding, speechSeconds: result.speechSeconds))
        try? modelContext.save()
        onFinish?()
    }
}

@Observable
final class EnrollmentRecorder {
    enum State { case idle, recording, processing }

    static let duration: Double = 30
    /// 声紋に使う発話がこれより短ければやり直してもらう（秒）
    private static let minimumSpeech: Double = 10

    private(set) var state: State = .idle
    private(set) var elapsed: Double = 0
    private(set) var levels: [Float] = Array(repeating: 0, count: 24)
    private(set) var errorMessage: String?
    var progress: Double { min(elapsed / Self.duration, 1) }

    private var capture: AudioCapture?

    func record(using models: VoiceModels) async -> (embedding: [Float], speechSeconds: Double)? {
        errorMessage = nil
        guard await AudioCapture.requestPermission() else {
            errorMessage = AudioCapture.CaptureError.permissionDenied.localizedDescription
            return nil
        }
        let capture = AudioCapture()
        let stream: AsyncStream<[Float]>
        do {
            stream = try capture.start()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        self.capture = capture
        state = .recording
        elapsed = 0

        let target = Int(Self.duration * PCM.sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(target)
        for await chunk in stream {
            samples.append(contentsOf: chunk)
            elapsed = Double(samples.count) / PCM.sampleRate
            levels.removeFirst()
            levels.append(PCM.rms(chunk))
            if samples.count >= target { break }
        }
        capture.stop()
        self.capture = nil

        // 途中で「やり直す」が押された
        guard samples.count >= target else {
            state = .idle
            elapsed = 0
            return nil
        }

        state = .processing
        defer { state = .idle }
        do {
            let speech = try await models.speechOnly(samples)
            let speechSeconds = Double(speech.count) / PCM.sampleRate
            guard speechSeconds >= Self.minimumSpeech else {
                errorMessage = "話している部分が\(Int(speechSeconds))秒しか検出できませんでした。静かな場所でもう一度お試しください。"
                return nil
            }
            guard let embedding = try await models.embedding(for: speech) else {
                errorMessage = "声の特徴を計算できませんでした。もう一度お試しください。"
                return nil
            }
            return (embedding, speechSeconds)
        } catch {
            errorMessage = "声の特徴を計算できませんでした：\(error.localizedDescription)"
            return nil
        }
    }

    func cancel() {
        capture?.stop()
        capture = nil
    }
}

struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.tint)
                    .frame(width: 4, height: 4 + CGFloat(min(levels[index] * 12, 1)) * 36)
            }
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}
