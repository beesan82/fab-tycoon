# Fab Tycoon（仮）

半導体ファブを経営する iOS 向け放置系タイクーンゲームの試作です。設計の正は [DESIGN.md](DESIGN.md)。
このリポジトリは **スライス1**（28nm ライン1本を回す最小ループ）の実装です。

- SwiftUI / iOS 17 以降 / 外部依存なし
- Bundle ID: `com.fabtycoon.app`
- 通貨はすべて日本円（設計書の「G」は 1G = 100万円 で換算済み）

## 開き方

1. Xcode 15 以降で `FabTycoon.xcodeproj` を開く
2. スキーム `FabTycoon` を選び、iPhone シミュレータで Run
3. 実機で動かす場合は Signing & Capabilities で自分の Team を設定する

Codemagic / TestFlight 連携は次の段階で設定します（AppIcon は現在空なので、TestFlight 提出前に 1024×1024 の画像を入れる必要があります）。

## ディレクトリ構成

```
FabTycoon/
  FabTycoonApp.swift        エントリポイント（scenePhase を GameStore に転送）
  Models/                   Foundation のみ（SwiftUI 非依存）
    Catalog.swift           工程・ノード・装置モデルのカタログ
    GameState.swift         セーブ対象の状態（Codable）
    Engine.swift            派生値計算・tick・オフライン・売買（純粋関数）
    MoneyFormat.swift       円・個数・時間のフォーマッタ
  Persistence/SaveManager.swift   Documents/fabtycoon-save.json へ保存
  ViewModels/GameStore.swift      ObservableObject。0.25秒 Timer で tick、5秒ごと保存
  Views/                    ContentView / LineView / ProcessDetailView / ShopView / StatsView
HeadlessCheck/main.swift    エンジンのヘッドレス検証（Xcode ターゲット外）
```

## ヘッドレス検証（Linux / macOS）

モデル層は Foundation のみに依存するため、Swift ツールチェーンだけでコンパイルして検証できます。

```sh
swiftc FabTycoon/Models/Catalog.swift FabTycoon/Models/GameState.swift \
       FabTycoon/Models/Engine.swift HeadlessCheck/main.swift -o /tmp/fab-headless
/tmp/fab-headless   # 最後に "HEADLESS CHECK PASSED" が出れば成功、失敗時は exit 1
```

内容：初期状態の派生値表示 → 0.25秒×2400 tick（実10分）→ 生産・売上・資金増加のチェック → D1 購入でラインWPH上昇の確認 → オフライン進行（1時間不在）の確認。

## スライス1で動く範囲

- 28nm ライン1本（第1ファブ、12スロット）。初期資金 30億円、初期装置 L1×2 / D1×2 / E1×3 / I1×1 / C1×1 / Q1×1 / P1×1
- リアルタイム進行（実1秒 = ゲーム内10分）。工程WPH・ラインWPH・ボトルネック/次点の算出
- 歩留まり学習（累計投入ウェハによる指数カーブ＋検査装置ボーナス）
- 市況：週次サイクル（±30%）＋ゲーム内1時間ごとのランダムウォーク（0.6〜1.5）
- 売上原価の控除（製品別の原価率 45〜55% を売上から差し引いて入金。市場不良ペナルティは売上ベースで計算）
- 自動販売 ON/OFF、在庫（上限 10,000個、超過分は自動売却）、一括売却
- 装置の購入・改良（Lv1〜5）・売却、購入/改良後ラインWPHのプレビュー
- ショップの工程フィルタ、ロック表示（対応ノード外 / 研究が必要）、購入不可理由（資金不足 / スロット不足）
- セーブ/ロード（5秒ごと＋バックグラウンド移行時）、オフライン進行（上限4時間・効率50%・価格固定）と簡易おかえりシート
- 統計画面（累計売上・投入ウェハ・良品・欠陥と損失額・プレイ時間・現在値）

## TODO（スライス2以降）

- 研究ツリー（液浸露光機 / EUV露光 / High-NA EUV / EB検査装置 / 先端パッケージ ほか）
- 第2ファブ
- 特需イベント
- 市場グラフ
- ノード進行（14nm〜2nm）
- ノード移行シート
- おかえりシートの本実装
- チュートリアル
- 設定画面
- サウンド / 通知

## 既知の設計解釈メモ

- **改良費** は「モデル価格 × 20% × 現在Lv」と解釈（Lv5 は改良不可）。
- **売却返金** はモデル価格の 50%。改良に投じた費用は戻らない。
- **稼働率 85%** を式どおり工程WPHに適用しているため、初期ラインWPH は約 **8.5**（成膜 2台 × 100 ÷ 20パス × 0.85）。設計書 5.1 の「8.5」も稼働率適用後の値。
- 装置の「1台あたり実効WPH」表示は稼働率適用前の値（公称WPH × Lv補正 ÷ パス数）。工程カードの WPH は稼働率適用後。
- 露光のパス数は、稼働中の露光機のうち最上位の露光クラスに対する上書き値（例：7nm の EUV は 35パス）があればそれを工程全体に使う。
- スライス1では対応ノード外の装置・研究が必要な装置は購入不可（Engine.buy でも弾く）。
- 市況ラベルは cycleFactor × walkFactor が 1.1 以上で「好況」、0.9 以下で「不況」、それ以外「平常」。
- オフライン処理（起動時・フォアグラウンド復帰時）は 60秒超の不在が対象。60秒以下の中断は通常速度で一括 tick して追いつく。
- **SWIFT_VERSION は 5.0** を設定（Xcode の SWIFT_VERSION は言語モード指定で 4 / 4.2 / 5 / 6 のみ受け付け、`5.9` はエラーになるため）。コードは Swift 5.9 コンパイラ（Xcode 15）で通る書き方にしている。
- 起動画面は `INFOPLIST_KEY_UILaunchScreen_Generation = YES` で空の UILaunchScreen を生成（これが無いとレターボックス表示の互換モードになる）。
