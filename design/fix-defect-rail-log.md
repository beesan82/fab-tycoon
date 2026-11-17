# 不具合修正ログ：欠陥分析の導線復旧＋原因工程のヒント連動＋レール誤タップ防止

- 実施日：2026-11-16
- 作業場所：隔離クローン `~/workspace/projects/fab-tycoon-trackFIX`（本線 9f8b2fc 相当のコピー。本線・他クローンは無変更、push なし）
- 実装：Claude Code（Opus）に書かせ、コーディネーターが差分確認・検証
- 前提資料：design/gap-analysis-2026-11-16.md（Fable 5.2 乖離分析）§4・§5
- ユーザー承認：2026-11-16、12/1 の (22) ビルドへの同梱を承認済み
- 変更ファイルは **3ファイルのみ**（いずれも Views）。新規ファイルなし、モデル層・ViewModels・HeadlessCheck は無変更

## 修正1：欠陥分析シートの導線復旧

### 問題
- `DefectAnalysisSheet`（FacilitySheets.swift:869）は定義のみで、Views／ViewModels 全体に生成・表示箇所が **0件**だった。
- アドバイザー（Engine.swift:2468「検査装置をタップして欠陥分析を開いて…」）、StatsView の案内文、ProblemsPopover.swift:160 のコメント（「欠陥分析は検査装置の ToolCard から開く」）はすべてこの導線の存在を前提にしていたが、ToolCard にボタンが無かった。
- ヒント開示（`revealExcursionHint`）と対策実行（`applyExcursionCountermeasure`）はこのシート経由でしか呼べず、異常の終了経路は対策の成功だけ（Engine.swift:1969-1977、時間経過では消えない）。つまり一度発生すると永久に解消できなかった。

### 実装（ToolCard.swift）
- `@State private var showsDefectAnalysis` を追加し、`card(_:)` のルートに `.sheet(isPresented:) { DefectAnalysisSheet()}` を付けた。
- `actionRow(_:)`（コンパクト段でも常時見える最下段のボタン列）の先頭に、検査工程の装置（`info.model.process ==.inspection`）のときだけ「欠陥分析を開く」ボタン（systemImage: waveform.path.ecg、既存ボタンと同じ `actionLabel` 様式）を追加。
- 異常発生中（`store.state.activeExcursion!= nil`）は `.borderedProminent`、通常時は `.bordered` にする `DefectAnalysisButtonStyle`（private な ViewModifier を同ファイル末尾に追加。buttonStyle の型が異なるための分岐集約で、新規ファイルは作っていない）。
- DefectAnalysisSheet 本体は無変更（未発生時の「現在、歩留まり異常は発生していません。」表示はもともと持っている）。

### 判断した点
- **ボタンの置き場所は processSection ではなく actionRow**。processSection は展開段でしか見えず、アドバイザーに誘導されたプレイヤーが検査装置をタップした直後（コンパクト段）にボタンが見えないと導線にならないため。
- **ボタンは異常の有無にかかわらず検査装置に常時表示**。シート側に未発生時の表示が用意されている＝いつでも開ける設計が既存の前提であり、発生中だけ出すと「普段は無いボタン」になって発見性が落ちるため。発生中は Prominent で目立たせるに留めた。
- 分析 §5 の改善案にあった「問題ポップオーバーの異常行にも同じ入口」は**入れていない**。指示が「既存の案内文が指している導線そのものを実装する（新しい導線を発明しない）」であり、ポップオーバーの「見る」は既に検査装置へフォーカスする（＝ToolCard が開く）ため、ToolCard 側の復旧で案内文の指す経路は完全に繋がる。追加の入口が欲しいかは要判断として申し送る。

### 解消までのモデル経路の確認（静的＋既存チェック）
UI から解消まで一続きに繋がることを確認した：
1. 検査装置タップ → ToolCard →「欠陥分析を開く」→ DefectAnalysisSheet
2. シート「さらに分析する」→ `GameStore.revealExcursionHint()` → `Engine.revealExcursionHint`（費用を払い `hintsRevealed` +1、上限3）
3. シート「対策を実行する」→ `GameStore.applyExcursionCountermeasure(_:)` → `Engine.applyExcursionCountermeasure`（原因工程なら `activeExcursion = nil`、`excursionsResolved` +1、クールダウン設定、`.resolved` を返しシートは「解決しました」表示へ）
- このモデル経路自体は HeadlessCheck の既存チェックで担保されている（強制発生→ヒント1〜3段階と上限→別工程対策は `.wrongProcess`→原因工程で `.resolved`→異常なしでは `.noActiveExcursion`、HeadlessCheck/main.swift:734-787）。欠けていたのは UI 導線だけだった。

### 導線の機械確認（grep 証拠）
修正前（本線）― `DefectAnalysisSheet` の出現は定義のみ：
```
FabTycoon/Views/FacilitySheets.swift:869:struct DefectAnalysisSheet: View {
```
修正後（trackFIX）― 定義＋生成箇所1件：
```
FabTycoon/Views/FacilitySheets.swift:869:struct DefectAnalysisSheet: View {
FabTycoon/Views/ToolCard.swift:127: DefectAnalysisSheet()
```

## 修正2：事務所の「原因工程」表示をヒント段階に連動

**保留ではなく実施した。** ヒント段階のモデルは既に存在した（`ActiveExcursion.hintsRevealed`、0〜3）ため、発明は不要だった。

### 問題
- StatsView「歩留まり」セクション冒頭が、異常発生直後から `derived.excursionProcess`（＝本当の原因工程）を「原因工程：○○」と名指ししており、設計（simcity-rebuild §7-13「ヒント3段階＋Q3で初めて原因が分かる」）の推理を潰していた。`derived.excursionProcess` の表示箇所は StatsView のここだけ（grep で確認）。

### 実装（StatsView.swift）
- 異常の発生表示そのものは従来どおり `activeExcursion!= nil` の間つねに出す。
- 「（原因工程：○○）」は、**欠陥分析シートが原因を明かす条件と同一条件**（`excursion.hintsRevealed >= 3 && Engine.bestInspectionGrade(state:) == 3`、FacilitySheets.swift の hintSection と同じ式）のときだけ付ける。
- 条件未達の間は工程名を出さず「歩留まり異常が発生中です。検査装置をタップして欠陥分析を開いて、原因を特定しましょう。」（アドバイザー文言と同旨）。
- DerivedState・Engine は無変更（隠すのは表示だけ。モデル層の `excursionProcess` 自体は HeadlessCheck でも検証される派生値として維持）。

### 判断した点
- 特定条件にシート側の式をそのまま使った。ToolCardInfo／FloorDrawData の原因ランプも「ヒント3段階＋Q3」で点灯する同趣旨の条件であり、アプリ内で「原因が分かる瞬間」の定義が1つに揃う。
- ヒント1段階以降にシート内で見える「候補工程」は StatsView には出していない（候補の開示場所はシート、という従来の役割分担を維持。事務所は発生の通知と、特定済みの場合の再掲まで）。

## 修正3：レール誤タップ（向き変更）の防止

### 問題
- 敷設ツール（.draw）で既存レールをタップすると向きが時計回りに変わっていた（MapScene.swift `railTap`、無言・無償・確認なし）。
- なぞり敷設の計画（`plannedRailCells`）も、始点の同軸逆方向・中間の通過／折れ曲がりで既存セルの `direction` を上書きしていた。
- 「元に戻す」（`undoLastStroke`）が覚えるのは新規セルだけなので、これらの変更は取り消せなかった。
- なお RailCard には向き変更ボタンは**存在しない**（確認済み）。タップ回転が唯一のその場変更手段だった。

### 実装（MapScene.swift）
- `railTap` の `.draw`：既存レールのあるセルでは**何もしない**（回転なし・setRail なし・メッセージなし）。空きセルに東向きで敷く挙動は従来どおり。
- `plannedRailCells`：既存セルについて `direction` への代入を全廃した。
- 終点：従来どおり触らない。
- 始点：同方向はスキップ（従来どおり）。直交方向へ出る場合は `kind =.branch` 変換のみ（direction は既存のまま）。同軸の逆方向はセル自体を結果に含めない（従来は反転していた）。
- 中間：直交に横切る場合は `kind =.cross` 変換のみ（direction は既存のまま）。それ以外（同方向・逆方向の通過、折れ曲がり）はセル自体を結果に含めない（従来は direction を上書きしていた。同方向通過で branch／cross の kind が.straight に戻されることもあったが、それも無くなる）。
- 既存でないセルの計画ロジックは一切変更なし。
- 案内文（`railStatus` の.draw 用テキスト）から「、タップで向きを回す」を削除し、「既存レールの向きはタップでは変わりません。」に差し替えた（この文言が残っていると嘘の案内になるため必須の追随）。
- `commitStroke`／`undoLastStroke` は無変更（元々、新規セルだけが課金・取り消しの対象で、今回の変更と整合する）。

### 判断した点・残る正規手段
- 対象は「向き（direction）」の保護に限定した。branch／cross への kind 変換は、既存レールへ接続するための設計された接合処理（分岐・交差）であり、向きを変えないので残した。
- 向きを変えたい場合の正規手段は残っている：撤去ツールで消して敷き直す（購入セルは全額返金される仕様）。その場回転の利便性は失われるが、誤操作で本線が壊れる穴を塞ぐことを優先した（分析 §4 の改善案の第一選択肢どおり）。

## 検証結果

1. **HeadlessCheck**（Swift 6.1.2、`swiftc -O`、Models 全ファイル＋SaveManager＋HeadlessCheck/main.swift）
- 修正前（クローン素の状態）：コンパイル成功、**886件全通過・HEADLESS CHECK PASSED**
- 修正後：最終的に **886件全通過・HEADLESS CHECK PASSED** を確認（件数の増減なし＝新規チェック追加なし、判定帯の変更なし）。ただし当日夜は VM が極端に混雑し、確定までに以下の経過があった（いずれも変更起因ではない）：
  - 1回目：849件 OK の後、R3 性能チェックで停止（1 tick 平均 294.025ms ≥ 予算 250ms）。当夜の負荷による揺れ
  - 2回目：13件 OK の後、既知フレーク「D1 価格 8億円が引かれた」で停止（設備割引イベントのランダム発生による既存の非決定性。trackLINE でも記録済み）
  - 3回目：コンパイル成功後、実行中にランタイム再起動で中断（結果不明、/tmp の成果物も消去）
  - 4回目：出力先を workspace（~/workspace/projects/trackFIX-verify/run4.log）に変えて実行し、**886件全通過・HEADLESS CHECK PASSED**（実行シェルの読み戻しで確認。なお workspace 側に同期された run4.log のコピーは 4,096 バイトで切れており全文は残っていない）
- 構造的な裏付け：変更は Views のみで、HeadlessCheck のコンパイル入力（Models＋SaveManager＋HeadlessCheck）は修正前後でバイト単位で同一。よって修正後バイナリはベースラインと同一であり、上記の失敗2件が変更に起因しないことは確定している。
2. **View 層メンバー参照スイープ**（DT トラックの方式を再現した機械照合：Views／ViewModels の `store.*`・`store.state.*`・`state.*`・`derived.*`・`excursion.*`・`info.*` と型チェーンを実在メンバーと照合）
- 照合 **442件・不一致 0件**
- 負テスト：β5 の実バグ `store.state.inventoryChips` を一時混入させると正しく検出できることを確認（混入は検証用コピー上のみ、実ファイル無変更）
3. **導線の機械確認**：上記「修正1」に grep 証拠を掲載（修正前 生成0件 → 修正後 ToolCard.swift:127 に生成あり）。
4. **pbxproj 全数照合**：FabTycoon 配下の全 23 Swift ファイルが project.pbxproj に登録済み（未登録 0件）。新規ファイルなしのため pbxproj は本線と一致。
5. **構文パース**：全 Swift ファイル（FabTycoon 23＋HeadlessCheck 1）に `swiftc -parse` 無エラー。
6. **差分範囲**：本線との diff は ToolCard.swift／StatsView.swift／MapScene.swift の3ファイルのみ。他はバイト一致。

## 未検証・申し送り
- SwiftUI の実コンパイルと実機表示はこの VM では未検証（従来どおり Codemagic 実ビルド＋実機判定が最終確認）。特に ToolCard の `.sheet` はカード表示中のみ有効な点、異常発生中に実機で「検査装置タップ→ボタン→シート→ヒント→対策→解消」まで通す確認は (22) 配信後にお願いしたい（チェックリスト R2-8 の判定に直結）。
- 問題ポップオーバーへの欠陥分析の直接入口は入れていない（上記「修正1 判断した点」参照）。欲しければ別途。
- `plannedRailCells` の kind 変換は、既存セルが既に.cross の場合に始点で.branch へ書き換わる等の既存挙動を温存している（向きは不変。今回の対象外として触っていない）。
- レール敷設そのものの確定方式（指を離して確定・課金）は分析 §4 で別件として挙がっているが、今回の指示対象外のため無変更。
