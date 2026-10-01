import Foundation

nonisolated enum SpeakerLabel: Hashable, Sendable {
    case me
    case other(Int)
    case unknown

    var displayName: String {
        switch self {
        case .me: "自分"
        case .other(let index): "他人" + Self.letter(index)
        case .unknown: "不明"
        }
    }

    private static func letter(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < letters.count ? String(letters[index]) : "\(index + 1)"
    }
}

/// 発話ごとの声の特徴（埋め込み）を、登録済みの自分の声・これまでの他人と比べてラベルを付ける。
nonisolated struct SpeakerIdentifier: Sendable {
    struct Decision: Sendable, Equatable {
        let label: SpeakerLabel
        /// 自分の声とのコサイン類似度（PoCでのしきい値調整用）
        let similarityToMe: Float
    }

    /// これ以上なら「自分」。PoCの実測で調整する
    var meThreshold: Float = 0.5
    /// これ以上なら既存の他人と同一人物とみなす
    var otherThreshold: Float = 0.45
    /// これより短い発話からは新しい他人を作らない（秒）
    var minSecondsForNewSpeaker: Double = 1.0

    private let me: [Float]
    private var others: [(centroid: [Float], count: Int)] = []

    init(me: [Float]) {
        self.me = Self.normalized(me)
    }

    mutating func identify(_ embedding: [Float], seconds: Double) -> Decision {
        let embedding = Self.normalized(embedding)
        let toMe = Self.cosine(embedding, me)
        if toMe >= meThreshold {
            return Decision(label: .me, similarityToMe: toMe)
        }

        let best = others.indices
            .map { ($0, Self.cosine(embedding, others[$0].centroid)) }
            .max { $0.1 < $1.1 }
        if let (index, similarity) = best, similarity >= otherThreshold {
            // 重心を少しずつ更新して、同じ人の声の揺れに追従する
            let count = others[index].count
            let merged = zip(others[index].centroid, embedding).map { ($0 * Float(count) + $1) / Float(count + 1) }
            others[index] = (Self.normalized(merged), count + 1)
            return Decision(label: .other(index), similarityToMe: toMe)
        }

        guard seconds >= minSecondsForNewSpeaker else {
            return Decision(label: .unknown, similarityToMe: toMe)
        }
        others.append((embedding, 1))
        return Decision(label: .other(others.count - 1), similarityToMe: toMe)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-9 else { return v }
        return v.map { $0 / norm }
    }

    /// 複数の埋め込みを平均して1つの声紋にする
    static func average(_ embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for e in embeddings.map(normalized) where e.count == sum.count {
            for i in sum.indices { sum[i] += e[i] }
        }
        return normalized(sum)
    }
}
