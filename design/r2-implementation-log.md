# R2 実装ログ（SimCity式リビルド第2弾：情報の現象化＋学習）

- 作業場所：隔離クローン `~/workspace/projects/fab-tycoon-trackR2`（本線 β4＝コミット b572031 相当のコピー）。本線・他クローンには未変更。push はしていない（親側の担当）。
- 仕様の正：`design/simcity-rebuild.md`。R2 の範囲は §6 の R2 行と対応本文（§3、§4、§5.2、§5.4 の R2 分）。
- 実装分担：Claude Code（Opus）がコードを書き、コーディネーターが節ごとの指示・差分確認・検証を担当（R1 と同じ分担）。
- schemaVersion は 4 のまま維持。

## 実装範囲（設計書の節対応）

### モデル層（§5.4 の R2 分）
- `Catalog.fieldNotes`：現場ノート 16 件（§4.3 の表どおりの順序・見出し・関連用語）。`FieldNoteSpec`／`FieldNoteTrigger`（引数つきケースで閾値を保持）を新設、`Catalog.fieldNote(id:)` を追加。
- 用語 11 語追加（term.lot／foup／amhs／oht／stocker／loadport／wip／cycletime／little／reentrant／conwip）。解放条件は新設の `GlossaryUnlock.fieldNoteSeen`。用語総数 30 → 41。
- マイルストーン 7 件追加（first_rail／first_lot_complete／line_connected／return_lane／no_stall_day／cycle_time_40／second_loop）。総数 14 → 21。新条件 7 種を `MilestoneCondition` に追加し、`milestoneAchieved`／`milestoneProgress`／`milestoneProgressTexts` で評価。
- `Stats` に追加のみ（decodeIfPresent）：`seenFieldNoteIds`、`tutorialStep`（memberwise 既定値 0／デコードでキー無しなら番兵 5＝旧セーブでミッションを出さない）、`noteTriggerMemo`。
- `Engine` 追加：`lotProgress`／`LotProgress`／`LotQualityBand`／`lotQualityBand`、`railCongestion`、`lineBreakAnchors`、`railLoopCount`、`pendingFieldNotes`、`updateFieldNoteMemo`、`fieldNoteTitle`（fn.little のみ実数値化）、`tutorialStepSatisfied`。
- `buyAndPlace` 成功時に fn.not_bottleneck の発生を `noteTriggerMemo["fn.not_bottleneck.at"]` へ記録（旧 `buy` には入れない）。

### GameStore（§5.2 の R2 分）
- 実行時状態：`trackedLotId`、`activeFieldNote`、`placementFeedback`（`PlacementFeedback` 構造体）、`lineEstablishedSignal`。
- `step()` と復帰時の refresh 後に `evaluateR2AfterTick()` を接続：メモ更新 → 現場ノート配信（1 回の評価で最大 1 件、fn.reentrant は追跡ロットの passNumber >= 2 で最優先）→ ミッション自動進行 → ライン成立検出。
- `buyAndPlace`／`placeStoredTool` 成功時に配置フィードバック（接続可否・ライン WPH 前後）を記録。`resetGame()` でも R2 実行時状態を初期化（申し送り対応）。

### 現象化（§3、MapScene）
- 熱色レール（railCongestion、2〜3 黄／4〜5 橙／6+ 赤）、ストッカー充填メーター（90% 橙・満杯で赤点滅）、排出中プレート（ノード切替中）、投入停止プレート（ストッカー満杯）。
- 切断プラグ（未接続装置、1 秒周期点滅のピクセル絵）、律速看板、寸断矢印（lineBreakAnchors、赤点線＋✗）、デッドロック ビネット（1.5 秒周期脈動）。
- 検査装置の「！」（異常発生中）、原因ランプのヒント段階連動（hintsRevealed >= 3 かつ稼働中 Q3 がある場合のみ赤。MapScene の FloorDrawData と ToolCard のステータス判定の両方を同条件に統一）。
- FOUP 品質帯（赤帯／緑帯）、停止 FOUP の砂時計を絵文字からドット絵風の手続き描画へ差し替え、追跡 FOUP の黄輪郭。
- 配置直後フラッシュ（白枠 2 回点滅）＋「接続 OK」チップとライン WPH 増分の表示（ContentView、3 秒）。
- 123 オーバーレイの描画本体（装置の稼働%｜待 n、ストッカー n/cap、投入口 WIP n/cap、出荷口 在庫）。トグルは R1 既存の HUD 側 `showNumbers` を MapScene へ配線。

### 学習（§4）
- 現場ノート：トースト（8 秒→自動消去、タップで展開、関連図鑑チップ）＝新規 `FieldNoteToast.swift`。資料室
...[truncated 6158 chars]