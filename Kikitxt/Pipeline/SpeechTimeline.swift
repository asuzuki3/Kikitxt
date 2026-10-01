import Foundation

/// 文字起こしエンジンには発話区間の音声だけを詰めて渡すため、
/// エンジン側の時刻（発話だけをつないだ時間軸）と録音側の時刻・発話区間を対応づける。
nonisolated struct SpeechTimeline: Sendable {
    struct Segment: Sendable, Equatable {
        let id: Int
        /// 録音開始からのサンプル位置
        let captureStart: Int
        /// エンジン側時間軸でのサンプル位置
        let feedStart: Int
        var feedEnd: Int?
    }

    private(set) var segments: [Segment] = []

    mutating func begin(id: Int, captureStart: Int, feedStart: Int) {
        segments.append(Segment(id: id, captureStart: captureStart, feedStart: feedStart))
    }

    mutating func end(id: Int, feedEnd: Int) {
        guard let index = segments.lastIndex(where: { $0.id == id }) else { return }
        segments[index].feedEnd = feedEnd
    }

    /// エンジン側のサンプル位置を含む発話区間（境界の外なら直前の区間）
    func segment(atFeedSample sample: Int) -> Segment? {
        segments.last { $0.feedStart <= sample } ?? segments.first
    }

    /// エンジン側のサンプル位置を、録音開始からのサンプル位置に変換する
    func captureSample(forFeedSample sample: Int) -> Int? {
        guard let segment = segment(atFeedSample: sample) else { return nil }
        return segment.captureStart + max(0, sample - segment.feedStart)
    }
}
