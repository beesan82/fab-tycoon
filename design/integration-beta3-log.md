# β3 統合ログ（トラックC ドット絵化＋トラックD 必須修正①②、2026-11-09）

作業：隔離クローン2件（トラックC／トラックD）の成果を本線 `~/workspace/projects/fab-tycoon`（β2 = コミット 28e6850、TestFlight 1.0.0 (15) 配信済み）へ統合し、検証まで実施。**push は未実施**（親側で実施）。取り込み前の本線ファイルは `/tmp/fab-beta3-backup/` に退避済み。

- トラックC：ドット絵化（`design/gate3-dot-log.md` §7 の取り込み手順に準拠。ただし mov1 の扱いは本ログ §3 の判断で手順3・4を変更）
- トラックD：β1実機フィードバック必須修正①②（`design/fix-beta1-feedback-log.md`）

---

## 1. 取り込みファイル一覧

### トラックD（コード3ファイル＋ログ1件、いずれも取り込み元と `cmp` でバイナリ一致を確認）

| ファイル | 内容 |
|---|---|
| `FabTycoon/Models/Layout.swift` | テンプレート並べ替え（I1/Q1/C1 のスロット入替）、`snappedOrigin`、`RouteStepOrder` 追加 |
| `FabTycoon/Views/FloorGridView.swift` | IN/OUT プレート＋脈動枠、工程順バッジ、レール流れドット、ゴーストのドラッグ／スナップ／確定ボタン化 |
| `HeadlessCheck/main.swift` | P7 セクション 12 件追加＋既存 1 件（P4 derived EMA 下限）の帯調整 |
| `design/fix-beta1-feedback-log.md` | 新規（トラックDの作業ログ） |

### トラックC（ドット絵化）

| ファイル | 内容 |
|---|---|
| `FabTycoon/Assets.xcassets/eq_<id>_front_body.imageset/eq_<id>_front_body.png` ×7（c1/l1/d1/e1/i1/q1/p1） | 本体スプライトをセミフォトリアル版からドット絵版へ差し替え（4,075〜5,808 B/点、合計 32,006 B。セミリアル版 2.65MiB の約 1/87）※バイナリのため push 対象外（§4） |
| `design/sprites/generated/eq_<id>_front_body.png` ×7 | 上記と同一バイトのマスター側コピー（imageset と `cmp` 一致を確認）※バイナリのため push 対象外 |
| `design/sprites/<id>.json` ×7 | メタデータ正本。新 pixelSize・status=`gate3-dot` で更新。c1 は layers 空（§3） |
| `FabTycoon/Assets.xcassets/eq_<id>_meta.dataset/<id>.json` ×7 | 上記と同一バイト（全7件 `cmp` 一致を確認） |
| `Scripts/generate_sprites.sh` | トラックC版（ドット絵7点）をベースに、β2版スクリプトの mov1 セクションを追加したマージ版（§3）。約 3.75MB → 259,399 B |
| `design/gate3-dot-log.md` | 新規（トラックCの作業ログ） |
| `design/sprites/make_dot_sprites.py` | 新規（ドット絵の再生成用スクリプト。gate3 §7 手順5） |
| `design/sprites/dot-contact-sheet.png` | 7機種一覧の参照画像。**ローカルにのみ配置し、push 対象外** |

### 無変更を確認したもの

- 全7機種の imageset／dataset の `Contents.json`：トラックCと本線で同一だったため取り込みなし。
- `eq_c1_front_mov1.imageset`（フォルダ＋PNG＋Contents.json）：本線の既存状態のまま残置（§3）。

## 2. 競合について

トラックDの起点は β2 統合済み本線のコピーのため、`FloorGridView.swift` は本線と競合せず、そのまま取り込みできた（トラックCはコード変更なし）。

## 3. C1 可動部 mov1 の扱い（判断）

トラックCは「ドット絵版 mov1 は作らず、セミリアル版も流用しない」として、クローン内で mov1 アセットを削除し、`c1.json` の `layers` を空にした。本線への統合では次のように扱った。

- **メタデータ側はトラックCの判断をそのまま採用**：`c1.json` の `layers` は空配列（統合後の本線でも空であることを確認済み）。描画側は `front.layers.first` が無ければ可動部描画をスキップする既存仕様のため、**mov1 が表示されることはない**。CMP のプラテン回転アニメは β3 では無くなる（プラテン自体はドット絵本体に描き込み済み）。
- **アセット側は削除せず残置**：本線の `eq_c1_front_mov1.imageset` フォルダと PNG は残した。理由は2つ。(1) リポジトリへの反映はスナップショット送信方式でファイル削除ができず、PNG だけ消えて `Contents.json` が残る中途半端な状態になるとアセットカタログのコンパイルで問題になり得る。(2) 将来ドット絵 mov1 を試作する際の参照にもなる。
- **`generate_sprites.sh` は mov1 生成を含む形にした**：トラックC版スクリプト（ドット絵7点、SPRITE_0〜6）に、β2版スクリプトの mov1 ブロックを SPRITE_7 として追加。Codemagic のビルド時生成でも mov1 PNG が欠落しない。スクリプトのヘッダコメントにも本判断を明記した。
- 往復検証：別ツリー（/tmp）に Scripts と FabTycoon をコピー → 装置 PNG 8 点（本体7＋mov1）を全削除 → スクリプト実行 → 復元された **8 点すべての md5 が本線 imageset の PNG と一致**。

## 4. 検証結果

- コピー整合性：取り込んだ全ファイルについて、取り込み元との `cmp` 一致（コード・JSON・PNG）および design/dataset の JSON ペア一致・imageset/generated の PNG ペア一致を確認。
- メタデータ：`c1.json` の layers が空であること、全7件の JSON がパース可能であることを確認。
- **HeadlessCheck（統合後の本線で実施）**：
  - コンパイル：Swift 6.1.2（`~/workspace/tools/swift-6.1.2/usr/bin/swiftc`、`-O`）、対象は `FabTycoon/Models/*.swift`（7ファイル）＋`FabTycoon/Persistence/SaveManager.swift`＋`HeadlessCheck/main.swift`。**エラー・警告なし**（約146秒）。
  - 実行：**555 件全通過（HEADLESS CHECK PASSED、exit 0、失敗 0 件）**（約5.0分）。内訳は β2 の 543 件＋トラックD の P7 新規 12 件で、想定どおり。トラックD単体での結果（555 件全通過）とも一致。
- 未検証（β3 配信後に実機で確認する事項）：SwiftUI 側の Xcode 実ビルド（Codemagic が初回）、ドット絵の接地感・縦はみ出し・縮小表示でのドットの潰れ・fps（gate3-dot-log.md §8）、必須修正①②の操作感（fix-beta1-feedback-log.md の確認手順）。

## 5. push 対象ファイルリスト（テキストファイルのみ、全 22 件）

push は本統合では未実施。親側で以下のファイルを対象にスナップショット送信すること。

```
FabTycoon/Models/Layout.swift
FabTycoon/Views/FloorGridView.swift
HeadlessCheck/main.swift
Scripts/generate_sprites.sh
design/fix-beta1-feedback-log.md
design/gate3-dot-log.md
design/integration-beta3-log.md
design/sprites/make_dot_sprites.py
design/sprites/c1.json
design/sprites/l1.json
design/sprites/d1.json
design/sprites/e1.json
design/sprites/i1.json
design/sprites/q1.json
design/sprites/p1.json
FabTycoon/Assets.xcassets/eq_c1_meta.dataset/c1.json
FabTycoon/Assets.xcassets/eq_l1_meta.dataset/l1.json
FabTycoon/Assets.xcassets/eq_d1_meta.dataset/d1.json
FabTycoon/Assets.xcassets/eq_e1_meta.dataset/e1.json
FabTycoon/Assets.xcassets/eq_i1_meta.dataset/i1.json
FabTycoon/Assets.xcassets/eq_q1_meta.dataset/q1.json
FabTycoon/Assets.xcassets/eq_p1_meta.dataset/p1.json
```

### push 対象外（明記）

- **ドット絵 PNG 7 点**（各 `eq_<id>_front_body.imageset` 内）および `design/sprites/generated/` のマスター PNG 7 点：バイナリのため対象外。リポジトリ側では `Scripts/generate_sprites.sh` がビルド時に imageset の PNG を生成する（往復 md5 一致を §3 で検証済み）。generated/ はローカルのマスター置き場として同期済み。
- **`design/sprites/dot-contact-sheet.png`**：参照用のためローカルにのみ配置し、push 対象外。
- **`eq_c1_front_mov1.imageset/Contents.json`**：無変更のため含めない（mov1 の PNG も本線既存のまま残置であり、生成は `generate_sprites.sh` の SPRITE_7 が担う）。
- 全7機種の imageset／dataset の `Contents.json`：無変更のため含めない。
