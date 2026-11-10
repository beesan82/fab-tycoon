# R3 実装ログ（SimCity式リビルド第3弾：ドット絵完成＋仕上げ）

- 対象：設計書 `design/simcity-rebuild.md` §6 の R3 行、§6.1 の R3 チェックリスト
- 作業ツリー：`~/workspace/projects/fab-tycoon-trackR3`（土台＝β5 相当の本線、コミット cf49f2f）
- 経緯：前任コーディネーターが最終報告なしに終了したため、本ログは「引き継ぎ担当」が残存物を精査し、不足分のみを仕上げて作成した。前任の作業と引き継ぎ担当の作業は節を分けて明記する。
- 結論：**HeadlessCheck 851 件全通過（645 件維持＋R3 追加 206 件）**。push 条件を満たす。本線・他クローンは無変更、push はしていない。

## 1. 精査結果（済／未完の切り分け）

### 前任の作業として残っていたもの（精査で妥当性を確認済み）

| 項目 | 内容 | 精査結果 |
|---|---|---|
| 残り13機種のドット絵 | `design/sprites/make_dot_sprites_r3.py`（初期7機種の様式を踏襲：輪郭 #222636、グレー5階調、工程色アクセント1色、タワー無し）で L2/L3/L4・D2/D3・E2/E3・I2・C2・Q2/Q3・P2/P3 を生成。generated PNG・Assets.xcassets（imageset＋meta.dataset）・`design/sprites/<id>.json` が揃っている | ✅ 完備（下記 §3 の往復検証と目視で確認） |
| 環境ドット寄せ（MapScene） | `pixelOutline`（#222636 相当）＋`drawPixelBox`／`notchedRect` ヘルパを新設し、FOUP・ストッカー棚・投入口／出荷口プレート・売地看板・施設3棟（絵文字廃止→矩形合成のピクセル建物：事務所＝窓格子ビル、研究棟＝煙突＋ガラスドーム、資料室＝本積み屋根）・煙・各種ラベル板をピクセル調に置換 | ✅ 実装済み。切断プラグと砂時計は R2 時点でドット化済み、床は P5 第2ゲートの手続き描画（市松＋グレーチング孔、矩形合成）が既にピクセル調のため変更なし |
| 性能（モデル層） | `Engine.tick` で tick 前に `derived` を1回だけ計算して使い回し（異常抽選と SimCore 初期化で共有）。`SimCore` 初期化に `knownPriceYen` を追加し、精算価格の再計算を回避 | ✅ 実装済み。価格は tick 中に変わらない（製品・ノード・市況は tick 内で不変）ため意味論は不変で、645件の既存チェック（精算額一致・決定性・オフライン精度）がそれを裏付けている |
| 不要コード掃除 | 削除：`Fab.freeSlots`、`DerivedState.maxProcessWPH`、`BuyBlockReason.noFreeSlot` と `isLock`、`Engine.offlineStepSeconds`、`productCogsRate`、`canAttachEquipment`、`canApplyEmergencySubsidy`、`lineYieldAfterAdding/Upgrading/Selling`、`FloorLayout` の固定設備移動ヘルパ（`canPlaceFacility`／`moveStocker`／`moveEntry`／`moveShipping`）、`templateRailPoints`。連動して MapScene／BuildDrawer の `.noFreeSlot` 分岐も除去 | ✅ 全削除シンボルの参照 0 件を grep で確認。設計書が名指しした `AppTab`・`FloorEditMode.parcels` は R1 時点で既に除去済み（本線・当ツリーとも 0 件） |
| HeadlessCheck の R3 追加 | 全20機種のスプライト・メタデータ整合（後述）と、性能計測（48×48・装置60台・tick＋derived 平均） | ⚠️ 性能フィクスチャに不具合あり（§2 で引き継ぎ担当が修正） |
| ベースライン | `r3-baseline.log` に変更前の 645 件全通過の出力を保存 | ✅ 確認（OK 645 件＋PASSED） |

### 未完・申し送りとして残すもの

- **Dynamic Type 対応（カード）**：未着手。View 層のフォント指定は固定サイズのまま。§6.1 R3 #4 は実機判定項目であり、この VM では SwiftUI の型検査ができないため、無検証で広範囲に触るより未完として明示する（RC 前に実機確認とセットで実施推奨）。
- **LOD／LayoutAnalysis の恒常キャッシュ**：未実装。代わりに上記の「tick 内 derived 使い回し」で再計算は削減済み。性能計測（§4）で 1 tick 平均 83.3ms（予算 250ms の 1/3）を確認しており、実害ベースでは不足していない。48×48・FOUP 80 個での 30fps は実機判定（§6.1 R3 #3）。
- **レール返金の攻略論点（C.7 逸脱4）の決着**：コード変更なしで「決着済み」と判断。理由：P6（β2）で `FloorLayout.paidRailPoints` を導入し、無償レール（テンプレート分）の撤去返金は 0・購入セルのみ全額返金に変更済み。逸脱4が挙げた「無償レール売却で最大8,000万円」は既に封鎖されており、HeadlessCheck の P6 節（テンプレ全セル返金合計 0 等）が担保している。

## 2. 引き継ぎ担当が仕上げた内容

1. **性能フィクスチャの台数不足を修正**（HeadlessCheck/main.swift の R3 節）
   - 症状：初回実行で `FAILED: R3: 配置台数は 60（実数 53）`。切り分けの結果、配置アルゴリズムや床面積の問題ではなく、`r3FillerIds` が 42 要素しかなく初期 11 台＋42＝53 が上限だった（前任の要素数え間違い）。レイアウト・回転のバリアント検証でも全て 53 で一致したため特定できた。
   - 修正：配列末尾に工程1式（L1, D1, E1, I1, C1, Q1, P1）の 7 要素を追加し 49 要素にした（Claude Code Opus に編集させ、差分はこの1行追加のみであることを確認）。チェック文言・閾値の変更はなし。
   - 修正後の実測：配置 60 台（追加 49／49 台全て配置成功）、ウォームアップ後ロット 121。
2. **MagnifyGesture 移行**（MapScene.swift、設計書 R3 行の明示項目で前任未着手）
   - `MagnificationGesture()` → `MagnifyGesture()` に置換し、`onChanged` の値を `value.magnification` に変更（2トークンの機械的置換、Claude Code Opus に編集させ差分を確認）。最低 OS 17.0 のため利用可能。ジェスチャ競合の実挙動は実機確認が必要（§5）。
3. **掃除の残渣除去**：`design/sprites/__pycache__`（生成スクリプト実行時の Python キャッシュ）を削除。push 対象に混入するとバイナリで送信が失敗するため。

## 3. スプライト一覧と検証

新規13機種（本体 PNG、design/sprites/generated と Assets.xcassets はバイト一致）：

| 機種 | PNG サイズ | 機種 | PNG サイズ |
|---|---|---|---|
| L2 | 8,052 B | E3 | 5,665 B |
| L3 | 9,818 B | I2 | 4,995 B |
| L4 | 11,103 B | C2 | 5,195 B |
| D2 | 6,037 B | Q2 | 5,739 B |
| D3 | 4,792 B | Q3 | 4,511 B |
| E2 | 6,956 B | P2 | 4,863 B |
|  |  | P3 | 5,356 B |

- 新規13機種の合計：**83,082 B**。初期7機種（32,006 B）と合わせて全20機種の本体合計 **115,088 B（約112 KB）**。
- **generate_sprites.sh 往復**：スクリプトを空ディレクトリで実行し、書き出された 21 PNG（全20機種の本体＋C1 mov1）全てがリポジトリ内の imageset と md5 一致（21/21）。generated ↔ imageset も 20/20 一致。
- **メタデータ整合**：HeadlessCheck の R3 節が全20機種について、json の modelId／footprint／loadPorts と Catalog の一致、front.body.image 名・anchor・drawScale 帯（0.9〜1.4）、PNG の IHDR 実寸と pixelSize の一致、meta.dataset と design/sprites の json のバイト一致、imageset PNG と generated のバイト一致を検証（200 件）。
- **目視**：`design/sprites/dot-contact-sheet-r3.png`（全20機種）を確認。初期7機種と様式が揃い（輪郭・グレー階調・工程色1色・FOUP スロット）、機種ごとのシルエット判別も可能。タワー描画なし。
- 新規 Swift ファイルは無し。pbxproj は変更なしで、照合はディスク 22＝FileReference 22＝Sources 22 で一致。

## 4. 性能計測結果（HeadlessCheck R3 節、この VM の共有 CPU で計測）

- フィクスチャ：区画 3×3＝9（48×48 セル）、蛇行6レーン＋戻りレーンのレール 404 セル、装置 60 台。
- ウォームアップ 400 tick 後のロット数：**121**（要件 80 以上）。
- 計測 200 tick の **1 tick 平均（tick＋derived）：83.3 ms**（要件：tick 間隔 250ms 未満）。実機の fps 判定は §6.1 R3 #3 で別途必要。

## 5. 検証結果

- **HeadlessCheck：851 件全通過**（`HEADLESS CHECK PASSED`）。内訳＝β5 の 645 件維持＋R3 追加 206 件（スプライト・メタ整合 200＋性能 5＋機種数 1）。既存チェックの判定帯の変更・緩和は一切なし。
- **View 層メンバー参照スイープ**：Views／ViewModels の全ファイルで `store.state.<member>`（8種：fab／stats／cashYen／activeExcursion／subsidy／research／gameHoursElapsed／currentProductId）と `state.fab.<member>`（8種）の参照を GameState／Fab の実在メンバーと照合し、不一致ゼロ。`store.<member>` 参照も GameStore の実在メンバーと照合済み（不一致ゼロ）。全 Swift ファイルの構文パースも無エラー。
- 削除シンボル 16 件の残存参照ゼロを確認（§1）。

## 6. 未検証事項

- **SwiftUI の型検査を兼ねる実ビルドは Codemagic 待ち**（この VM ではモデル層までしかコンパイル不可。β4・β5 と同じ前提）。特に MagnifyGesture 移行はこの VM では構文パースまでしか確認できていない。
- **§6.1 R3 実機チェックリスト 5 項目は RC 配信後の実機判定待ち**：①20機種ドット絵の3段ズームでの見え方 ②環境素材のピクセル密度の揃い ③48×48・装置60台・FOUP 80個で 30fps（Low Power で 20fps）④Dynamic Type 最大でのカード可読性（対応自体が未完、§1）⑤1時間連続プレイのメモリ。
- MapScene のジェスチャ競合（MagnifyGesture 化したピンチと自前タッチ認識の併用）は実機での確認が必要。

## 7. 変更ファイル一覧（対 β5 本線）

- 変更（前任）：Models/Engine.swift、Models/GameState.swift、Models/Layout.swift、Models/Simulation.swift、Views/BuildDrawer.swift、Views/MapScene.swift、HeadlessCheck/main.swift、Scripts/generate_sprites.sh
- 変更（引き継ぎ担当）：HeadlessCheck/main.swift（r3FillerIds に7要素追加）、Views/MapScene.swift（MagnifyGesture 移行）
- 新規（前任）：Assets.xcassets の新規13機種分 imageset／meta.dataset（各 Contents.json 含む）、design/sprites の新規13機種分 json、design/sprites/generated の新規13 PNG、design/sprites/make_dot_sprites_r3.py、design/sprites/dot-contact-sheet-r3.png、r3-baseline.log
- 新規（引き継ぎ担当）：本ログ design/r3-implementation-log.md
