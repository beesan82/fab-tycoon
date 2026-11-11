# Dynamic Type 対応（カード）実装ログ

実施：2026-11-11、隔離クローン `fab-tycoon-trackDT`（土台＝本線 1.0.0 (20) / コミット 980dbbc 相当）。
実装は Claude Code（Opus、ファイル別セッション）、検証はコーディネーター側。

## 目的

設計書 `design/simcity-rebuild.md` §6.1 R3 チェック項目4「Dynamic Type 最大でカードの文言が折り返して読める」を満たす。
R3 実装時に「この VM では SwiftUI の型検査ができず、無検証で広範囲に触らない」として未着手で残された項目（`design/r3-implementation-log.md` §1・申し送り）。

## 洗い出し結果（対象ファイル別）

前提として、全 View のフォント指定は大半が `.caption` / `.subheadline` 等のセマンティックスタイルで、Dynamic Type に追随する状態だった。固定サイズ指定（`.font(.system(size:))`）は対象範囲では WelcomeCardView の装飾アイコン1件のみ。実際の問題は「行数制限で本文が切れる」「固定高で枠が伸びない」「横並びの圧迫」に集中していた。

| ファイル | 問題箇所 | 問題の種類 |
|---|---|---|
| ToolCard.swift | コンパクト段の高さが固定 176pt（`toolCardHeight`） | 固定高：文字が育っても枠が伸びず切れる |
| ToolCard.swift | header 2行目（チップ＋統計テキストの HStack） | 横並びの圧迫：AX サイズで統計が読めない |
| ToolCard.swift | statusLabel の `.fixedSize()`（両軸） | 全幅要求：タイトル側を押し出す |
| ToolCard.swift | actionMessage の `.lineLimit(2)` | 行数制限：エラー文が切れる |
| ToolCard.swift | learnPage 見出しのモデル名 `.lineLimit(1)`、header 3行目・同工程行の装置名に最小縮小なし | 行数制限：名前が切れる |
| LotCard.swift | 行き先 Label・infoRow 値の `.lineLimit(1)`＋`.minimumScaleFactor(0.8)` | 行数制限：長い値が縮小されても切れる |
| LotCard.swift | 「この工程を学ぶ」ボタンだけ `.lineLimit(1)`（隣のボタンは制限なし） | 不揃い |
| RailCard.swift | 「先頭の行き先」Label の `.lineLimit(1)`＋`.minimumScaleFactor(0.8)` | 行数制限 |
| BuildDrawer.swift | BuildModelTile の機種名 `.lineLimit(1)`（縮小指定もなし） | 行数制限：切れる |
| BuildDrawer.swift | 価格行（価格・公称WPH・所持台数）に縮小指定なし | 横並びの圧迫 |
| FacilitySheets.swift | 書棚の現場ノート見出し：折りたたみ時 `.lineLimit(1)` | 行数制限：実測値入りの見出し（fn.little）が途中で切れる |
| FacilitySheets.swift | リトルの法則ライブの数式（3項＋演算子の HStack） | 横並びの圧迫：AX サイズで3項が潰れる |
| FacilitySheets.swift | WelcomeCardView アイコンの `.font(.system(size: 40))` | 固定サイズ（装飾グリフ） |
| StatsView.swift | 行テキスト群を精査：`.lineLimit` 指定は全行になし、List 内で自然に折り返す | **変更不要** |
| FieldNoteToast.swift | 見出しの折りたたみ時 `.lineLimit(1)` | 行数制限：実測値入りの見出しが切れる |
| MarketEventToast.swift | イベント名の `.lineLimit(1)` | 行数制限 |

調査したが変更しなかったもの（範囲内・問題なし／意図的に対象外）：

- **StatsView.swift**：全行が List＋HStack（タイトル＋Spacer＋値）で、行数制限がなく文字拡大時は行が縦に伸びて折り返す。ProductsView／GlossaryView／GlossaryDetailView も同型。変更なし。
- **RailCard.swift の StockerCard**：行・本文とも制限なし。本文は VStack 全幅で自然に折り返す。変更なし。
- **FacilitySheets.swift の他シート**（LibrarySheet 本文、EntrySheet、ShippingSheet、NodeSwitchSheet、DefectAnalysisSheet）：List ベースで、散文には既に `fixedSize(horizontal: false, vertical: true)` が付いており折り返す。リトルの法則の各項の数値（`.lineLimit(1)`＋最小縮小 0.6〜0.7）は数値ラベルとして妥当と判断し維持。
- **ContentView.swift 内の ResearchView／SettingsView／OfflineReportSheet**：研究棟シートの実体だが List ベースで散文は折り返し済み。問題箇所なし。
- **ToolCard の chip（律速／未接続バッジ）** の `.fixedSize()`：短いバッジ文言であり、隣の統計テキスト側が縮小する現行バランスを維持（意図的に変更なし）。
- **ToolCard の actionLabel（ボタン列）** の `.lineLimit(1)`：横スクロールのボタン列で、短い命令＋数値サブのみ。通常サイズ・AX とも列自体がスクロールで回避できるため維持。
- **BuildDrawer のドロワー高（画面の 40% 固定）**：各タブ内が ScrollView のため、文字が育ってもスクロールで読める。変更なし。

範囲外として調査のみ（本タスクの指示で対象外）：

- HUDView（HUD は対象外。P6 申し送りの「イベントチップと WPH の幅」は別件）
- MapScene の Canvas 描画テキスト（Dynamic Type の管轄外）
- MapScene の SwiftUI オーバーレイ（ゴーストツールバー／レールモードバー）：カードではなく操作バーのため対象外。エラー・説明文は既に `fixedSize(horizontal: false, vertical: true)` で折り返す。確定ボタンの `.lineLimit(1)` と、ツールバーの想定高さ（52/80pt 固定計算）は残課題として申し送る。
- DockView、ProblemsPopover（展開式で本文は読める）、ContentView の吹き出し／施設ショートカット列（アドバイザー吹き出しは1行ティッカーで、全文は問題ポップオーバーで読める設計）。

## 実施した変更（ファイル別・方法）

### ToolCard.swift
1. コンパクト段の高さ：`toolCardHeight`（View 拡張）を `ToolCardHeightModifier`（ViewModifier、`@Environment(\.dynamicTypeSize)` 保持）に置換。.compact は AX サイズ（`isAccessibilitySize`）のとき `frame(minHeight: 176)`、それ以外は従来どおり `frame(height: 176)`。展開・全画面段は従来どおり。
2. header 2行目：チップ部を `headerChips(_:)`、統計テキストを `headerStats(_:)` に切り出し、AX サイズでは VStack（チップ行＋統計）、それ以外は従来の HStack に分岐。`headerChips` はチップが1つもないとき何も出さない（空 HStack の間隔で統計がずれるのを防ぐため。Claude Code からの提案を採用）。
3. statusLabel：`.fixedSize()` → `.fixedSize(horizontal: false, vertical: true)`（横は圧縮可、縦は全文）。
4. actionMessage：`.lineLimit(2)` を外し、`.multilineTextAlignment(.center)`＋`.fixedSize(horizontal: false, vertical: true)`。
5. header 3行目（工程名＋パス数）と siblingSection の装置名に `.minimumScaleFactor(0.8)` を追加（`.lineLimit(1)` は維持）。
6. learnPage 見出しのモデル名：`.lineLimit(1)` を外し、中央寄せ＋`.fixedSize(horizontal: false, vertical: true)`。

### LotCard.swift
1. 行き先 Label：`.lineLimit(1)`＋`.minimumScaleFactor(0.8)` を外し `.fixedSize(horizontal: false, vertical: true)`（全文折り返し）。
2. infoRow の値：制限を外し `.multilineTextAlignment(.trailing)`＋`.fixedSize(horizontal: false, vertical: true)`（右寄せのまま折り返し）。
3. 「この工程を学ぶ」ボタン：`.lineLimit(1)`＋`.minimumScaleFactor(0.8)` を外し、隣の「追跡をやめる」と挙動を統一。

### RailCard.swift
1. 「先頭の行き先」Label：`.lineLimit(1)`＋`.minimumScaleFactor(0.8)` を削除（VStack 全幅行なので自然に折り返す）。

### BuildDrawer.swift
1. BuildModelTile の機種名：`.lineLimit(1)` → `.lineLimit(2)`＋`.fixedSize(horizontal: false, vertical: true)`（倉庫タブ storedTile と同じ流儀）。
2. 価格行 HStack：`.lineLimit(1)`＋`.minimumScaleFactor(0.7)` を追加（数値ラベル群は折り返さず最小縮小で対応。最小縮小を確実に効かせるには lineLimit(1) が要るという Claude Code の指摘を採用）。

### FacilitySheets.swift
1. 書棚の現場ノート見出し：折りたたみ時の `.lineLimit` を 1 → 2、`fixedSize` の vertical を `isExpanded` 依存から常時 true に。
2. リトルの法則ライブ：EntrySheet に `@Environment(\.dynamicTypeSize)` を追加し、数式を AX サイズでは VStack（項→演算子→項→演算子→項の縦積み）、それ以外は従来の HStack に分岐。littleTerm／littleOperator の中身・引数は不変更。
3. WelcomeCardView のアイコン：`@ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 40` を追加し `.font(.system(size: iconSize))` に（デフォルトサイズでは従来どおり 40pt、拡大時は連動）。

### FieldNoteToast.swift
1. 見出し：折りたたみ時の `.lineLimit` を 1 → 2、`fixedSize` の vertical を常時 true に。
2. 本文の折りたたみ時1行制限は**意図的に維持**（タップで展開すれば全文が読めるプレビュー。展開時は元々制限なし。アクセシビリティヒント「タップで全文を読む」も既存）。

### MarketEventToast.swift
1. イベント名：`.lineLimit(1)` を外し `.fixedSize(horizontal: false, vertical: true)`。

## 通常サイズへの影響

差分を全件目視確認した結果、デフォルトの Dynamic Type で見た目が変わり得るのは次の2件のみで、いずれも軽微：

- **FacilitySheets の書棚見出し／FieldNoteToast の見出し**：通常サイズでも1行に収まらない長い見出しは、従来の1行省略（…）ではなく2行表示になる。1行に収まる見出しは不変。長い見出し（fn.little の実測値入り等）で発生し得る。
- **ToolCard の statusLabel**：横方向の圧縮を許したため、極端に長い装置名＋長い状態ラベル（「待機（ノード非対応）」）の組み合わせでは、状態ラベルが従来より先に折り返す／切れる可能性がある。通常の組み合わせでは不変のはずだが、実機での確認を推奨（Claude Code からも同旨の指摘あり）。

それ以外の変更は、AX サイズでのみ効く分岐・制限緩和、またはデフォルトでは等価な指定（ScaledMetric の係数 1.0、minHeight の下限＝従来の固定高と同じ 176 等）で、通常サイズのレイアウト・余白・並び・ウェイトに変更はない。

## 検証結果

- **HeadlessCheck：887 件全通過を維持**（変更前ベースライン 887 件全通過 → 変更後も 887 件全通過・失敗 0、`HEADLESS CHECK PASSED`）。モデル層は無変更（Models／Persistence／HeadlessCheck を本線と diff し完全一致を確認）。件数の増減なし。
- **View 層メンバー参照スイープ：不一致ゼロ**。Views／ViewModels の全ファイルで `store.*`（GameStore 77 メンバー）、`store.state.*`・`state.*`（GameState 19 メンバー）、`derived.*`（DerivedState 40 メンバー）、および `state.fab.*` 等の2段チェーン（プロパティ型のメンバー）を機械照合し、照合 280 件すべて実在。負テストとして β5 の実バグ `store.state.inventoryChips` を一時的に混入させ、検出できることも確認した（混入は復元済み、StatsView.swift は本線とバイト一致に戻っている）。
- **構文パース：全 Swift ファイル無エラー**（`swiftc -parse`、FabTycoon 配下 23 ファイル＋HeadlessCheck 1 ファイル）。
- **pbxproj：無変更**（新規ファイルなし。本線と diff 一致）。
- **変更ファイルは対象7ファイルのみ**（ToolCard／LotCard／RailCard／BuildDrawer／FacilitySheets／FieldNoteToast／MarketEventToast）。他の View・モデル・設定ファイルは本線と完全一致。

## 未検証事項

- **Dynamic Type 最大（AX5 等）での実際の折り返し・読みやすさは実機判定分**。この VM では SwiftUI の型検査・プレビューができないため、レイアウトの最終確認は Codemagic 実ビルド＋実機（§6.1 R3 #4 の判定）で行うこと。特に確認してほしい点：
  - ToolCard コンパクト段が AX サイズで縦に伸びて全文読めるか（minHeight 化の効果）。
  - リトルの法則ライブが AX サイズで縦積み表示になるか。
  - WelcomeCardView が `.medium` デテント内で収まるか（文字＋アイコン拡大で高さ超過の懸念。超過する場合はデテントを `.large` 併記にする等の追加対応が要る）。
  - ToolCard の状態ラベル（上記「通常サイズへの影響」参照）。

## 申し送り

- MapScene のゴーストツールバーは想定高さ（52/80pt）を位置計算に使っているため、AX サイズでは確定ボタン列がはみ出す可能性がある。今回は対象外としたが、実機で問題があればツールバー側の高さ計算を dynamicTypeSize 連動にする追加対応が要る。
- FieldNoteToast 本文の折りたたみ時1行は意図的に維持した。実機で「プレビューとして不足」と判断されれば、見出しと同じく2行化が候補。
- 本変更の取り込み時は View 層のみの差分（7ファイル）で、モデル・セーブ互換には影響しない。
