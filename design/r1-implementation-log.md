# Fab Tycoon R1 実装ログ（SimCity 式リビルド第 1 弾）

作業ツリー：`~/workspace/projects/fab-tycoon-trackR1`（土台＝trackE：β3＋蛇行テンプレート検証済み）
仕様の正：`design/simcity-rebuild.md`（未決 22 件は全て推奨どおりで確定）
実装方式：Claude Code（Opus）に節ごとのセッションで書かせ、検証はコーディネーターが実施。
push はしていない（本線・他クローン無変更）。

## 1. Claude Code セッション分割

| # | 範囲 | 主な成果 |
|---|---|---|
| 1 | モデル層（§5.4 の R1 分）＋付録 C 文言（指定3件） | `Engine.buyAndPlace`、`buyBlockReason(state:modelId:origin:rotation:)`、`BuyBlockReason.cannotPlace`、`GameState.didShowMapRebuildNotice` |
| 1b | 付録 C 文言の残り | Engine／StatsView／ShopView／LineView／ProcessDetailView のタブ前提語を置換（ContentView:229 の移行告知文だけ対応行が無いため保留 → §5 の申し送り） |
| 2 | GameStore（§5.2 の R1 分） | `selectedToolId`、`buildDrawerTab`、`railMode`、`buyAndPlace` ラッパ、`openBuild(process:)`、`shouldShowWelcomeCard`／`dismissWelcomeCard`。`AppTab`／`selectedTab`／`openShop` を削除 |
| 3 | MapScene（§1・§2・付録 A/B） | FloorGridView のコピーを全画面マップへ作り替え（下記 §2） |
| 4 | HUD／ドック／ContentView（§1.1〜§1.5） | HUDView・DockView 新規、ContentView を MapScene＋HUD＋ドック＋オーバーレイ構成へ全面書き換え、HeaderView 削除 |
| 5 | 建設ドロワー／ToolCard（§2.2〜§2.4） | BuildDrawer・ToolCard 新規 |
| 6 | 問題ポップオーバー／施設シート（§1.3・§1.5・§3.4） | ProblemsPopover・FacilitySheets 新規（EntrySheet／ShippingSheet／WelcomeCardView を含む） |
| 7 | 統合・掃除 | MapScene へ `moveRequest` を追加（長押し持ち上げと共通の `beginLift` に切出し）、LineView から NodeSwitchSheet／DefectAnalysisSheet／EquipmentIllustration／EquipmentPainter／ProcessType 拡張を FacilitySheets へ移設、ScaleNoticeBanner 削除 |
| 8 | HeadlessCheck 追加分 | buyAndPlace 16 件＋v4 固定 JSON 往復 6 件 |

ファイル削除と pbxproj 更新はコーディネーターが機械的に実施（§4）。

## 2. 実装した範囲（設計書の節対応）

- **§1.1 レイヤー構成**：全画面 `MapScene`＋半透明 HUD（56pt）＋ドック（64pt）。フロアはセーフエリア全面。初期ズームは施設帯と隣接区画が収まる倍率（実測相当で約 0.65、§6 の申し送り参照）。ズーム範囲 0.3〜2.0（zoomRange 下限を 0.5→0.3）。
- **§1.2 HUD**：資金／収入・分／ゲーム時計（LineView.clockText を移植）／WPH（`sim.throughputEMA` 実測、タップで実測・理論上限・律速工程をトースト）。右端に 123 トグル（@AppStorage 永続化）と ⚙（SettingsView）。
- **§1.3 施設帯**：フロア北側 y=−3〜−1 に事務所🏢／研究棟🔬／資料室📚 のアイコンプレート＋ライブ表示（事務所：補助金可で「￥」、研究棟：研究中の煙・完了未読で「！」、資料室：解放済み未読の件数バッジ）。タップでシート。投入口／出荷口はフロア内タップで EntrySheet／ShippingSheet。
- **§1.4 ドック**：建設／問題／施設の 3 ボタン＋バッジ（問題はデッドロック／ライン停止で赤、その他は橙。0 件でも常時表示＝決定 #21）。アドバイザーはドック上の吹き出しで 12 秒表示（`.task(id:)` で文言変化時に再表示）、タップで問題ポップオーバー。
- **§1.5 画面遷移**：施設は `.sheet`、フロア上カード（ToolCard／BuildDrawer／ProblemsPopover）は自前オーバーレイで同時 1 枚（優先順：問題→ドロワー→ToolCard）。オフライン報告シートとようこそカードは競合しないよう順序付け。
- **§2.1 ジェスチャ**：モードレス（1 本指パン、タップ選択、ダブルタップでズーム段階循環 0.97→1.5→2.0→0.97）。長押し 0.35 秒で持ち上げ（触覚 .medium）。2 本指パンは UIKit 認識器を自前で付けて実装（§6）。
- **§2.2 配置**：建設ドロワー（購入／倉庫／レール／撤去）。タイルタップ→画面中央にゴースト（snappedOrigin 吸着）→ドラッグ移動→浮動ツールバー（回転／ここに置く（価格）／キャンセル）。購入は確定時に `buyAndPlace` で課金＋配置を 1 トランザクション。倉庫は `placeStoredTool`。ドロワーからマップへのドラッグ持ち出しは未実装（タップ方式のみ、§6）。
- **§2.3 ToolCard**：3 段（コンパクト約 176pt／展開 56%／全画面）、グラバー操作。コンパクト面にサムネ・通し番号・Lv・状態ラベル・待ち FOUP・稼働率・工程順バッジ＋パス数、律速／未接続チップ、ボタン列（改良／移動／回転／倉庫へ／売却（確認文言は旧 sellMessage と同一）／学ぶ）。展開面に工程数値と From→To 全行、「学ぶ」ページ（教育ブロック相当＋図鑑で読む）、全画面段に同工程の他装置リスト。
- **§2.4 移動・回転・撤去**：長押し持ち上げ＋ToolCard「移動」（moveRequest 経由で MapScene の持ち上げを開始）。確定は必ずボタン。回転は ToolCard から即実行＋失敗理由表示。
- **§2.5 レールモード**：唯一のモード。上部モードバー（敷設｜消しゴム／元に戻す（直前ストロークの新規セルを removeRail で除去、1 段）／完了）。レールモード中はポート候補セルを薄青の口で描画（`RailGraph.portCells` が返す既存レール隣接セルに加え、敷設可能な外周セルも表示する拡張あり、§6）。
- **§2.6 区画拡張**：売地看板を常時描画（資金が足りれば黄色、不足なら灰色＋不足額）。タップで既存の購入アラート→ buyParcel。購入時の床アニメ（0.6 秒）は未実装（§6）。
- **§5.2 GameStore**：上記セッション 2 のとおり。R2 分（trackedLotId、activeFieldNote、markFieldNoteSeen、advanceTutorial、pendingFieldNotes 評価）は §6 のフェーズ分けに従い R1 では入れていない。
- **§5.3 セーブ互換**：schemaVersion 4 維持。追加は `didShowMapRebuildNotice` のみ（decodeIfPresent、既定 false）。ようこそカードは旧セーブ読み込み時のみ 1 回（WelcomeCardView、スワイプで閉じられない）。
- **§5.4 モデル追加**：R1 分として `buyAndPlace`、`buyBlockReason(state:modelId:origin:rotation:)`、`BuyBlockReason.cannotPlace(String)` を追加。残りの §5.4 項目（lotProgress、railCongestion、lineBreakAnchors、pendingFieldNotes、tutorialStepSatisfied、fieldNotes、用語 11 語、マイルストーン 7 件、Stats の現場ノート関連）は §6 で R2 の成果物に紐づくため R1 では未実装（「追加のみ」の制約は維持し、既存モデルへの変更は一切なし）。
- **付録 C 文言**：タブ前提語を置換済み（対象はセッション 1／1b の報告どおり）。

## 3. 変更・新規・削除ファイル

変更：
- `FabTycoon/Models/Engine.swift`（buyAndPlace 等の追加、advisorMessage 文言）
- `FabTycoon/Models/GameState.swift`（didShowMapRebuildNotice）
- `FabTycoon/ViewModels/GameStore.swift`（§5.2）
- `FabTycoon/Views/ContentView.swift`（全面書き換え、HeaderView・ScaleNoticeBanner 削除。ResearchView／SettingsView／OfflineReportSheet／BadgeView／MarketCondition 拡張は残置）
- `FabTycoon/Views/StatsView.swift`（付録 C 文言 1 件のみ）
- `HeadlessCheck/main.swift`（末尾に R1 セクション 22 件を追加）
- `FabTycoon.xcodeproj/project.pbxproj`（下記 §4）

新規：
- `FabTycoon/Views/MapScene.swift`（1,988 行。FloorGridView 描画コアの移植＋モードレス化）
- `FabTycoon/Views/HUDView.swift`、`DockView.swift`、`BuildDrawer.swift`、`ToolCard.swift`、`ProblemsPopover.swift`、`FacilitySheets.swift`（EntrySheet／ShippingSheet／WelcomeCardView と、LineView から移設した NodeSwitchSheet／DefectAnalysisSheet／EquipmentIllustration／EquipmentPainter／ProcessType 拡張を含む）
- `HeadlessCheck/fixture-v4.json`（β3 時点の GameState.initial() を iso8601・sortedKeys で書き出した固定フィクスチャ、43KB。新キーを含まない）
- `design/simcity-rebuild.md`（本線からのコピー。設計の正は本線側）

削除：
- `FabTycoon/Views/FloorGridView.swift`（MapScene へ移植済み）
- `FabTycoon/Views/LineView.swift`（分解・移設済み）
- `FabTycoon/Views/ShopView.swift`（建設ドロワーへ）
- `FabTycoon/Views/ProcessDetailView.swift`（ToolCard へ）

## 4. pbxproj の変更

コーディネーターが機械的に実施：
- 削除 4 ファイルの PBXBuildFile／PBXFileReference／グループ子要素／Sources エントリを除去。
- 新規 7 ファイル（MapScene、HUDView、DockView、BuildDrawer、ToolCard、ProblemsPopover、FacilitySheets）に新規 ID（A1…19〜1F／B1…19〜1F）を採番し、4 か所すべてへ登録。
- 検証：ディスク上の全 19 Swift ファイルについて「PBXFileReference がちょうど 1 件」「Sources 言及がちょうど 2 件（BuildFile＋Sources フェーズ）」を全数確認。参照だけ残るゴーストは 0 件。

## 5. 検証結果

- **HeadlessCheck（Swift 6.1.2、-O、Models 7 ファイル＋SaveManager＋main.swift）**：
  - 土台（trackR1 コピー直後）：**555 件全通過**（HEADLESS CHECK PASSED）。
  - R1 統合後：**577 件全通過**（既存 555 件を維持＋R1 追加 22 件：buyAndPlace 成功 7／資金不足 3／配置不可 3／不明モデル 3、v4 固定 JSON 往復 6）。失敗 0 件。ログは `.verify/headless-final.log`（検証後に削除、本ログへ転記）。
  - 既存チェックの判定帯の変更は **なし**（緩和・書き換えゼロ。追加のみ）。
- **View 層の機械チェック**（ローカルで SwiftUI コンパイル不可のため）：
  - 全ファイルの括弧・角括弧バランス：不一致 0 件。
  - 型の重複定義：0 件（削除ファイルの型が残存ファイルと衝突しないことを確認）。
  - 削除した型（FloorGridView、LineView、ShopView、ProcessDetailView、LayoutProblemsSheet、FloorSelection 等）への参照：コメント内のみ、コード参照 0 件。
  - クロスファイルのインターフェース整合：ContentView の MapScene／ToolCard／BuildDrawer／ProblemsPopover／FacilitySheetView／WelcomeCardView の呼び出し形と各定義側の引数順・型を目視＋grep で一致確認。

## 6. 未検証事項と仮置き（実機・Codemagic で確認）

実ビルド（Codemagic）で初めて分かるもの：
- SwiftUI 全体のコンパイル可否（この VM では未検証）。特に MapScene のジェスチャ競合（タップ／ダブルタップ／長押し／パンの同時認識）と 2 本指パンの UIKit 認識器。
- §6.1 の実機判定チェックリスト 12 項目すべて（fps、HUD の収まり、ToolCard の操作感ほか）。

仮置き・設計との差分（判断が必要なら親側で）：
1. **初期ズーム**：施設帯＋隣接区画まで含めると iPhone 15 で約 0.65 になり、§1.1 の例示 0.97（フロア幅のみ）とは異なる。§2.6「初期ズームで隣接区画が少し見える」に寄せた判断。
2. **ポート候補の口**：`RailGraph.portCells` は既存レール隣接セルしか返さないため、敷設可能な外周セルも合わせて描いている（「ここへつなぐ」の意図を優先）。
3. **区画購入の床アニメ**（§2.6 の 0.6 秒）は未実装。
4. **建設ドロワーからマップへのドラッグ持ち出し**（§2.2-1 の後段）は未実装。タップ→中央ゴーストのみ。
5. **ToolCard の未接続チップのタップでポート側を点滅**（§2.3）は MapScene 側の対応が要るため未実装。
6. **資料室の初期エントリ表示**：GlossaryView が内部に NavigationStack を持つため、glossaryTargetId 指定時は 0.35 秒後に GlossaryDetailView を別シートで重ねる方式。見出しが 2 段になる見た目の粗さがある。
7. **ようこそカードの「見て回る」**：ズームアウトして施設帯まで見せるカメラ動作は未実装（閉じるだけ）。
8. **ContentView:229 の移行告知文**（ScaleNoticeBanner の旧文言）：付録 C に対応行が無いため文言は旧 UI 前提のまま残っていたが、R1 で ScaleNoticeBanner 自体を削除したため、この文言はアプリから消えた（ようこそカードが代替）。
9. MapScene の HUD／ドック高さは定数（56pt／64pt）で仮定し、モードバー等の配置に使用。
10. 区画が y>0 から始まる旧セーブでは施設帯と北隣の売地が 3 行重なり、その範囲は施設タップが優先される。

## 7. 申し送り

- R2 着手時は §5.4 の残項目（lotProgress、railCongestion、lineBreakAnchors、pendingFieldNotes、fieldNotes、用語 11 語、マイルストーン 7 件、Stats 追加）を §6 R2 行の HeadlessCheck 追加分とセットで実装すること。
- 実機でジェスチャ競合が出た場合の調整ポイントは MapScene のジェスチャ組み立て部（セッション 3 の報告に詳細）。
- 設計書の正は本線 `~/workspace/projects/fab-tycoon/design/simcity-rebuild.md`。trackR1 内のコピーは作業用。
