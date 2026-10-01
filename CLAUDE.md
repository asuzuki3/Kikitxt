# kikitxt — Claude Code 作業ルール

自分の声と日常会話をiPhone上で文字起こしし、Obsidianに日次で蓄積するiOSアプリ。仕様は [SPEC.md](SPEC.md) を正とする。

## 技術方針

- 言語：Swift 6 / SwiftUI。最小iOS：26.0
- 文字起こし：Speech フレームワークの SpeechAnalyzer + SpeechTranscriber（locale: ja-JP）。旧 SFSpeechRecognizer は使わない
- 話者判別・VAD：FluidAudio（Swift Package Manager）。これ以外の外部ライブラリは追加前に必ず相談
- 永続化：SwiftData
- 非同期処理は async/await と Swift Concurrency で書く

## 守ること

- 音声データ・文字起こし結果を端末の外へ送信するコードを書かない（Claude連携は別フェーズ）
- APIキーや個人情報をコードに埋め込まない
- 電力を意識する：無音区間では文字起こし・話者判別を動かさない
- 権限（マイク、音声認識）の説明文は Info.plist に日本語で書く
- 1回の変更は小さく。変更後は xcodebuild でビルドが通ることを確認してから報告する
- マイク・SpeechTranscriber・声紋判別はシミュレータで動かないため、実機で確認すべき点は報告の最後に箇条書きで示す

## 進め方

- SPEC.md の「開発ステップ」の順に進める（PoC → MVP → 要約連携 → 検索）
- 仕様に無い判断が必要なときは、実装前に選択肢を示して確認する
- UI文言・コメント・報告は日本語

## ビルド確認

```bash
xcodebuild -project Kikitxt.xcodeproj -scheme Kikitxt -destination 'generic/platform=iOS Simulator' build
```
