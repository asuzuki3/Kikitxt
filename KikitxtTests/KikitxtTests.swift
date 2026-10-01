//
//  KikitxtTests.swift
//  KikitxtTests
//
//  Created by SUZUKI Akinori on 2026/10/01.
//

import Testing
@testable import Kikitxt

struct SpeakerIdentifierTests {
    private let me: [Float] = [1, 0, 0]
    private let personA: [Float] = [0, 1, 0]
    private let personB: [Float] = [0, 0, 1]

    @Test func 自分の声に近ければ自分と判定する() {
        var identifier = SpeakerIdentifier(me: me)
        let decision = identifier.identify([0.9, 0.1, 0], seconds: 2)
        #expect(decision.label == .me)
        #expect(decision.similarityToMe > 0.9)
    }

    @Test func 他人は登場順にAとBを振り同じ人には同じラベルを付ける() {
        var identifier = SpeakerIdentifier(me: me)
        #expect(identifier.identify(personA, seconds: 2).label == .other(0))
        #expect(identifier.identify(personB, seconds: 2).label == .other(1))
        #expect(identifier.identify([0.05, 0.95, 0.05], seconds: 2).label == .other(0))
    }

    @Test func 短すぎる発話からは新しい他人を作らない() {
        var identifier = SpeakerIdentifier(me: me)
        #expect(identifier.identify(personA, seconds: 0.5).label == .unknown)
        #expect(identifier.identify(personA, seconds: 2).label == .other(0))
    }

    @Test func ラベルの表示名() {
        #expect(SpeakerLabel.me.displayName == "自分")
        #expect(SpeakerLabel.other(0).displayName == "他人A")
        #expect(SpeakerLabel.other(1).displayName == "他人B")
        #expect(SpeakerLabel.unknown.displayName == "不明")
    }

    @Test func 平均した声紋は正規化される() throws {
        let averaged = try #require(SpeakerIdentifier.average([[2, 0], [0, 2]]))
        #expect(abs(SpeakerIdentifier.cosine(averaged, averaged) - 1) < 1e-5)
    }
}

struct SpeechTimelineTests {
    @Test func 発話だけをつないだ時刻を録音時刻と区間に戻す() throws {
        var timeline = SpeechTimeline()
        // 1つ目の発話：録音1秒目から2秒間
        timeline.begin(id: 0, captureStart: 16_000, feedStart: 0)
        timeline.end(id: 0, feedEnd: 32_000)
        // 2つ目の発話：録音10秒目から
        timeline.begin(id: 1, captureStart: 160_000, feedStart: 32_000)

        #expect(timeline.segment(atFeedSample: 8_000)?.id == 0)
        #expect(timeline.captureSample(forFeedSample: 8_000) == 24_000)
        #expect(timeline.segment(atFeedSample: 40_000)?.id == 1)
        #expect(timeline.captureSample(forFeedSample: 40_000) == 168_000)
    }

    @Test func 区間がなければnil() {
        #expect(SpeechTimeline().segment(atFeedSample: 0) == nil)
    }
}
