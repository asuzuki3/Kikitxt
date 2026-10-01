import Foundation
import SwiftData

/// 登録済みの自分の声紋。端末内にのみ保存する。
@Model
final class VoiceProfile {
    var embedding: [Float]
    /// 登録時に使った発話の長さ（秒）
    var speechSeconds: Double
    var createdAt: Date

    init(embedding: [Float], speechSeconds: Double, createdAt: Date = .now) {
        self.embedding = embedding
        self.speechSeconds = speechSeconds
        self.createdAt = createdAt
    }
}
