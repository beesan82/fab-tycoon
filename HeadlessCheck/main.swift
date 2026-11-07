import Foundation

// Models/Catalog.swift・GameState.swift・Engine.swift・MoneyFormat.swift・Persistence/SaveManager.swift と一緒にコンパイルして実行する。
// 例: swiftc FabTycoon/Models/Catalog.swift FabTycoon/Models/GameState.swift \
//       FabTycoon/Models/Engine.swift FabTycoon/Models/MoneyFormat.swift FabTycoon/Persistence/SaveManager.swift \
//       HeadlessCheck/main.swift -o /tmp/fab-headless && /tmp/fab-headless

func fail(_ message: String) -> Never {
    print("FAILED: \(message)")
    exit(1)
}

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  OK: \(message)")
    } else {
        fail(message)
    }
}

func num(_ value: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", value)
}

func describe(_ d: DerivedState) {
    for process in ProcessType.allCases {
        print("  \(process.displayName): \(d.units(process))台  \(num(d.wph(process))) WPH")
    }
    print("  ラインWPH: \(num(d.lineWPH))")
    print("  ボトルネック: \(d.bottleneck?.displayName ?? "-") / 次点: \(d.secondBottleneck?.displayName ?? "-")")
    print("  歩留まり: \(num(d.currentYield * 100, 1))%")
    print("  単価: \(num(d.currentPriceYen, 0))円")
    print("  収入/分: \(num(d.incomePerMinuteYen, 0))円")
}

// 1. 初期状態
print("== 1. 初期状態 ==")
var state = GameState.initial()
let initialCash = state.cashYen
let d0 = Engine.derived(state: state)
describe(d0)
check(initialCash == 3_000_000_000, "初期資金は30億円")
check(abs(d0.lineWPH - 8.5) < 1e-6, "初期ラインWPH ≈ 8.5")
check(d0.bottleneck == .deposition, "初期ボトルネックは成膜")
check(abs(d0.currentYield - 0.6983) < 0.005, "初期歩留まり 約69.8%")

// 2. 実10分相当の tick
print("== 2. tick 0.25秒 × 2400回（実10分） ==")
var produced = 0.0
var goodChips = 0.0
var revenue = 0.0
for _ in 0..<2_400 {
    let result = Engine.tick(state: &state, dtRealSeconds: 0.25)
    produced += result.producedWafers
    goodChips += result.goodChips
    revenue += result.revenueYen
}
let d1 = Engine.derived(state: state)
print("  投入ウェハ: \(num(produced))枚")
print("  良品チップ: \(num(goodChips, 0))個")
print("  売上: \(num(revenue, 0))円")
print("  資金: \(num(initialCash, 0))円 → \(num(state.cashYen, 0))円")
print("  ゲーム内経過: \(num(state.market.gameTimeMinutes, 0))分  walkFactor: \(num(state.market.walkFactor, 3))")
print("  歩留まり: \(num(d1.currentYield * 100, 2))%  単価: \(num(d1.currentPriceYen, 0))円")

// 3. 生産・売上・資金のチェック
print("== 3. チェック ==")
check(goodChips > 0 && state.stats.totalGoodChips > 0, "良品チップが生産された")
check(state.stats.totalRevenueYen > 0, "売上が立った")
check(state.cashYen > initialCash, "資金が初期より増えた")
check(abs(state.stats.playSeconds - 600) < 1e-6, "プレイ時間が600秒")
check(abs(state.stats.totalRevenueYen - (state.stats.totalGrossSalesYen - state.stats.totalCogsYen - state.stats.totalMarketPenaltyYen)) < 1.0, "粗利 = 売上 − 原価 − ペナルティ")
check(state.stats.totalGrossSalesYen > 0 && state.stats.totalCogsYen > 0, "売上と原価が計上された")

// 4. D1 購入
print("== 4. D1 購入 ==")
let before = Engine.derived(state: state).lineWPH
let predicted = Engine.lineWPHAfterAdding(state: state, modelId: "D1")
let cashBeforeBuy = state.cashYen
check(Engine.buy(state: &state, modelId: "D1"), "D1 を購入できた")
let after = Engine.derived(state: state).lineWPH
print("  ラインWPH: \(num(before)) → \(num(after))（予測 \(num(predicted))）")
print("  資金: \(num(cashBeforeBuy, 0))円 → \(num(state.cashYen, 0))円")
check(after > before, "購入後にラインWPHが上がった")
check(abs(after - predicted) < 1e-9, "プレビューと実際が一致")
check(abs(cashBeforeBuy - state.cashYen - 800_000_000) < 1e-6, "D1 価格 8億円が引かれた")

// 追加: オフライン進行
print("== 追加. オフライン進行（1時間不在） ==")
let marketMinutesBeforeOffline = state.market.gameTimeMinutes
let playSecondsBeforeOffline = state.stats.playSeconds
let gameHoursBeforeOffline = state.gameHoursElapsed
let report = Engine.offlineProgress(state: &state, elapsedRealSeconds: 3_600)
print("  有効時間: \(num(report.effectiveSeconds, 0))秒  投入: \(num(report.producedWafers))枚  売上: \(num(report.revenueYen, 0))円")
check(report.producedWafers > 0 && report.revenueYen > 0, "オフラインでも生産・売上がある")
check(state.gameHoursElapsed == gameHoursBeforeOffline, "オフライン前後でゲーム内経過時間が変わらない")
check(state.market.gameTimeMinutes == marketMinutesBeforeOffline, "オフライン前後で市況位相（market.gameTimeMinutes）が変わらない")
check(state.stats.playSeconds == playSecondsBeforeOffline, "オフライン前後でプレイ時間（stats.playSeconds）が変わらない")

// 0.2.0: スキーマ・バランス定数
print("== 0.2.0. スキーマ・バランス定数 ==")
check(GameState.initial().schemaVersion == 2, "新規ゲームの schemaVersion は 2")
check(Catalog.node(id: "n28")?.learnWafers == 6_000, "28nm の learnWafers は 6,000")
check(Engine.marketCycleMinutes == 90_000, "市況周期は 90,000 ゲーム内分")
check(Engine.walkStep == 0.02, "ランダムウォーク幅は ±2%")
check(Engine.inventoryCap == 200_000, "在庫上限は 200,000 個")

// 0.2.0: 開始直後は補助金を申請できない
print("== 0.2.0. 初期の補助金 ==")
let freshForSubsidy = GameState.initial()
check(Engine.subsidyCapYen(state: freshForSubsidy) == 0, "新規ゲームの交付可能額は 0（初期装置は累計設備投資に含めない）")
check(!Engine.canApplySubsidy(state: freshForSubsidy), "開始直後は補助金を申請できない")

// 0.2.0: ランダムウォーク間隔（6ゲーム時間）
print("== 0.2.0. ランダムウォーク間隔 ==")
var walkState = GameState.initial()
Engine.tick(state: &walkState, dtRealSeconds: 30)
print("  ゲーム内経過: \(num(walkState.market.gameTimeMinutes, 0))分  walkFactor: \(num(walkState.market.walkFactor, 3))")
check(walkState.market.walkFactor == 1.0, "300ゲーム分（6ゲーム時間未満）ではランダムウォークが動かない")

// 0.2.0: 学習曲線（300ゲーム時間 = 実1800秒）
print("== 0.2.0. 学習曲線 ==")
var learnState = GameState.initial()
for _ in 0..<7_200 {
    Engine.tick(state: &learnState, dtRealSeconds: 0.25)
}
let learnDerived = Engine.derived(state: learnState)
print("  累計投入: \(num(learnState.learningWafers["n28"] ?? 0, 0))枚  ライン歩留まり: \(num(learnDerived.lineYield * 100, 2))%")
check(learnDerived.lineYield >= 0.76 && learnDerived.lineYield <= 0.81, "実30分後のライン歩留まりが 76〜81%（理論値 約78.5%）")

// 0.2.0: 製品マージン（パワー vs 汎用ロジック）
print("== 0.2.0. 製品マージン ==")
func marginPerWafer(productId: String) -> Double {
    var productState = GameState.initial()
    productState.currentProductId = productId
    let d = Engine.derived(state: productState)
    return d.incomePerMinuteYen / (d.lineWPH * Engine.gameMinutesPerRealSecond)
}
let logicMargin = marginPerWafer(productId: "logic")
let powerMargin = marginPerWafer(productId: "power")
let marginRatio = powerMargin / logicMargin
print("  ウェハ1枚あたり純売上: 汎用ロジック \(num(logicMargin, 0))円 / パワー \(num(powerMargin, 0))円  比率 \(num(marginRatio, 3))")
check(marginRatio >= 0.75 && marginRatio <= 1.25, "パワー/汎用ロジックのマージン比が 0.75〜1.25")

// 0.2.0: セーブ移行・安全化
print("== 0.2.0. セーブ移行・安全化 ==")
let fileManager = FileManager.default
let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("fabtycoon-check-\(UUID().uuidString)")

func makeDirectory(_ name: String) -> URL {
    let url = tempRoot.appendingPathComponent(name)
    do {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        fail("一時ディレクトリを作れない: \(error)")
    }
    return url
}

func encodedObject(_ state: GameState) -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(state),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { fail("GameState を辞書化できない") }
    return object
}

func writeObject(_ object: [String: Any], to url: URL) {
    do {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: .atomic)
    } catch {
        fail("フィクスチャを書き込めない: \(error)")
    }
}

// v1 フィクスチャ（schemaVersion 1・新フィールドなし）
let v1Dir = makeDirectory("v1")
var v1Object = encodedObject(GameState.initial())
v1Object["schemaVersion"] = 1
v1Object.removeValue(forKey: "didShowScaleChangeNotice")
writeObject(v1Object, to: v1Dir.appendingPathComponent(SaveManager.fileName))
var v1Manager = SaveManager(directory: v1Dir)
let v1Loaded = v1Manager.load()
check(v1Loaded != nil, "v1 セーブを読み込める")
check(v1Loaded?.schemaVersion == 2, "v1 セーブは schemaVersion 2 に移行される")
check(v1Manager.lastLoadedOriginalVersion == 1, "v1 セーブの元バージョンは 1")

// schemaVersion キー自体が無いセーブ
let noVersionDir = makeDirectory("noversion")
var noVersionObject = v1Object
noVersionObject.removeValue(forKey: "schemaVersion")
writeObject(noVersionObject, to: noVersionDir.appendingPathComponent(SaveManager.fileName))
var noVersionManager = SaveManager(directory: noVersionDir)
check(noVersionManager.load() != nil, "schemaVersion キーの無いセーブも読み込める")
check(noVersionManager.lastLoadedOriginalVersion == 1, "schemaVersion キーの無いセーブの元バージョンは 1")

// .bak からの復旧
let bakDir = makeDirectory("bak")
var bakManager = SaveManager(directory: bakDir)
var bakState = GameState.initial()
bakState.cashYen = 1_234_567_890
do {
    try bakManager.save(bakState)
    try bakManager.save(bakState)
} catch {
    fail("セーブできない: \(error)")
}
check(fileManager.fileExists(atPath: bakDir.appendingPathComponent(SaveManager.backupFileName).path), "2回目の保存で .bak が作られる")
do {
    try "{ broken".data(using: .utf8)!.write(to: bakDir.appendingPathComponent(SaveManager.fileName))
} catch {
    fail("メインを壊せない: \(error)")
}
let bakLoaded = bakManager.load()
check(bakLoaded?.cashYen == 1_234_567_890, "メインが壊れていても .bak から復旧できる")

// 未知の将来版は上書きせず退避する
let futureDir = makeDirectory("future")
var futureObject = encodedObject(GameState.initial())
futureObject["schemaVersion"] = 99
writeObject(futureObject, to: futureDir.appendingPathComponent(SaveManager.fileName))
var futureManager = SaveManager(directory: futureDir)
check(futureManager.load() == nil, "schemaVersion 99 のセーブは読み込まない")
check(futureManager.lastLoadedOriginalVersion == nil, "読み込めなかったときの元バージョンは nil")
check(fileManager.fileExists(atPath: futureDir.appendingPathComponent(SaveManager.unreadableFileName).path), "将来版のセーブは退避ファイルに残る")

// リセット相当：セーブ削除
do {
    try futureManager.deleteSave()
    try bakManager.deleteSave()
} catch {
    fail("セーブを削除できない: \(error)")
}
check(!futureManager.hasSave, "deleteSave 後は hasSave == false")
check(!bakManager.hasSave && !fileManager.fileExists(atPath: bakDir.appendingPathComponent(SaveManager.backupFileName).path), "deleteSave でメインと .bak の両方が消える")
check(fileManager.fileExists(atPath: futureDir.appendingPathComponent(SaveManager.unreadableFileName).path), "deleteSave しても退避ファイルは残る")

try? fileManager.removeItem(at: tempRoot)

// 0.3.0: 目標と図鑑
print("== 0.3.0. カタログ件数・図鑑の解放 ==")
let glossaryInitial = GameState.initial()
check(Catalog.milestones.count == 12, "マイルストーンは12本")
check(Catalog.glossaryTerms.count == 30, "用語は30本")
check(Engine.glossaryEntries(state: glossaryInitial).count == 57, "図鑑の全エントリは57件")
check(Engine.glossaryUnlockedCount(state: glossaryInitial) == 26, "初期状態の図鑑の解放数は26（装置7＋工程7＋用語12）")

// 0.3.0: 「なぜ？」内訳（初期状態）
print("== 0.3.0. 内訳の整合 ==")
let breakdown = Engine.derived(state: glossaryInitial)
print("  検出率: 基礎 \(num(breakdown.detectionBase, 3)) ＋ 余裕度 ×\(num(breakdown.detectionHeadroom, 3)) による上乗せ \(num(breakdown.detectionHeadroomBonus, 3)) = \(num(breakdown.detectionRate, 3))")
print("  歩留まり: 工程積 \(num(breakdown.processYieldProduct, 4)) 欠陥残存率 \(num(breakdown.learningDefectScale, 4)) 倍率前 \(num(breakdown.rawLineYield, 4)) → \(num(breakdown.lineYield, 4))")
check(breakdown.detectionBase == 0.55, "初期の基礎検出率は 0.55（Q1）")
check(abs(breakdown.detectionHeadroom - 4.0) < 1e-9, "初期の検査余裕度は 4.0（34 ÷ 8.5）")
check(abs(breakdown.detectionHeadroomBonus - 0.225) < 1e-9, "初期の余裕度ボーナスは 0.225")
check(abs(breakdown.detectionRate - 0.775) < 1e-9, "初期の検出率は 0.775")
let rebuiltRawYield = 1 - (1 - breakdown.processYieldProduct) * breakdown.learningDefectScale
let rebuiltLineYield = min(max(1 - (1 - rebuiltRawYield) / Engine.productYieldMultiplier(state: glossaryInitial), 0), 0.99)
check(abs(rebuiltLineYield - breakdown.lineYield) < 1e-12, "内訳から再構成したライン歩留まりが lineYield と一致")

// 0.3.0: アドバイザー
print("== 0.3.0. アドバイザー ==")
let advisorInitial = Engine.advisorMessage(state: glossaryInitial, derived: breakdown)
print("  初期: \(advisorInitial)")
check(advisorInitial.contains("成膜") && advisorInitial.contains("PECVD"), "初期状態ではボトルネックの成膜に PECVD を勧める")
var noDepositionState = GameState.initial()
noDepositionState.fab.equipment.removeAll { Catalog.model(id: $0.modelId)?.process == .deposition }
let advisorStopped = Engine.advisorMessage(state: noDepositionState, derived: Engine.derived(state: noDepositionState))
print("  成膜なし: \(advisorStopped)")
check(advisorStopped.contains("止まって"), "成膜装置が無いとライン停止を知らせる")
var subsidyReadyState = GameState.initial()
subsidyReadyState.subsidy.totalInvestedYen = 300_000_000
let advisorSubsidy = Engine.advisorMessage(state: subsidyReadyState, derived: Engine.derived(state: subsidyReadyState))
print("  投資3億円: \(advisorSubsidy)")
check(advisorSubsidy.contains("補助金"), "補助金を申請できるときは申請を勧める")
var fullAffordState = GameState.initial()
fullAffordState.fab.slots = fullAffordState.fab.equipment.count
fullAffordState.cashYen = 10_000_000_000
let advisorFullAfford = Engine.advisorMessage(state: fullAffordState, derived: Engine.derived(state: fullAffordState))
print("  スロット満杯・資金あり: \(advisorFullAfford)")
check(advisorFullAfford.contains("増床") && !advisorFullAfford.contains("を足すと"), "スロット満杯で増床資金があれば増床を勧める")
var fullPoorState = GameState.initial()
fullPoorState.fab.slots = fullPoorState.fab.equipment.count
fullPoorState.cashYen = 0
let advisorFullPoor = Engine.advisorMessage(state: fullPoorState, derived: Engine.derived(state: fullPoorState))
print("  スロット満杯・資金不足: \(advisorFullPoor)")
check(advisorFullPoor.contains("倉庫") && !advisorFullPoor.contains("を足すと"), "スロット満杯で資金不足なら倉庫への付け替えを勧める")

// 0.3.0: マイルストーンのシミュレーション
print("== 0.3.0. マイルストーン（D1購入→パワーへ切替→実10分） ==")
var milestoneState = GameState.initial()
check(Engine.buy(state: &milestoneState, modelId: "D1"), "D1 を購入できた")
check(Engine.switchProduct(state: &milestoneState, productId: "power"), "パワー／アナログ系に切り替えられた")
for _ in 0..<2_400 {
    Engine.tick(state: &milestoneState, dtRealSeconds: 0.25)
}
let achievedIds = Catalog.milestones.map { $0.id }.filter { milestoneState.stats.achievedMilestones[$0] != nil }
print("  達成: \(achievedIds.joined(separator: ", "))")
check(["first_investment", "wph_10", "product_switch"].allSatisfy { milestoneState.stats.achievedMilestones[$0] != nil },
      "first_investment・wph_10・product_switch を達成")
check(achievedIds.count >= 3, "達成数が 3 以上")

// 0.3.0: 旧セーブ互換（Stats に新フィールドが無い）
print("== 0.3.0. 旧セーブ互換・往復 ==")
let checkDecoder = JSONDecoder()
checkDecoder.dateDecodingStrategy = .iso8601
var legacyObject = encodedObject(GameState.initial())
guard var legacyStats = legacyObject["stats"] as? [String: Any] else { fail("stats を辞書として取り出せない") }
legacyStats.removeValue(forKey: "achievedMilestones")
legacyStats.removeValue(forKey: "readGlossaryIds")
legacyObject["stats"] = legacyStats
let legacyData = try? JSONSerialization.data(withJSONObject: legacyObject)
let legacyState = legacyData.flatMap { try? checkDecoder.decode(GameState.self, from: $0) }
check(legacyState != nil, "achievedMilestones・readGlossaryIds の無いセーブを読み込める")
check(legacyState?.stats.achievedMilestones.isEmpty == true && legacyState?.stats.readGlossaryIds.isEmpty == true,
      "欠けたフィールドは空で補われる")

// 0.3.0: Stats の往復
let checkEncoder = JSONEncoder()
checkEncoder.dateEncodingStrategy = .iso8601
var roundTripState = GameState.initial()
roundTripState.stats.readGlossaryIds.insert("term.wafer")
let roundTripData = try? checkEncoder.encode(roundTripState)
let roundTripDecoded = roundTripData.flatMap { try? checkDecoder.decode(GameState.self, from: $0) }
check(roundTripDecoded?.stats == roundTripState.stats, "readGlossaryIds を含む Stats がエンコード→デコードで一致")

print("HEADLESS CHECK PASSED")
