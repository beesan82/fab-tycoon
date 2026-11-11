# P6 実装ログ（特需イベント＋期間P&L＋経済バランス最終調整）

- 作業日：2026-11-11
- 作業ツリー：`~/workspace/projects/fab-tycoon-trackP6`（本線 RC = コミット 3a97adc 相当のコピー。本線・他クローンは無変更、push なし）
- 実装：Claude Code（Opus）全4セッション＋コーディネーターのマイクロ修正3件（OfflineProgress のコメント2件、HUD の残り分表示の切り上げ化）
- 仕様の正：プロジェクト直下 `DESIGN.md` §2.5／§5、`design/improvement-analysis-2026-11-07.md` の特需イベント行
- 対象外の確認：装置の故障・保守／維持費は DESIGN §4.2「v1では作らないもの」のため実装していない

## 1. 特需イベント（DESIGN §2.5）

### カタログ（Catalog.marketEvents、7種）

| id | 名前 | 効果 | 対象ノード | 発生条件 | 継続（実時間） | 重み |
|---|---|---|---|---|---|---|
| ev.ai_boom | AIブーム | 単価 ×2.0 | n7/n5/n3/n2 | n7 到達後 | 1380秒（23分） | 1.0 |
| ev.game_console | ゲーム機ブーム | 単価 ×1.8 | n28/n14 | 常時 | 1080秒（18分） | 1.0 |
| ev.automotive | 車載増産 | 単価 ×1.6 | n28 | 常時 | 2400秒（40分） | 1.0 |
| ev.smartphone | スマホ新機種 | 単価 ×1.5 | n5/n3 | n5 到達後 | 840秒（14分） | 1.0 |
| ev.oversupply | 在庫過剰 | 単価 ×0.6 | 全ノード | 常時 | 840秒（14分） | 1.0 |
| ev.contamination | 汚染事故 | 歩留まり相対 −10% | 進行中ノード | 常時（低確率） | 600秒（10分） | 0.4 |
| ev.subsidy_boost | 補助金 | 装置購入価格 −20% | 購入全般 | 常時 | 600秒（10分） | 1.0 |

### 継続時間の換算根拠（採用した換算）

DESIGN §2.5 の継続時間はゲーム内時間（6〜48時間）だが、現行テンポ（実1秒＝ゲーム内10分）では 36実秒〜4.8実分となり短すぎるため、improvement-analysis の再定義指示「実時間基準（10〜40実分）」を優先した。写像は DESIGN の相対比を保つ線形写像：実秒 ＝ 600 ＋（ゲーム時間 − 6）×（1800/42)。6時間→600秒、12時間→約857秒（840に丸め）、18時間→約1114秒（1080に丸め）、24時間→約1371秒（1380に丸め）、48時間→2400秒。残り時間は `ActiveMarketEvent.remainingRealSeconds` として実秒で保持し、プレイ中 tick とオフライン進行（不在の上限適用後秒数）の両方で減らす。新規発生はプレイ中 tick のみ（歩留まり異常と同じ扱い）。

### 発生頻度の換算根拠

DESIGN §2.5 は「平均ゲーム内1日に1回（実時間24分に1回）」。現行テンポではゲーム内1日＝2.4実分となり、実時間基準に再定義された継続時間（10〜40分）と両立しない（常時2件張り付きになる）ため、DESIGN 自身が併記した実時間換算「24分に1回」を採用した。抽選はポアソン到着の近似：tick ごとに p ＝ 1 − exp(−dt / 1440秒）。同時上限は2件（DESIGN §2.5／§5.8）。発生中のイベントは再抽選されない。乱数源は歩留まり異常と同じ作法で `Engine.eventRandomUnit`（差し替え可能）。

### 効果の反映経路

- 価格：`Engine.derived` の単価 ＝ 製品単価 × サイクル係数 × ウォーク係数 × `eventPriceFactor`。eventPriceFactor は発生中の価格イベントのうち「対象ノードが空（全ノード）または現在ノードを含む」ものの倍率の積（DESIGN の価格決定式「イベント係数 × ノード別需要係数」を1つの係数に統合）。DerivedState に eventPriceFactor / eventYieldFactor / equipmentDiscountFactor を追加して表示側でも参照可能にした。
- 歩留まり（汚染事故）：derived の lineYield と lineYieldWithoutExcursion の両方に ×0.9（excursionYieldLoss が異常分だけを保つため）。実生産側は SimCore に `eventYieldMultiplier` を新設し、ロット精算の lotYield に上限 0.99 の後に掛ける。Engine.tick と OfflineProgress.advance が毎回 state から設定する（スナップショットには保存しない。オフラインは開始時点の状態で区間全体に効く近似で、区間途中で期限切れになっても倍率は外さない）。
- 装置価格（補助金）：`Engine.purchasePriceYen(state:model:)` を新設し、buyBlockReason の資金不足判定、buy / buyAndPlace の課金と subsidy.totalInvestedYen（実際に支払った額を計上）へ反映。表示側は BuildDrawer の価格と MapScene の配置確定ボタン（「ここに置く（価格）」）を purchasePriceYen に合わせた。
- 状態：`MarketState.activeEvents` を追加。schemaVersion は 4 のまま。MarketState は synthesized Codable だったため、Stats と同じ作法で custom init（全キー decodeIfPresent）を追加し、旧セーブは activeEvents = [] で復元される。

### UI（新画面・新タブなし。既存の置き場のみ）

- 開始・終了通知：GameStore が tick／復帰処理の前後で activeEvents の集合を比較し、`marketEventNotice` を発行。新規ビュー `Views/MarketEventToast.swift`（FieldNoteToast と同じ見た目、8秒で自動消去）を ContentView のトースト層に表示。同時に複数変化した場合はカタログ順の先頭1件（開始優先）、表示中は上書きしない。
- 残り時間バッジ：HUDView の HStack（WPH の後）に発生中イベントのチップ（名前＋「あと◯分」、汚染事故は赤系）を最大2件。
- 詳細：StatsView（事務所シート）に「市場イベント」セクション（発生中イベントの名前・効果・残り実時間、現在のイベント単価倍率）を追加。

## 2. 期間P&L（StatsView「期間損益（ゲーム内24時間）」）

- 区切り：`market.gameTimeMinutes` を 1440 ゲーム分（ゲーム内24時間）で区切った期間インデックス。根拠：既存のゲーム内時計（Day 表示）と一致し、累計表示の隣で「今日の損益」として読める最小単位。オフライン進行はゲーム内時計を進めない既存仕様のため、オフライン売上は復帰時点の期間に計上される。
- 集計：Stats に plPeriodIndex（-1 = 未初期化）＋現在期間／前期間の4値（売上総額・売上原価・市場不良ペナルティ・粗利）を追加（decodeIfPresent で旧セーブ互換）。`Engine.accruePeriodPL` が期間跨ぎで現在期間を前期間へ移してリセットする。
- フック箇所（累計 total* へ加えるのと同じ金額を同じ呼び出しで計上。二重計上・欠落なしを HeadlessCheck で検証）：
  1. Engine.tick：売れた割合で按分した gross / cogs / penalty / net の増分
  2. Engine.sellInventory：grossYen / cogsYen / sale.penaltyYen / netYen
  3. OfflineProgress.advance：按分後の sold フロー
- 表示：StatsView に当期間4行＋（前期間の値があれば）前期間4行。

## 3. 経済バランス最終調整（DESIGN §5 との差分表）

機械比較の結果、§5.1〜§5.4 の大半は現行値と一致していた。差分はすべて「現行値が過去の再調整／チェックで固定された値」で、テンポや判定帯への影響が大きいため、今回は寄せずに「要判断（現行維持）」として残した。寄せた項目はゼロ（＝無条件に寄せられる安全な差分は存在しなかった）。

### 一致していた項目（変更なし）

- §5.1：初期所持金 30億円、スロット 12、初期ライン構成（L1×2・D1×2・E1×3・I1・C1・Q1・P1）、初期ラインWPH 8.5、初期歩留まり 70%
- §5.2：全ノードのダイ数（100/120/150/170/200/220）、Y_init / Y_max、チップ基準単価、ウェハ材料費、パス数（§5.3 全ノード分）
- §5.4：装置カタログ全20機種の価格・公称WPH（機械比較で全一致を確認）
- §5.8：サイクル振幅 0.7〜1.3（現行 amplitude 0.3）、ウォークのクランプ 0.6〜1.5、イベント同時最大 2 件

### 要判断として残した差分（変更せず）

| 項目 | DESIGN §5 | 現行 | 現行維持の根拠 |
|---|---|---|---|
| W_learn（28nm） | 500 枚 | 6,000 枚 | リデザイン期の学習テンポ再調整値。下げると序盤の歩留まり上昇が速くなり、収入系チェック（14nm到達後の収入比など）の前提も変わる |
| W_learn（14nm） | 1,000 枚 | 2,000 枚 | 同上 |
| 市況サイクル周期 | ゲーム内7日（10,080分） | 90,000 分 | HeadlessCheck の既存チェック「市況周期は 90,000 ゲーム内分」で固定された意図的な値。短縮すると価格変動の体感が大きく変わる |
| ランダムウォーク | ゲーム内1時間ごとに ±5% | 360 分ごとに ±2% | 同上（現行間隔はチェックで固定）。頻度・幅とも現行は穏やか側で、イベント導入後の価格変動の主役をイベント側に置く現行設計と整合 |
| 在庫上限 | 10,000 個 | 200,000 個 | 製品制（ダイ数 45〜600個/ウェハ）では 10,000 個は数ゲーム時間で溢れる。現行値は製品制に合わせて再調整された値 |
| 研究費・時間（実装済み10件） | §5.7 の表 | すべて再調整済み（例：14nmプロセス 20億円/10分 → 40億円/60分） | 研究は出荷済みシステムで費用・時間とも個別に再調整されている。一括で §5.7 に戻すと進行テンポが激変する |
| イベント発生間隔 | 平均ゲーム内24時間（ポアソン） | 平均 24 実分（上記換算） | 継続時間の実時間再定義とセットの判断として本ログ §1 に根拠を明記 |

- §5.7 の未実装研究（スループットⅢ、SPC 以降、7nm 以降の解放研究など）は今回の範囲外（研究ツリー拡張は別フェーズ）。
- 判定帯への影響：価格・イベント・P&L の追加は生産側の数値（定常 7.458 WPH の帯、検出率 0.7822、初回ロット完了 tick）を変えず、全既存チェックが無変更で通過している。

## 4. 変更・新規ファイル一覧

変更（13）：
- FabTycoon/Models/Catalog.swift（MarketEventSpec、Catalog.marketEvents 7件＋索引）
- FabTycoon/Models/GameState.swift（ActiveMarketEvent、MarketState.activeEvents＋custom Codable、Stats の期間P&L 9フィールド＋CodingKeys＋decodeIfPresent）
- FabTycoon/Models/Engine.swift（定数・乱数源、DerivedState の3フィールド追加と derived への係数反映、updateMarketEvents / eligibleMarketEvents / eventPriceFactor / contaminationActive / equipmentDiscountFactor / purchasePriceYen、tick 組み込み、購入価格の反映、accruePeriodPL と tick／sellInventory のフック）
- FabTycoon/Models/Simulation.swift（SimCore.eventYieldMultiplier、ロット精算への適用）
- FabTycoon/Models/OfflineProgress.swift（eventYieldMultiplier の設定、イベント残り時間の減少、期間P&L のフック、コメント整合）
- FabTycoon/ViewModels/GameStore.swift（MarketEventNotice 型、marketEventNotice、開始・終了検出、dismiss）
- FabTycoon/Views/ContentView.swift（トースト層への MarketEventToast 組み込み）
- FabTycoon/Views/HUDView.swift（イベントチップ＋残り分ヘルパー）
- FabTycoon/Views/StatsView.swift（市場イベント／期間損益セクション）
- FabTycoon/Views/BuildDrawer.swift（価格表示を purchasePriceYen に）
- FabTycoon/Views/MapScene.swift（配置確定ボタンの価格を purchasePriceYen に）
- FabTycoon.xcodeproj/project.pbxproj（MarketEventToast.swift の登録、接尾辞 23）
- HeadlessCheck/main.swift（P6 セクション追加）

新規（2）：
- FabTycoon/Views/MarketEventToast.swift
- design/p6-implementation-log.md（本ファイル）

削除：なし。schemaVersion は 4 のまま。

## 5. 検証結果

- HeadlessCheck（Swift 6.1.2、-O）：**887 件全通過**（`HEADLESS CHECK PASSED`、失敗 0）。内訳＝従来 851 件を無変更で維持＋P6 追加 36 件。追加分の内訳：カタログ sanity 3、旧セーブ互換 2、抽選の決定性 3、解放条件 3、価格係数とノード対象 5、期限切れ 2、同時上限 1、汚染事故 2、補助金と購入 5、期間P&L の直接計上とロールオーバー 3、在庫売却の二重計上なし 3、tick 統合（期間＝累計の一致）3、ほか境界確認 1。
  - 既存チェックの判定帯の変更・緩和はなし。変更した既存チェックもなし。
- View 層メンバー参照スイープ：Views／ViewModels 全ファイルで `store.state.*`・`store.*`・`store.derived.*`・`derived.*`・素の `state.*`・`Engine.*`・`Catalog.*` の参照を実在メンバー集合と機械照合し、**不一致ゼロ**。
- pbxproj 全数照合：ディスク上の Swift 23 ＝ FileReference 23 ＝ Sources 23（不足・余剰なし）。
- 全 23 Swift ファイルの構文パース（swiftc -parse）無エラー。

## 6. 未検証事項（実機・実ビルド判定分）

- SwiftUI の型検査を兼ねる実ビルドは Codemagic 待ち（この VM ではモデル層までしかコンパイルできない。従来と同じ前提）。
- HUD のイベントチップは fixedSize のため、狭幅（iPhone SE 375pt）で WPH 表示と合わせて幅が足りるかは実機確認が必要。
- イベント通知トーストの表示タイミング（現場ノートとの重なり順序。市場イベント側が上に出る配置にした）、StatsView の新セクションの見え方は実機判定事項。
- イベントの実プレイ体感（発生頻度 24 実分平均・継続 10〜40 分・価格変動幅）は実機プレイでの調整対象。

## 7. 仮置き・設計との差分・申し送り

- 発生頻度と継続時間は DESIGN のゲーム内時間表記ではなく実時間換算を採用（根拠は §1）。DESIGN §5.8 の「イベント発生間隔：平均ゲーム内24時間（ポアソン）」とは表記が異なるが、実時間では DESIGN §2.5 の併記値と一致する。
- 汚染事故の「歩留まり −10%」は相対 −10%（×0.9）と解釈した（ポイント減ではない）。
- 補助金イベント中も、アドバイザーの提案文と nodeSwitchWarnings が表示する装置価格は定価（model.priceYen）のまま。課金は割引価格で行われるため、表示と実額が最大20%ずれる。購入の主要導線（BuildDrawer・配置確定ボタン）は実価格に合わせてある。アドバイザー側の追随は次フェーズの申し送り。
- 期間P&L の「粗利」は累計 totalRevenueYen と同じ定義（純額）。表示では売上総額・原価・ペナルティを併記して内訳が追えるようにした。
- オフライン中のイベントは新規発生せず、残り時間だけが減る。汚染事故の倍率はオフライン開始時点の状態で区間全体に効く近似。
- 本ツリーは隔離クローンであり、本線への統合・push・Codemagic は親側の工程。
