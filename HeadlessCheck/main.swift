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

// 0.6.0: 歩留まり異常の発生抽選は乱数依存のため、既存チェックの決定性を保つよう既定では当たらない値に固定する（0.6.0 セクションで差し替える）
Engine.excursionRandomUnit = { 0.999_999 }

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
print("== 0.2.0. スキーマ・バランス定数（schemaVersion は 0.4.0 で 3） ==")
check(GameState.initial().schemaVersion == 3, "新規ゲームの schemaVersion は 3")
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
check(v1Loaded?.schemaVersion == 3, "v1 セーブは schemaVersion 3 に移行される")
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
check(Catalog.milestones.count == 14, "マイルストーンは14本")
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

// 0.4.0: 研究ツリー・補助金の実時間化
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// 研究を開始し、所要時間ちょうどで完了させる。完了時刻を返す
@discardableResult
func completeResearch(_ s: inout GameState, _ researchId: String, startAt start: Date) -> Date {
    guard let spec = Catalog.research(id: researchId) else { fail("研究 \(researchId) がカタログに無い") }
    check(Engine.startResearch(state: &s, researchId: researchId, now: start), "\(researchId) を開始できた")
    let end = start.addingTimeInterval(spec.durationSeconds)
    check(Engine.settleResearchIfDue(state: &s, now: end) == researchId, "\(researchId) が所要時間で完了")
    return end
}

print("== 0.4.0. 研究カタログ ==")
let unlockCount = Catalog.research.filter { if case .unlock = $0.effect { return true } else { return false } }.count
check(Catalog.research.count == 10, "研究は10項目")
check(Catalog.research.count - unlockCount == 7, "効果系の研究は7項目")
check(unlockCount == 3, "解放系の研究は3項目")

print("== 0.4.0. 研究の開始 ==")
var researchState = GameState.initial()
let cashBeforeResearch = researchState.cashYen
check(Engine.startResearch(state: &researchState, researchId: "throughput_1", now: t0), "throughput_1 を開始できた")
check(cashBeforeResearch - researchState.cashYen == 300_000_000, "研究費 3億円がちょうど引かれた")
check(!Engine.startResearch(state: &researchState, researchId: "cleaning", now: t0), "研究中は他の研究（cleaning）を開始できない")
check(Engine.researchBlockReason(state: researchState, researchId: "cleaning") == "他の研究が進行中です", "研究中の理由は「他の研究が進行中です」")
check(!Engine.canStartResearch(state: researchState, researchId: "throughput_2"), "前提未完了の throughput_2 は開始できない")
check(Engine.researchBlockReason(state: GameState.initial(), researchId: "throughput_2") == "前提の研究が未完了です",
      "研究中でなくても、前提未完了の理由は「前提の研究が未完了です」")

print("== 0.4.0. 研究の完了と効果 ==")
check(Engine.settleResearchIfDue(state: &researchState, now: t0.addingTimeInterval(299)) == nil, "299秒後はまだ完了しない")
check(Engine.settleResearchIfDue(state: &researchState, now: t0.addingTimeInterval(300)) == "throughput_1", "300秒後に throughput_1 が完了")
check(researchState.research.completedIds.contains("throughput_1"), "completedIds に throughput_1 が入る")
check(researchState.research.inProgressId == nil && researchState.research.hasUnseenCompletion, "完了後は進行中なし・未確認バッジあり")
let throughputDerived = Engine.derived(state: researchState)
print("  ラインWPH: \(num(throughputDerived.lineWPH, 4))")
check(abs(throughputDerived.lineWPH - 8.925) < 1e-6, "スループット改善Ⅰでラインが 8.925 WPH（8.5 × 1.05）")

print("== 0.4.0. オフライン中の研究進行 ==")
let researchSaveDir = makeDirectory("research-offline")
var researchSaveManager = SaveManager(directory: researchSaveDir)
var offlineResearchState = GameState.initial()
check(Engine.startResearch(state: &offlineResearchState, researchId: "throughput_1", now: t0), "throughput_1 を開始できた")
do {
    try researchSaveManager.save(offlineResearchState)
} catch {
    fail("セーブできない: \(error)")
}
let researchSaveURL = researchSaveDir.appendingPathComponent(SaveManager.fileName)
guard let researchSavedData = try? Data(contentsOf: researchSaveURL),
      var researchSavedObject = (try? JSONSerialization.jsonObject(with: researchSavedData)) as? [String: Any],
      var researchSavedResearch = researchSavedObject["research"] as? [String: Any]
else { fail("保存した research を辞書として取り出せない") }
researchSavedResearch["inProgressStartedAt"] = ISO8601DateFormatter().string(from: t0.addingTimeInterval(-400))
researchSavedObject["research"] = researchSavedResearch
writeObject(researchSavedObject, to: researchSaveURL)
guard var resumedState = researchSaveManager.load() else { fail("書き換えたセーブを読み込めない") }
check(resumedState.research.inProgressId == "throughput_1", "読み込み後も throughput_1 が進行中")
check(Engine.settleResearchIfDue(state: &resumedState, now: t0) == "throughput_1", "復帰時（開始から400秒後）に throughput_1 が完了")

print("== 0.4.0. 稼働率向上 ==")
var uptimeState = GameState.initial()
completeResearch(&uptimeState, "uptime_1", startAt: t0)
let uptimeDerived = Engine.derived(state: uptimeState)
print("  ラインWPH: \(num(uptimeDerived.lineWPH, 4))")
check(abs(uptimeDerived.lineWPH - 8.70) < 0.01, "稼働率向上Ⅰでラインが 8.70 WPH（10 × 0.87）")

print("== 0.4.0. クリーン度向上 ==")
var cleanroomState = GameState.initial()
completeResearch(&cleanroomState, "cleanroom", startAt: t0)
let cleanroomYield = Engine.derived(state: cleanroomState).processYields[.deposition] ?? 0
print("  成膜の工程歩留まり: \(num(cleanroomYield, 6))")
check(abs(cleanroomYield - 0.9525) < 1e-9, "クリーン度向上で成膜の工程歩留まりが 0.9525")

print("== 0.4.0. オフライン効果 ==")
var offlineFxState = GameState.initial()
let transportDone = completeResearch(&offlineFxState, "transport", startAt: t0)
completeResearch(&offlineFxState, "offline_cap_1", startAt: transportDone)
print("  オフライン効率: \(num(Engine.offlineEfficiency(state: offlineFxState), 3))  上限: \(num(Engine.offlineCapSeconds(state: offlineFxState), 0))秒")
check(Engine.offlineEfficiency(state: offlineFxState) == 0.6, "オフライン効率が 0.6")
check(Engine.offlineCapSeconds(state: offlineFxState) == 21_600, "オフライン上限が 21,600秒")
var offlineFxRun = offlineFxState
let offlineFxReport = Engine.offlineProgress(state: &offlineFxRun, elapsedRealSeconds: 30_000)
check(offlineFxReport.elapsedSeconds == 21_600, "30,000秒の不在は 21,600秒で頭打ち")

print("== 0.4.0. 研究による装置の解放 ==")
var unlockState = GameState.initial()
guard let modelL2 = Catalog.model(id: "L2"), let modelL3 = Catalog.model(id: "L3") else { fail("L2/L3 がカタログに無い") }
let l2LockedReasons = Engine.lockReasons(model: modelL2, state: unlockState)
print("  L2（研究前）: \(l2LockedReasons.joined(separator: " / "))")
check(l2LockedReasons.contains { $0.contains("研究") }, "研究前の L2 には研究の理由がある")
completeResearch(&unlockState, "unlock_immersion", startAt: t0)
let l2UnlockedReasons = Engine.lockReasons(model: modelL2, state: unlockState)
print("  L2（研究後）: \(l2UnlockedReasons.joined(separator: " / "))")
check(!l2UnlockedReasons.contains { $0.contains("研究") }, "研究後の L2 には研究の理由がない")
check(l2UnlockedReasons.contains { $0.contains("14nm で稼働") }, "研究後の L2 は「14nm で稼働」と案内される")
if case .locked? = Engine.buyBlockReason(state: unlockState, modelId: "L2") {
    check(true, "研究後も 28nm では L2 を購入できない（.locked）")
} else {
    fail("研究後も 28nm では L2 を購入できない（.locked）")
}
check(Engine.isResearchUnlocked(state: unlockState, key: "L2"), "解放キー L2 が有効")
let l3Reasons = Engine.lockReasons(model: modelL3, state: unlockState)
print("  L3: \(l3Reasons.joined(separator: " / "))")
check(l3Reasons.contains { $0.contains("準備中") }, "研究未実装の L3 は「準備中」のまま")

print("== 0.4.0. 補助金の実時間化 ==")
var realtimeSubsidy = GameState.initial()
realtimeSubsidy.subsidy.totalInvestedYen = 300_000_000
check(Engine.applySubsidy(state: &realtimeSubsidy, now: t0), "補助金を申請できた")
check(realtimeSubsidy.subsidy.pendingGrantAt == t0.addingTimeInterval(720), "交付予定は申請の720秒後")
let grantYen = realtimeSubsidy.subsidy.pendingGrantYen
let cashBeforeGrant = realtimeSubsidy.cashYen
Engine.settleSubsidyIfDue(state: &realtimeSubsidy, now: t0.addingTimeInterval(719))
check(realtimeSubsidy.cashYen == cashBeforeGrant, "719秒後はまだ交付されない")
Engine.settleSubsidyIfDue(state: &realtimeSubsidy, now: t0.addingTimeInterval(720))
check(realtimeSubsidy.cashYen == cashBeforeGrant + grantYen && grantYen > 0, "720秒後に交付予定額が入金される")
check(!Engine.canApplySubsidy(state: realtimeSubsidy, now: t0.addingTimeInterval(720)), "交付直後は申請できない（クールダウン）")
realtimeSubsidy.subsidy.totalInvestedYen += 300_000_000
check(Engine.canApplySubsidy(state: realtimeSubsidy, now: t0.addingTimeInterval(720 + 4_320)), "交付から4,320秒後は再申請できる")

print("== 0.4.0. v2 セーブ移行（審査中） ==")
let v2BaseState: GameState = {
    var base = GameState.initial()
    base.gameHoursElapsed = 1_000
    return base
}()

/// v2 フィクスチャ（subsidy の書き換えは modify で行う）を一時ディレクトリに置いて読み込む
func loadV2Fixture(_ name: String, removing keys: [String] = [], modifySubsidy: (inout [String: Any]) -> Void) -> GameState? {
    let dir = makeDirectory(name)
    var object = encodedObject(v2BaseState)
    object["schemaVersion"] = 2
    for key in keys {
        object.removeValue(forKey: key)
    }
    guard var subsidyObject = object["subsidy"] as? [String: Any] else { fail("subsidy を辞書として取り出せない") }
    modifySubsidy(&subsidyObject)
    object["subsidy"] = subsidyObject
    writeObject(object, to: dir.appendingPathComponent(SaveManager.fileName))
    var manager = SaveManager(directory: dir)
    return manager.load()
}

let beforeV2PendingLoad = Date()
let v2Pending = loadV2Fixture("v2-pending") { subsidy in
    subsidy["pendingGrantYen"] = 50_000_000.0
    subsidy["pendingGrantAtHours"] = v2BaseState.gameHoursElapsed + 60
    subsidy.removeValue(forKey: "pendingGrantAt")
}
guard let v2PendingState = v2Pending else { fail("審査中の v2 セーブを読み込めない") }
check(v2PendingState.schemaVersion == 3, "v2 セーブは schemaVersion 3 に移行される")
let v2PendingOffset = v2PendingState.subsidy.pendingGrantAt.map { $0.timeIntervalSince(beforeV2PendingLoad) }
print("  交付予定: 読み込みの \(num(v2PendingOffset ?? -1, 1))秒後")
check(v2PendingOffset.map { abs($0 - 360) <= 10 } == true, "残り60ゲーム時間は実360秒後の交付予定に移る")
check(v2PendingState.subsidy.pendingGrantAtHours == nil, "移行後の pendingGrantAtHours は nil")
guard let v2ReencodedData = try? checkEncoder.encode(v2PendingState),
      let v2Reencoded = String(data: v2ReencodedData, encoding: .utf8)
else { fail("移行後の state を再エンコードできない") }
check(!v2Reencoded.contains("pendingGrantAtHours"), "再エンコードしたセーブに pendingGrantAtHours が含まれない")

print("== 0.4.0. v2 セーブ移行（クールダウン） ==")
let v2Cooldown = loadV2Fixture("v2-cooldown") { subsidy in
    subsidy["lastGrantAtHours"] = v2BaseState.gameHoursElapsed - 360
    subsidy["totalInvestedYen"] = 300_000_000.0
    subsidy["totalReceivedYen"] = 100_000_000.0
}
guard let v2CooldownState = v2Cooldown else { fail("クールダウン中の v2 セーブを読み込めない") }
let afterV2CooldownLoad = Date()
check(!Engine.canApplySubsidy(state: v2CooldownState, now: afterV2CooldownLoad), "読み込み直後は申請できない")
let v2CooldownRemaining = Engine.subsidyCooldownRemainingSeconds(state: v2CooldownState, now: afterV2CooldownLoad)
print("  クールダウン残り: \(num(v2CooldownRemaining ?? -1, 1))秒")
check(v2CooldownRemaining.map { abs($0 - 2_160) <= 10 } == true, "残りクールダウンは 2,160秒（720 − 360 ゲーム時間 = 360 × 6秒）")

print("== 0.4.0. v2 セーブ互換（研究なし） ==")
let v2NoResearch = loadV2Fixture("v2-noresearch", removing: ["research"]) { _ in }
guard let v2NoResearchState = v2NoResearch else { fail("research の無い v2 セーブを読み込めない") }
check(v2NoResearchState.research.completedIds.isEmpty, "研究なしのセーブは completedIds が空")
let v2NoResearchDerived = Engine.derived(state: v2NoResearchState)
check(abs(v2NoResearchDerived.lineWPH - 8.5) < 1e-6, "研究なしのラインWPH は 8.5")
check(abs(v2NoResearchDerived.currentYield - 0.6983) < 0.005, "研究なしの歩留まりは 約69.8%")

// 0.5.0: 14nm移行
print("== 0.5.0. 14nm の定数 ==")
guard let node14 = Catalog.node(id: "n14") else { fail("n14 がカタログに無い") }
check(node14.priceMultiplier == 3.5, "14nm の単価倍率は 3.5")
check(node14.cogsAddition == 0.03, "14nm の原価率加算は 0.03")
check(node14.learnWafers == 2_000, "14nm の learnWafers は 2,000")
check(Catalog.isPlayable(nodeId: "n14"), "14nm はプレイ可能")

print("== 0.5.0. 移行のゲート ==")
var gateState = GameState.initial()
gateState.cashYen = 100_000_000_000
let initialGateReason = Engine.nodeSwitchBlockReason(state: gateState, toNodeId: "n14")
print("  初期: \(initialGateReason ?? "-")")
check(!Engine.canSwitchNode(state: gateState, toNodeId: "n14"), "初期状態では 14nm へ移行できない")
check(initialGateReason?.contains("研究") == true, "初期状態の理由に「研究」が含まれる")
let gateImmersionDone = completeResearch(&gateState, "unlock_immersion", startAt: t0)
check(!Engine.canSwitchNode(state: gateState, toNodeId: "n14"), "液浸露光機の研究だけでは 14nm へ移行できない")
completeResearch(&gateState, "unlock_14nm", startAt: gateImmersionDone)
check(Engine.canSwitchNode(state: gateState, toNodeId: "n14"), "14nmプロセスの研究完了後は 14nm へ移行できる")

/// 研究2件（液浸露光機・14nmプロセス）を完了した初期状態
func readyFor14nm() -> GameState {
    var s = GameState.initial()
    s.cashYen = 200_000_000_000
    let immersionDone = completeResearch(&s, "unlock_immersion", startAt: t0)
    completeResearch(&s, "unlock_14nm", startAt: immersionDone)
    return s
}

print("== 0.5.0. 移行と収支 ==")
var nodeState = readyFor14nm()
nodeState.learningWafers["n28"] = 100_000
let income28 = Engine.derived(state: nodeState).incomePerMinuteYen
let switchWarnings = Engine.nodeSwitchWarnings(state: nodeState, toNodeId: "n14")
for warning in switchWarnings {
    print("  警告: \(warning)")
}
check(switchWarnings.contains { $0.contains("L2") }, "移行前の警告で L2 の購入が案内される")
check(Engine.switchNode(state: &nodeState, toNodeId: "n14"), "14nm へ移行できた")
check(nodeState.fab.currentNodeId == "n14", "現在のノードが n14")
check(nodeState.stats.achievedMilestones["node_14"] != nil, "マイルストーン node_14 を達成")
let justSwitched = Engine.derived(state: nodeState)
check(justSwitched.lineWPH == 0, "移行直後はラインWPH 0（L1 が待機）")
guard let standbyL1 = nodeState.fab.equipment.first(where: { $0.modelId == "L1" }) else { fail("L1 が設置されていない") }
check(Engine.isStandby(standbyL1, state: nodeState), "L1 は待機中")
check(Engine.standbyCount(state: nodeState, process: .lithography) == 2, "露光の待機台数は 2")
var poorSwitched = nodeState
poorSwitched.cashYen = 0
check(Engine.emergencyGrantYen(state: poorSwitched) == nil, "待機による停止は緊急救済の対象外（ノードを戻せば稼働する）")
check(Engine.canRestartLineWithOwnedEquipment(state: poorSwitched), "14nm で待機停止中でも、所有装置で 28nm に戻せば再稼働する")
// 待機中の L1 を全て倉庫へ外しても、所有関係は変わらないため対象外のまま（付け替えでの回避を塞ぐ）
var detachedStandby = poorSwitched
for instance in detachedStandby.fab.equipment where instance.modelId == "L1" {
    check(Engine.detachEquipment(state: &detachedStandby, instanceId: instance.id), "待機中の L1 を倉庫へ外せる")
}
check(detachedStandby.fab.equipment.allSatisfy { $0.modelId != "L1" }, "設置中の L1 は 0 台")
check(detachedStandby.fab.storedEquipment.contains { $0.modelId == "L1" }, "L1 は倉庫にある")
check(Engine.canRestartLineWithOwnedEquipment(state: detachedStandby), "L1 を倉庫へ外しても、所有装置で 28nm に戻せば再稼働する")
check(Engine.emergencyGrantYen(state: detachedStandby) == nil, "待機装置を全て倉庫へ外しても緊急救済の対象外")

print("== 0.5.0. 緊急救済（古典的詰み） ==")
// 28nm で検査装置を全て手放し、どのノードでも再稼働しない詰みは従来どおり対象になる
var deadlock = GameState.initial()
for instance in deadlock.fab.equipment where instance.modelId == "Q1" {
    check(Engine.sellEquipment(state: &deadlock, instanceId: instance.id), "Q1 を売却できる")
}
deadlock.cashYen = 0
check(Engine.derived(state: deadlock).lineWPH == 0, "検査装置が無くラインが止まっている")
check(!Engine.canRestartLineWithOwnedEquipment(state: deadlock), "所有装置ではどのノードでも再稼働しない")
let deadlockGrant = Engine.emergencyGrantYen(state: deadlock)
print("  緊急交付額: \(num(deadlockGrant ?? -1, 0))円")
check(deadlockGrant != nil && deadlockGrant! > 0, "どのノードでも再稼働しない詰みは緊急救済の対象")
check(Engine.applyEmergencySubsidy(state: &deadlock), "緊急救済が発動する")
check(deadlock.cashYen > 0, "緊急救済で資金が交付された")
check(Engine.detachEquipment(state: &nodeState, instanceId: standbyL1.id), "待機中の L1 を1台倉庫へ外せる")
check(Engine.standbyCount(state: nodeState, process: .lithography) == 1, "外した後の露光の待機台数は 1")
check(Engine.attachEquipment(state: &nodeState, instanceId: standbyL1.id), "L1 を再設置できる")
check(Engine.buy(state: &nodeState, modelId: "L2"), "14nm では L2 を購入できる")
let withL2 = Engine.derived(state: nodeState)
let incomeRatio0 = withL2.incomePerMinuteYen / income28
print("  ラインWPH: \(num(withL2.lineWPH, 3))  歩留まり: \(num(withL2.lineYield * 100, 2))%  収入/分: 28nm \(num(income28, 0))円 → 14nm \(num(withL2.incomePerMinuteYen, 0))円（比 \(num(incomeRatio0, 3))）")
check(abs(withL2.lineWPH - 3.09) < 0.05, "L2 購入後のラインWPH が 約3.09")
check(incomeRatio0 >= 0.5 && incomeRatio0 <= 1.1, "移行直後の収入比（14nm/28nm）が 0.5〜1.1")
nodeState.learningWafers["n14"] = 2_000
let incomeRatio2000 = Engine.derived(state: nodeState).incomePerMinuteYen / income28
print("  学習2,000枚: 収入比 \(num(incomeRatio2000, 3))")
check(incomeRatio2000 > 1.0, "14nm で2,000枚学習すると収入が 28nm を上回る")
nodeState.learningWafers["n14"] = 5_000
Engine.evaluateMilestones(state: &nodeState)
check(nodeState.stats.achievedMilestones["yield_80_n14"] != nil, "学習5,000枚で yield_80_n14 を達成")
let learned28BeforeTick = nodeState.learningWafers["n28"]
let learned14BeforeTick = nodeState.learningWafers["n14"] ?? 0
for _ in 0..<40 {
    Engine.tick(state: &nodeState, dtRealSeconds: 0.25)
}
check((nodeState.learningWafers["n14"] ?? 0) > learned14BeforeTick, "14nm 稼働中は learningWafers[n14] が増える")
check(nodeState.learningWafers["n28"] == learned28BeforeTick, "14nm 稼働中は learningWafers[n28] が変わらない")

print("== 0.5.0. 車載チップ（14nm で Q2×2） ==")
completeResearch(&nodeState, "unlock_eb", startAt: t0)
for instance in nodeState.fab.equipment where instance.modelId == "L1" {
    check(Engine.detachEquipment(state: &nodeState, instanceId: instance.id), "L1 を倉庫へ外せる")
}
check(Engine.buy(state: &nodeState, modelId: "Q2"), "Q2 を1台目購入できる")
check(Engine.buy(state: &nodeState, modelId: "Q2"), "Q2 を2台目購入できる")
check(Engine.canSelectProduct(state: nodeState, productId: "automotive"), "14nm で Q2×2 稼働なら車載チップを選べる")
check(Engine.switchProduct(state: &nodeState, productId: "automotive"), "車載チップへ切り替えられた")
check(Engine.switchNode(state: &nodeState, toNodeId: "n28"), "28nm へ戻せた")
check(nodeState.currentProductId == "logic", "28nm へ戻すと製品は汎用ロジックに戻る")
check(!Engine.canSelectProduct(state: nodeState, productId: "automotive"), "28nm では Q2 が稼働しないので車載チップを選べない")

print("== 0.5.0. 往復 ==")
var roundTripNode = readyFor14nm()
let learned28BeforeRoundTrip = roundTripNode.learningWafers["n28"]
check(Engine.switchNode(state: &roundTripNode, toNodeId: "n14"), "14nm へ移行できた")
roundTripNode.learningWafers["n14"] = 500
check(Engine.switchNode(state: &roundTripNode, toNodeId: "n28"), "28nm へ戻せた")
check(roundTripNode.fab.currentNodeId == "n28", "現在のノードが n28")
check(abs(Engine.derived(state: roundTripNode).lineWPH - 8.5) < 1e-6, "戻した後のラインWPH は 8.5")
check(roundTripNode.learningWafers["n14"] == 500, "learningWafers[n14] = 500 が保持される")
check(roundTripNode.learningWafers["n28"] == learned28BeforeRoundTrip, "learningWafers[n28] は移行前と同じ")

print("== 0.5.0. v3 セーブ互換 ==")
let v3Dir = makeDirectory("v3")
writeObject(encodedObject(GameState.initial()), to: v3Dir.appendingPathComponent(SaveManager.fileName))
var v3Manager = SaveManager(directory: v3Dir)
let v3Loaded = v3Manager.load()
check(v3Loaded != nil, "v3 セーブを読み込める")
check(v3Loaded?.schemaVersion == 3, "v3 セーブの schemaVersion は 3 のまま")
check(v3Loaded?.fab.currentNodeId == "n28", "v3 セーブの現在ノードは n28")

// 0.6.0: 歩留まり異常の原因究明
print("== 0.6.0. カタログ ==")
check(Catalog.excursions.count == 7, "異常の原因は7工程分")
check(Set(Catalog.excursions.map { $0.causeProcess }) == Set(ProcessType.allCases), "原因は全工程をカバー")
check(Catalog.excursions.allSatisfy { !$0.causeName.isEmpty && !$0.symptom.isEmpty && !$0.stage1Hint.isEmpty && !$0.stage2Hint.isEmpty && !$0.stage3Hint.isEmpty && !$0.countermeasureTitle.isEmpty && !$0.learningNote.isEmpty }, "各原因に原因名・兆候・ヒント3段階・対策・学習ノートがある")

print("== 0.6.0. 初期状態では異常なし ==")
var excState = GameState.initial()
check(excState.activeExcursion == nil, "新規開始直後は異常なし")
check(excState.nextExcursionEarliestGameHours == Engine.excursionGraceGameHours, "発生可能時刻の初期値はグレース期間")
let excD0 = Engine.derived(state: excState)
check(excD0.excursionProcess == nil && excD0.excursionYieldLoss == 0, "異常なしでは派生値に影響しない")

print("== 0.6.0. 強制発生（成膜） ==")
let yieldBeforeExc = excD0.lineYield
let wphBeforeExc = excD0.lineWPH
check(Engine.forceStartExcursion(state: &excState, causeProcess: .deposition), "成膜に異常を強制発生できた")
check(!Engine.forceStartExcursion(state: &excState, causeProcess: .cmp), "発生中は二重に発生しない")
let excD1 = Engine.derived(state: excState)
let dropPt = (yieldBeforeExc - excD1.lineYield) * 100
print("  ライン歩留まり: \(num(yieldBeforeExc * 100, 2))% → \(num(excD1.lineYield * 100, 2))%（−\(num(dropPt, 2))pt）")
check(excD1.lineYield < yieldBeforeExc, "異常でライン歩留まりが下がった")
check(dropPt >= 3 && dropPt <= 10, "低下幅は 3〜10pt 級")
check(abs(excD1.excursionYieldLoss - (yieldBeforeExc - excD1.lineYield)) < 1e-9, "内訳の悪化分が実際の低下と一致")
check(excD1.excursionProcess == .deposition, "派生値の原因工程は成膜")
check(abs(excD1.lineWPH - wphBeforeExc) < 1e-9, "異常はラインWPHに影響しない")
for process in ProcessType.allCases where process != .deposition {
    check(abs((excD1.processYields[process] ?? 0) - (excD0.processYields[process] ?? 0)) < 1e-12, "他の工程（\(process.displayName)）の歩留まりは不変")
}
guard let depSpec = Catalog.excursion(for: .deposition) else { fail("成膜の異常スペックが無い") }
let expectedDegraded = 1 - (1 - (excD0.processYields[.deposition] ?? 0)) * depSpec.defectMultiplier
check(abs((excD1.processYields[.deposition] ?? 0) - expectedDegraded) < 1e-9, "成膜の工程歩留まりが欠陥倍率どおりに悪化")

print("== 0.6.0. ヒントと候補（Q1のみ） ==")
check(Engine.bestInspectionGrade(state: excState) == 1, "初期状態の検査グレードは Q1（1）")
check(Engine.excursionCandidates(state: excState).count == 7, "ヒント未開示では候補は全工程（7）")
let hintCost1 = Engine.excursionHintCostYen(state: excState)
let cashBeforeHint = excState.cashYen
check(Engine.revealExcursionHint(state: &excState), "ヒント1段階目を開示できた")
check(abs(cashBeforeHint - excState.cashYen - hintCost1) < 1e-6, "ヒント費用が引かれた")
let cand1 = Engine.excursionCandidates(state: excState)
print("  候補（Q1・1段階）: \(cand1.map { $0.displayName }.joined(separator: "・"))")
check(cand1.count == 3, "Q1のみ・ヒント1段階で候補は3工程")
check(cand1.contains(.deposition), "候補に原因工程（成膜）が含まれる")
check(Engine.revealExcursionHint(state: &excState), "ヒント2段階目を開示できた")
check(Engine.excursionCandidates(state: excState).count == 2, "ヒント2段階で候補は2工程")
check(Engine.revealExcursionHint(state: &excState), "ヒント3段階目を開示できた")
check(Engine.excursionCandidates(state: excState) == [.deposition], "ヒント3段階で原因工程を特定できる")
check(!Engine.revealExcursionHint(state: &excState), "ヒントは3段階まで")

print("== 0.6.0. 対策（外し→正解） ==")
let counterCost = Engine.excursionCountermeasureCostYen(state: excState)
let dailyNet = excD1.incomePerMinuteYen * 24 * Engine.realSecondsPerGameHour / 60
print("  対策費用: \(num(counterCost, 0))円 ／ 純益1日分: \(num(dailyNet, 0))円（収入/分 \(num(excD1.incomePerMinuteYen, 0))円）")
check(counterCost > 0, "対策費用は正の値")
check(counterCost <= dailyNet, "対策費用は純益1日分以下")
let cashBeforeWrong = excState.cashYen
check(Engine.applyExcursionCountermeasure(state: &excState, process: .cmp) == .wrongProcess, "違う工程（CMP）の対策は外れる")
check(abs(cashBeforeWrong - excState.cashYen - counterCost) < 1e-6, "外しても費用だけ引かれる")
check(excState.activeExcursion != nil, "外しても異常は続く")
check(excState.activeExcursion?.wrongGuesses == 1, "外した回数が記録される")
check(abs(Engine.derived(state: excState).lineYield - excD1.lineYield) < 1e-9, "外した後は歩留まりは低下したまま")
let cashBeforeRight = excState.cashYen
check(Engine.applyExcursionCountermeasure(state: &excState, process: .deposition) == .resolved, "原因工程（成膜）の対策で解決")
check(abs(cashBeforeRight - excState.cashYen - counterCost) < 1e-6, "正解でも費用は引かれる")
check(excState.activeExcursion == nil, "解決すると異常が消える")
check(abs(Engine.derived(state: excState).lineYield - yieldBeforeExc) < 1e-9, "解決すると歩留まりが元に戻る")
check(excState.stats.excursionsResolved == 1, "解決数が記録される")
check(excState.nextExcursionEarliestGameHours > excState.gameHoursElapsed, "解決後はクールダウンに入る")
check(Engine.applyExcursionCountermeasure(state: &excState, process: .deposition) == .noActiveExcursion, "異常が無いときの対策は noActiveExcursion")

print("== 0.6.0. 検査グレード（Q2） ==")
var q2State = readyFor14nm()
completeResearch(&q2State, "unlock_eb", startAt: t0)
check(Engine.switchNode(state: &q2State, toNodeId: "n14"), "14nm へ移行できた")
check(Engine.buy(state: &q2State, modelId: "Q2"), "Q2 を購入できた")
check(Engine.bestInspectionGrade(state: q2State) == 2, "Q2 稼働でグレードは 2")
check(Engine.forceStartExcursion(state: &q2State, causeProcess: .deposition), "成膜に異常を発生できた")
check(Engine.revealExcursionHint(state: &q2State), "ヒントを開示できた")
let q2Cand = Engine.excursionCandidates(state: q2State)
print("  候補（Q2・1段階）: \(q2Cand.map { $0.displayName }.joined(separator: "・"))")
check(q2Cand.count == 2 && q2Cand.contains(.deposition), "Q2あり・ヒント1段階で候補は2工程（原因を含む）")

print("== 0.6.0. 検査グレード（Q3） ==")
var q3State = GameState.initial()
q3State.fab.currentNodeId = "n5"
q3State.fab.equipment = [
    EquipmentInstance(modelId: "D3", level: 1, purchasedAt: t0),
    EquipmentInstance(modelId: "Q3", level: 1, purchasedAt: t0),
]
check(Engine.bestInspectionGrade(state: q3State) == 3, "Q3 稼働でグレードは 3")
check(Engine.forceStartExcursion(state: &q3State, causeProcess: .deposition), "成膜に異常を発生できた（n5）")
check(Engine.revealExcursionHint(state: &q3State), "ヒントを開示できた")
check(Engine.excursionCandidates(state: q3State) == [.deposition], "Q3あり・ヒント1段階で原因工程を特定できる")

print("== 0.6.0. オフラインでは発生・進行しない ==")
var offState = GameState.initial()
check(Engine.forceStartExcursion(state: &offState, causeProcess: .etching), "エッチングに異常を発生できた")
let excursionBeforeOffline = offState.activeExcursion
_ = Engine.offlineProgress(state: &offState, elapsedRealSeconds: 3_600)
check(offState.activeExcursion == excursionBeforeOffline, "オフライン進行の前後で異常の状態は変わらない")
var offState2 = GameState.initial()
offState2.gameHoursElapsed = 1_000
Engine.excursionRandomUnit = { 0 }
_ = Engine.offlineProgress(state: &offState2, elapsedRealSeconds: 3_600)
check(offState2.activeExcursion == nil, "抽選が当たる乱数でもオフラインでは発生しない")
Engine.tick(state: &offState2, dtRealSeconds: 0.25, frozenPriceYen: 1_200)
check(offState2.activeExcursion == nil, "frozenPrice の tick では発生しない")
Engine.tick(state: &offState2, dtRealSeconds: 0.25)
check(offState2.activeExcursion != nil, "プレイ中の tick では発生する（乱数を当たる値に固定）")
Engine.excursionRandomUnit = { 0.999_999 }

print("== 0.6.0. 猶予期間 ==")
var graceState = GameState.initial()
Engine.excursionRandomUnit = { 0 }
for _ in 0..<400 { Engine.tick(state: &graceState, dtRealSeconds: 0.25) }
check(graceState.activeExcursion == nil, "新規開始直後（猶予期間内）は発生しない")
Engine.excursionRandomUnit = { 0.999_999 }

print("== 0.6.0. セーブ往復・旧セーブ互換 ==")
var saveExcState = GameState.initial()
check(Engine.forceStartExcursion(state: &saveExcState, causeProcess: .packaging), "パッケージングに異常を発生できた")
check(Engine.revealExcursionHint(state: &saveExcState), "ヒントを開示できた")
check(Engine.applyExcursionCountermeasure(state: &saveExcState, process: .lithography) == .wrongProcess, "外しを1回記録")
let excDir = makeDirectory("excursion")
var excManager = SaveManager(directory: excDir)
do { try excManager.save(saveExcState) } catch { fail("異常ありセーブを保存できない: \(error)") }
let excLoaded = excManager.load()
check(excLoaded?.activeExcursion == saveExcState.activeExcursion, "異常の状態がセーブ往復で保持される")
check(excLoaded?.activeExcursion?.hintsRevealed == 1, "ヒント段階が保持される")
check(excLoaded?.activeExcursion?.wrongGuesses == 1, "外した回数が保持される")
var v3ExcObject = encodedObject(GameState.initial())
v3ExcObject.removeValue(forKey: "activeExcursion")
v3ExcObject.removeValue(forKey: "nextExcursionEarliestGameHours")
if var statsObject = v3ExcObject["stats"] as? [String: Any] {
    statsObject.removeValue(forKey: "excursionsResolved")
    v3ExcObject["stats"] = statsObject
}
let v3ExcDir = makeDirectory("v3-excursion")
writeObject(v3ExcObject, to: v3ExcDir.appendingPathComponent(SaveManager.fileName))
var v3ExcManager = SaveManager(directory: v3ExcDir)
let v3ExcLoaded = v3ExcManager.load()
check(v3ExcLoaded != nil, "0.5.0 形式のセーブ（異常フィールドなし）を読み込める")
check(v3ExcLoaded?.activeExcursion == nil, "旧セーブでは異常なし")
check(v3ExcLoaded?.stats.excursionsResolved == 0, "旧セーブの解決数は 0")
check(v3ExcLoaded?.schemaVersion == 3, "schemaVersion は 3 のまま（異常は decodeIfPresent で互換）")

try? fileManager.removeItem(at: tempRoot)

// MARK: - 1.0 P0: 仕様固定の試算（RouteBuilder の総ステップ数・T_pass）

let p0Combos: [(String, LithoClass?)] = [("標準", nil), ("ArF液浸", .duvImm), ("EUV", .euv), ("High-NA", .highNA)]
for node in Catalog.nodes {
    for (comboName, cls) in p0Combos {
        let steps = RouteBuilder.routeSteps(node: node, lithoClass: cls)
        let passes = RouteBuilder.effectivePasses(node: node, lithoClass: cls)
        check(steps.count == passes.values.reduce(0, +),
              "P0: \(node.displayName)（\(comboName)）ルート総ステップ \(steps.count) がパス合計と一致")
        var counted: [ProcessType: Int] = [:]
        for s in steps { counted[s, default: 0] += 1 }
        check(ProcessType.allCases.allSatisfy { (counted[$0] ?? 0) == (passes[$0] ?? 0) },
              "P0: \(node.displayName)（\(comboName)）工程別の出現回数がパス表と一致")
    }
}
func p0RouteTotal(_ nodeId: String, _ cls: LithoClass?) -> Int {
    RouteBuilder.routeSteps(node: Catalog.node(id: nodeId)!, lithoClass: cls).count
}
check(p0RouteTotal("n28", nil) == 72, "P0: 28nm ルートは 72 ステップ")
check(p0RouteTotal("n14", nil) == 196, "P0: 14nm ルートは 196 ステップ")
check(p0RouteTotal("n7", nil) == 279, "P0: 7nm ルートは 279 ステップ")
check(p0RouteTotal("n7", .euv) == 244, "P0: 7nm EUV ルートは 244 ステップ")
check(p0RouteTotal("n5", nil) == 275, "P0: 5nm ルートは 275 ステップ")
check(p0RouteTotal("n3", nil) == 307, "P0: 3nm ルートは 307 ステップ")
check(p0RouteTotal("n2", nil) == 350, "P0: 2nm ルートは 350 ステップ")
check(p0RouteTotal("n2", .highNA) == 330, "P0: 2nm High-NA ルートは 330 ステップ")
let p0Route28 = RouteBuilder.routeSteps(node: Catalog.node(id: "n28")!, lithoClass: nil)
check(p0Route28.first == .deposition && p0Route28.last == .packaging, "P0: 28nm ルートは成膜で始まり PKG で終わる")

let p0TPass: [(String, Double)] = [
    ("L1", 11.8), ("L2", 6.4), ("L3", 11.0), ("L4", 9.8),
    ("D1", 17.6), ("D2", 11.8), ("D3", 14.7),
    ("E1", 22.1), ("E2", 14.7), ("E3", 44.1),
    ("I1", 17.6), ("I2", 11.8),
    ("C1", 29.4), ("C2", 19.6),
    ("Q1", 14.7), ("Q2", 117.6), ("Q3", 17.6),
    ("P1", 29.4), ("P2", 17.6), ("P3", 44.1),
]
for (modelId, expected) in p0TPass {
    let t = SimCore.tPass(model: Catalog.model(id: modelId)!, level: 1, throughputMultiplier: 1, uptimeAddition: 0)
    check(abs(t - expected) < 0.15, "P0: T_pass \(modelId) = \(String(format: "%.2f", t)) 分（表値 \(expected)）")
}

// MARK: - 1.0 P1: SimCore（ロット離散シミュレーション）

let probeLot = Lot(id: SimCore.lotId(serial: 999), nodeId: "n28", productId: "logic", lithoClass: .duvDry,
                   location: .entry, releasedAtGameMin: 0, learningWafersAtRelease: 0)
check((try? JSONDecoder().decode(Lot.self, from: JSONEncoder().encode(probeLot))) == probeLot,
      "P1: Lot の Codable ラウンドトリップ")
let probeTool = ToolInstance(instance: GameState.initial().fab.equipment[0])
check((try? JSONDecoder().decode(ToolInstance.self, from: JSONEncoder().encode(probeTool))) == probeTool,
      "P1: ToolInstance の Codable ラウンドトリップ")
let probeCell = RailCell(point: GridPoint(x: 3, y: 4), direction: .east, kind: .corner)
check((try? JSONDecoder().decode(RailCell.self, from: JSONEncoder().encode(probeCell))) == probeCell,
      "P1: RailCell の Codable ラウンドトリップ")
let probeStocker = Stocker(origin: GridPoint(x: 1, y: 1), capacity: 40, lotIds: [probeLot.id], handlingGameMin: 10)
check((try? JSONDecoder().decode(Stocker.self, from: JSONEncoder().encode(probeStocker))) == probeStocker,
      "P1: Stocker の Codable ラウンドトリップ")

func p1Run(hours: Double) -> SimCore {
    var sim = SimCore(state: GameState.initial())
    for _ in 0..<Int(hours * 60) { sim.step() }
    return sim
}
let detRunA = p1Run(hours: 120)
let detRunB = p1Run(hours: 120)
check(detRunA.stats.completedWafers == detRunB.stats.completedWafers && detRunA.stats.sumNetYen == detRunB.stats.sumNetYen,
      "P1: SimCore は決定的（同一の初期状態から同一の結果）")

var p1Sim = SimCore(state: GameState.initial())
// 定常測定の運転点: 設計の WIP 上限 200 では、P1 の仮想搬送（24分/移動）のもとで WIP が
// 自己制限域（約75〜115）を振動し、投入レートが測定窓に依存する。§8 の定常等価性の検証では
// 上限を 100 に効かせて WIP を固定し（CONWIP）、投入＝完了に揃えた状態で測る。
p1Sim.wipCap = 100
for _ in 0..<(900 * 60) { p1Sim.step() }   // ウォームアップ 900 ゲーム時間
let p1Snap = p1Sim.stats
for _ in 0..<(1200 * 60) { p1Sim.step() }   // 計測 1200 ゲーム時間
let p1Throughput = (p1Sim.stats.completedWafers - p1Snap.completedWafers) / 1200
check(abs(p1Throughput - 8.5) <= 8.5 * 0.03,
      "P1: 定常スループット \(String(format: "%.3f", p1Throughput)) WPH（現行 8.5 の ±3% 以内）")
let p1ReleaseRate = (p1Sim.stats.releasedWafers - p1Snap.releasedWafers) / 1200
check(abs(p1ReleaseRate - 8.5) <= 8.5 * 0.03,
      "P1: 学習 W の加算 \(String(format: "%.3f", p1ReleaseRate)) 枚/時（現行フロー 8.5 と一致）")
let p1WindowLots = p1Sim.stats.completedLots - p1Snap.completedLots
let p1MeanDetection = p1WindowLots > 0
    ? (p1Sim.stats.sumDetectionRate - p1Snap.sumDetectionRate) / Double(p1WindowLots) : 0
check(p1WindowLots > 0 && abs(p1MeanDetection - 0.775) <= 0.005,
      "P1: 定常検出率 \(String(format: "%.4f", p1MeanDetection))（77.5% ±0.5pt、完了 \(p1WindowLots) ロット）")
check(!p1Sim.stats.firstCompletions.isEmpty, "P1: ロットが完了して精算される")
// 歩留まりの検証は WIP=1 の直行運転で行う（投入順 = 完了順が保証され、学習 W が 0, 25, 50, … と進む）。
// 定常運転では完了順が投入順と一致しない（キューでの追い越し）ため、そちらでは検証しない。
var yieldSim = SimCore(state: GameState.initial())
yieldSim.wipCap = 1
for _ in 0..<(600 * 60) { yieldSim.step() }
check(yieldSim.stats.firstCompletions.count >= 5, "P1: 直行運転で5ロット以上が完了する")
if let first = yieldSim.stats.firstCompletions.first {
    check(abs(first.lotYield - 0.698337) < 0.005,
          "P1: 初回ロット歩留まり \(String(format: "%.4f", first.lotYield))（0.95^7 = 0.6983 ±0.5pt）")
}
if yieldSim.stats.firstCompletions.count >= 5 {
    let avg5 = yieldSim.stats.firstCompletions.prefix(5).reduce(0) { $0 + $1.lotYield } / 5
    check(abs(avg5 - 0.698) <= 0.005,
          "P1: 初期ロット歩留まり平均 \(String(format: "%.4f", avg5))（69.8% ±0.5pt）")
}

// 精算式の等価性: 現行 tick の式を、状態集計値（lineYield / detectionRate）で25枚分に適用した期待値と比較
let eqState = GameState.initial()
let eqDerived = Engine.derived(state: eqState)
let eqNode = Catalog.node(id: "n28")!
let eqProduct = Catalog.product(id: "logic")!
let eqSettle = SimCore.settle(lotYield: eqDerived.lineYield, detectionRate: eqDerived.detectionRate,
                              node: eqNode, product: eqProduct, priceYen: eqDerived.currentPriceYen)
let eqGrossDies = 25.0 * Double(eqProduct.diesPerWafer)
let eqGoodDies = eqGrossDies * eqDerived.lineYield
let eqShippedDefect = (eqGrossDies - eqGoodDies) * (1 - eqDerived.detectionRate)
let eqOutputChips = eqGoodDies + eqShippedDefect
let eqSale = Engine.netSale(chips: eqOutputChips, defectRate: eqShippedDefect / eqOutputChips,
                            priceYen: eqDerived.currentPriceYen, penaltyMultiplier: eqProduct.marketPenaltyMultiplier)
let eqExpectedNet = eqSale.revenueYen - eqOutputChips * eqDerived.currentPriceYen
    * min(max(eqProduct.cogsRate + eqNode.cogsAddition, 0), 0.95)
check(abs(eqSettle.netYen - eqExpectedNet) < 0.01,
      "P1: ロット精算 \(Int(eqSettle.netYen)) 円が現行 tick の式と一致（期待 \(Int(eqExpectedNet)) 円）")

print("HEADLESS CHECK PASSED")
