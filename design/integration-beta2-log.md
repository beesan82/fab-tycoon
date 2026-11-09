# Fab Tycoon β2 統合ログ（トラックA＋B → 本線、2026-11-09）

作業場所：本線 `~/workspace/projects/fab-tycoon`（β1 = 1.0.0 (14) の状態から統合）
入力：隔離クローン `fab-tycoon-trackA`（P5スプライト、gate1-log.md／gate2-log.md）、`fab-tycoon-trackB`（P6経済3件、trackB-report.md）
範囲：**統合＋検証まで**。push と Codemagic 起動は本ログをもとに親側で実施する（本作業では push していない）。
版数：MARKETING_VERSION は 1.0.0 のまま変更なし。ビルド番号は Codemagic 側で TestFlight 最新+1 になる運用のため触っていない。
統合前の本線ファイルは `/tmp/fab-main-backup-beta1/` に退避した（変更6ファイル分）。

---

## 1. 取り込んだファイル一覧

### 変更（既存ファイルの更新、6件）
| ファイル | 取り込み元 | 内容 |
|---|---|---|
| `FabTycoon/Models/Simulation.swift` | B | プリシード用 `SimCore.warmedInitialSnapshot`・`initialWarmUpGameMinutes = 6_000` |
| `FabTycoon/Models/GameState.swift` | B | `initial()` の sim 生成を warmedInitialSnapshot に変更（新規ゲームのみ） |
| `FabTycoon/Models/Layout.swift` | B | `FloorLayout.paidRailPoints`＋custom decoder（旧セーブ互換）＋`LayoutTemplate.templateRailPoints` |
| `FabTycoon/Models/Engine.swift` | B | `railRefundYen(state:at:)` / `(state:points:)` 新設、setRail / removeRail の返金仕様変更 |
| `FabTycoon/Views/FloorGridView.swift` | A＋B（手マージ、§2） | スプライト描画・環境描画（A）と撤去プレビューの実返金額表示（B）の両立 |
| `HeadlessCheck/main.swift` | B | 既存517件（うち4件を仕様変更に合わせ更新）＋P6新規26件＝543件 |

いずれもコピー後に取り込み元と `cmp` でバイナリ一致を確認した（FloorGridView は §2 のため除く）。

### 新規（アセット、15フォルダ／30ファイル、計 約2.8MB）
`FabTycoon/Assets.xcassets/` 配下（トラックAから）：
- 本体 imageset ×7：`eq_c1_front_body` / `eq_d1_front_body` / `eq_e1_front_body` / `eq_i1_front_body` / `eq_l1_front_body` / `eq_p1_front_body` / `eq_q1_front_body`（各 Contents.json＋PNG）
- 可動部 imageset ×1：`eq_c1_front_mov1`（CMPプラテン）
- メタデータ dataset ×7：`eq_c1_meta` / `eq_d1_meta` / `eq_e1_meta` / `eq_i1_meta` / `eq_l1_meta` / `eq_p1_meta` / `eq_q1_meta`（各 Contents.json＋`<id>.json`）

新規 Swift ファイルは無いため **project.pbxproj の変更は不要**（アセットカタログ内の追加は既存 .xcassets の範囲）。

### 新規（設計記録）
- `design/sprites/` 一式（26ファイル）：機種別メタデータ正本 `{c1,d1,e1,i1,l1,p1,q1}.json`、生成スクリプト `make_c1_sprites.py` / `make_sprites.py`、`generated/`（本体PNG 8点＋measure2.json）、`raw/`（生成元 8ファイル）
- `design/gate1-log.md` / `design/gate2-log.md`（トラックAの工数・取り込み手順）
- `trackB-report.md`（プロジェクトルート、トラックBのレポート）
- `design/integration-beta2-log.md`（本ファイル）

統合後、`design/` と `Assets.xcassets/` はトラックA側と完全一致（diff 差分なし）を確認した。

---

## 2. FloorGridView.swift の合わせ方（競合解消）

両トラックの変更範囲が重ならなかったため、「A版をベースに、Bの変更箇所だけを移植」する方式で合わせた。

- **ベース＝トラックA版**（1,264行）：`import UIKit` 追加、`EquipmentSpriteMeta` / `EquipmentSprites` ローダ（NSDataAsset＋UIImage 実在確認、無い機種はベクタ描画にフォールバック）、`drawSpriteTool`（本体スプライト＋CMPプラテン回転、ズーム<0.5 で LOD 停止）、環境描画（床の市松＋グレーチング孔、ストッカーのラック＋収納FOUPスロット、FOUPの接地影・蓋継ぎ目・窓帯・取っ手）。
- **移植＝トラックBの変更（1ハンクのみ、`.erase` ケースの案内・プレビュー部）**：
  - 案内文言：「（全額返金）」→「（購入したレールは全額返金、最初からあるレールは返金なし）」
  - 撤去プレビュー：`count × Engine.railCellCostYen` の一律計算を廃し、`Engine.railRefundYen(state: store.state, points: targets)` による実返金額表示に変更。
- **両立の検証**：
  - 統合版 vs A版の diff ＝ Bの1ハンクのみ（他の差分なし）。
  - 統合版 vs B版の diff ＝ Aの追加分のみ（177行）。
  - grep で共存を確認：`EquipmentSprites` / `drawSpriteTool`（A）、床・ストッカー環境描画（A）、`railRefundYen`（B、927行目）。
  - 統合版は 1,265 行（A版 1,264行＋Bハンクの純増1行）。

---

## 3. 検証結果

- コンパイル：Swift 6.1.2（`~/workspace/tools/swift-6.1.2/usr/bin/swiftc`、`-O`）、対象は `FabTycoon/Models/*.swift`（7ファイル）＋`FabTycoon/Persistence/SaveManager.swift`＋`HeadlessCheck/main.swift`。**エラー・警告なし**（約91秒）。
- 実行：**543件 全通過（HEADLESS CHECK PASSED、exit 0、失敗0件）**。実行時間 約7.4分（トラックB時の約27分より短縮。VM負荷差と思われる）。
  - 内訳：既存517件（うち4件は仕様変更に合わせ更新。詳細は trackB-report.md）＋P6新規26件（プリシード／レール返金／WIP運転点）。
  - 統合で Models は B版とバイナリ一致しているため、チェック結果はトラックB単体の結果と同一になるはずで、実際に一致した。
- 未検証（β2配信後に実機で確認する事項。gate2-log §7 と trackB-report の申し送り）：
  - SwiftUI 側（FloorGridView 含む）の Xcode 実ビルド（Codemagic）。
  - 7機種の接地感・drawScale、Q1の縦はみ出し、床パスの fps。
  - β1実セーブのロード（paidRailPoints 欠落時のヒューリスティクス復元経路）。
  - 開始直後から45ロットが流れている見た目と、初回完了まで実約78秒の体感。

---

## 4. push 対象ファイル一覧（スナップショット送信用、全66ファイル）

本線ルート `~/workspace/projects/fab-tycoon` からの相対パス。

### 変更 6ファイル
```
FabTycoon/Models/Simulation.swift
FabTycoon/Models/GameState.swift
FabTycoon/Models/Layout.swift
FabTycoon/Models/Engine.swift
FabTycoon/Views/FloorGridView.swift
HeadlessCheck/main.swift
```

### 新規 30ファイル（Assets.xcassets、15フォルダ）
```
FabTycoon/Assets.xcassets/eq_c1_front_body.imageset/Contents.json
FabTycoon/Assets.xcassets/eq_c1_front_body.imageset/eq_c1_front_body.png
FabTycoon/Assets.xcassets/eq_c1_front_mov1.imageset/Contents.json
FabTycoon/Assets.xcassets/eq_c1_front_mov1.imageset/eq_c1_front_mov1.png
FabTycoon/Assets.xcassets/eq_c1_meta.dataset/Contents.json
FabTycoon/Assets.xcassets/eq_c1_meta.dataset/c1.json
FabTycoon/Assets.xcassets/eq_d1_front_body.imageset/Contents.json
FabTycoon/Assets.xcassets/eq_d1_front_body.imageset/eq_d1_front_body.png
FabTycoon/Assets.xcassets/eq_d1_meta.dataset/Contents.json
FabTycoon/Assets.xcassets/eq_d1_meta.dataset/d1.json
FabTycoon/Assets.xcassets/eq_e1_front_body.imageset/Contents.json
FabTycoon/Assets.xcassets/eq_e1_front_body.imageset/eq_e1_front_body.png
FabTycoon/Assets.xcassets/eq_e1_meta.dataset/Contents.json
FabTycoon/Assets.xcassets/eq_e1_meta.dataset/e1.json
FabTycoon/Assets.xcassets/eq_i1_front_body.imageset/Contents.json
FabTycoon/Assets.xcassets/eq_i1_front_body.imageset/eq_i1_front_body.png
FabTycoon/Assets.xcassets/eq_i1_meta.dataset/Contents.json
FabTycoon/Assets.xcassets/eq_i1_meta.dataset/i1.json
FabTycoon/Assets.xcassets/eq_l1_front_body.imageset/Contents.json
FabTycoon/Assets.xcassets/eq_l1_front_body.imageset/eq_l1_front_body.png
FabTycoon/Assets.xcassets/eq_l1_meta.dataset/Contents.json
FabTycoon/Assets.xcassets/eq_l1_meta.dataset/l1.json
FabTycoon/Assets.xcassets/eq_p1_front_body.imageset/Contents.json
FabTycoon/Assets.xcassets/eq_p1_front_body.imageset/eq_p1_front_body.png
FabTycoon/Assets.xcassets/eq_p1_meta.dataset/Contents.json
FabTycoon/Assets.xcassets/eq_p1_meta.dataset/p1.json
FabTycoon/Assets.xcassets/eq_q1_front_body.imageset/Contents.json
FabTycoon/Assets.xcassets/eq_q1_front_body.imageset/eq_q1_front_body.png
FabTycoon/Assets.xcassets/eq_q1_meta.dataset/Contents.json
FabTycoon/Assets.xcassets/eq_q1_meta.dataset/q1.json
```

### 新規 26ファイル（design/sprites）
```
design/sprites/c1.json
design/sprites/d1.json
design/sprites/e1.json
design/sprites/i1.json
design/sprites/l1.json
design/sprites/p1.json
design/sprites/q1.json
design/sprites/make_c1_sprites.py
design/sprites/make_sprites.py
design/sprites/generated/eq_c1_front_body.png
design/sprites/generated/eq_c1_front_mov1.png
design/sprites/generated/eq_d1_front_body.png
design/sprites/generated/eq_e1_front_body.png
design/sprites/generated/eq_i1_front_body.png
design/sprites/generated/eq_l1_front_body.png
design/sprites/generated/eq_p1_front_body.png
design/sprites/generated/eq_q1_front_body.png
design/sprites/generated/measure2.json
design/sprites/raw/media-generation-eq-d1-e1-raw-0-435fa41c-ba34-4569-8445-32b3eadd7a36.webp
design/sprites/raw/media-generation-eq-d1-e1-raw-1794208575.json
design/sprites/raw/media-generation-eq-i1-single-raw-0-3e58cf90-756e-4c74-8d59-c61574117762.webp
design/sprites/raw/media-generation-eq-i1-single-raw-1794208748.json
design/sprites/raw/media-generation-eq-l1-i1-raw-0-71fc2e47-6999-4283-aecf-fd8a02f5b035.webp
design/sprites/raw/media-generation-eq-l1-i1-raw-1794208570.json
design/sprites/raw/media-generation-eq-q1-p1-raw-0-e97a9ace-b012-48f3-a858-fbcd8606878e.webp
design/sprites/raw/media-generation-eq-q1-p1-raw-1794208569.json
design/sprites/raw/media-generation-last-upload-handles.json
```

### 新規 4ファイル（ドキュメント）
```
design/gate1-log.md
design/gate2-log.md
design/integration-beta2-log.md
trackB-report.md
```

**合計：変更6＋新規60＝66ファイル。**

---

## 5. 次の手順（親側）

1. 上記66ファイルをスナップショット送信で push。
2. Codemagic でビルド（ビルド番号は TestFlight 最新+1 で自動想定）。
3. TestFlight β2 で §3 の未検証事項を実機判定（特に β1 実セーブのロード、7機種の接地感、床パスの fps、初回完了の体感）。

---

## 6. push時のバイナリ扱い（2026-11-09 親側で追記）

スナップショット送信は UTF-8 テキストのみ扱えるため、バイナリ20点（imageset PNG 8点、design/sprites/generated PNG 8点、raw webp 4点）は push 対象から外した。装置スプライト8点は AppIcon と同じ方式に寄せ、`Scripts/generate_sprites.sh` に base64 で埋め込み、Codemagic のビルド時に各 .imageset へ書き出す（ステップ「Generate equipment sprites」を codemagic.yaml に追加）。スクリプトの往復一致（decode後のmd5が元PNGと全点一致）は検証済み。generated/ の PNG は imageset と同一バイトのため欠落なし。raw webp は生成元素材で、再生成に必要な場合はローカル（本線チェックアウトと trackA クローン）に残る。
