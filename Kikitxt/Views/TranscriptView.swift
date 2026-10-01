import SwiftUI

/// 録音開始／停止と、確定した文の時刻・話者付き表示。
struct TranscriptView: View {
    let models: VoiceModels
    let locale: Locale
    let myVoice: [Float]

    @State private var session = TranscriptSession()
    @State private var showsEnrollment = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            transcript
            recordButton
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("声を登録し直す", systemImage: "waveform.badge.mic") { showsEnrollment = true }
                        .disabled(session.isRecording)
                    Button("表示を消去", systemImage: "trash") { session.clear() }
                        .disabled(session.isRecording)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsEnrollment) {
            EnrollmentView(models: models) { showsEnrollment = false }
        }
        .onDisappear { session.stop() }
    }

    private var statusBar: some View {
        HStack {
            if session.isRecording {
                Label {
                    Text("録音中 \(Text(session.startDate ?? .now, style: .timer))")
                } icon: {
                    Circle().fill(.red).frame(width: 8, height: 8)
                }
                Spacer()
                Label(session.isSpeaking ? "発話あり" : "無音", systemImage: session.isSpeaking ? "waveform" : "pause")
                    .foregroundStyle(session.isSpeaking ? .primary : .secondary)
            } else {
                Text("停止中")
                Spacer()
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(session.lines) { line in
                    TranscriptRow(line: line, decision: session.speakers[line.segmentID])
                }
                if !session.volatileText.isEmpty {
                    Text(session.volatileText)
                        .foregroundStyle(.tertiary)
                        .id("volatile")
                }
                if let message = session.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .listStyle(.plain)
            .overlay {
                if session.lines.isEmpty && session.volatileText.isEmpty && !session.isRecording {
                    ContentUnavailableView("録音を始めましょう", systemImage: "mic",
                                           description: Text("話した内容が、時刻と話者付きでここに表示されます。"))
                }
            }
            .onChange(of: session.lines.count) {
                if let last = session.lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var recordButton: some View {
        Button {
            if session.isRecording {
                session.stop()
            } else {
                Task { await session.start(models: models, locale: locale, myVoice: myVoice) }
            }
        } label: {
            ZStack {
                Circle().strokeBorder(.secondary, lineWidth: 3).frame(width: 68, height: 68)
                if session.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 26, height: 26)
                } else {
                    Circle().fill(.red).frame(width: 54, height: 54)
                }
            }
        }
        .accessibilityLabel(session.isRecording ? "録音を停止" : "録音を開始")
        .padding(.vertical, 12)
    }
}

private struct TranscriptRow: View {
    let line: TranscriptSession.Line
    let decision: SpeakerIdentifier.Decision?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.date, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Text(decision?.label.displayName ?? "…")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(decision?.label == .me ? Color.accentColor : .secondary)
                    .background(decision?.label == .me ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12),
                                in: .rect(cornerRadius: 6))
                // PoC：しきい値調整のため、自分の声との類似度を表示する
                if let decision {
                    Text(decision.similarityToMe, format: .number.precision(.fractionLength(2)))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Text(line.text)
        }
    }
}

@Observable
final class TranscriptSession {
    struct Line: Identifiable {
        let id: UUID
        let segmentID: Int
        let date: Date
        let text: String
    }

    private(set) var lines: [Line] = []
    private(set) var speakers: [Int: SpeakerIdentifier.Decision] = [:]
    private(set) var volatileText = ""
    private(set) var isRecording = false
    private(set) var isSpeaking = false
    private(set) var startDate: Date?
    private(set) var errorMessage: String?

    private var capture: AudioCapture?
    private var runTask: Task<Void, Never>?
    /// 区間IDは録音ごとに0から振り直されるため、過去の録音分とずらす
    private var segmentOffset = 0

    func start(models: VoiceModels, locale: Locale, myVoice: [Float]) async {
        guard !isRecording else { return }
        errorMessage = nil
        guard await AudioCapture.requestPermission() else {
            errorMessage = AudioCapture.CaptureError.permissionDenied.localizedDescription
            return
        }
        let capture = AudioCapture()
        let audio: AsyncStream<[Float]>
        do {
            audio = try capture.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let start = Date.now
        let transcriber = LiveTranscriber(models: models, myVoice: myVoice, locale: locale, startDate: start)
        self.capture = capture
        startDate = start
        isRecording = true
        segmentOffset = (lines.map(\.segmentID).max() ?? -1) + 1

        let offset = segmentOffset
        Task.detached { await transcriber.run(audio: audio) }
        runTask = Task {
            for await event in transcriber.eventStream {
                apply(event, offset: offset)
            }
            isRecording = false
            isSpeaking = false
            volatileText = ""
        }
    }

    func stop() {
        capture?.stop()
        capture = nil
    }

    func clear() {
        lines = []
        speakers = [:]
        errorMessage = nil
    }

    private func apply(_ event: LiveTranscriber.Event, offset: Int) {
        switch event {
        case .line(let id, let segmentID, let date, let text):
            lines.append(Line(id: id, segmentID: segmentID + offset, date: date, text: text))
        case .volatile(let text):
            volatileText = text
        case .speaker(let segmentID, let decision):
            speakers[segmentID + offset] = decision
        case .speaking(let speaking):
            isSpeaking = speaking
        case .failure(let message):
            errorMessage = message
        }
    }
}
