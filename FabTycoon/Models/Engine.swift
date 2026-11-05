import Foundation

// MARK: - 派生状態・結果型

/// GameState から純粋に計算される表示・シミュレーション用の値
struct DerivedState: Equatable {
    var nodeId: String
    /// 工程ごとの実効WPH（稼働率適用済み）
    var processWPH: [ProcessType: Double]
    /// 工程ごとの稼働中装置台数
    var activeUnits: [ProcessType: Int]
    /// 露光工程で実際に使われているパス数
    var lithoPasses: Int
    var lineWPH: Double
    var bottleneck: ProcessType?
    var secondBottleneck: ProcessType?
    /// 互換用。lineYield と同値（ライン歩留まり・検査前）
    var currentYield: Double
    /// 学習曲線のみの歩留まり（従来式）
    var learnedYield: Double
    /// 工程ごとの工程歩留まり（稼働装置0台の工程は 0）
    var processYields: [ProcessType: Double]
    /// ライン歩留まり（検査前）= 1 − (1 − Π工程歩留まり) × 学習による欠陥縮小率
    var lineYield: Double
    /// 検査で不良を見つけて廃棄できる割合
    var detectionRate: Double
    /// 総生産ダイに対する出荷不良ダイの割合
    var shippedDefectFraction: Double
    /// 出荷したチップのうち良品の割合
    var shippedYield: Double
    /// 出荷したチップのうち不良の割合（市場不良率）
    var marketDefectRate: Double
    var isLearning: Bool
    var cycleFactor: Double
    var walkFactor: Double
    var currentPriceYen: Double
    /// 実時間1分あたりの純収入（円）
    var incomePerMinuteYen: Double

    func wph(_ process: ProcessType) -> Double { processWPH[process] ?? 0 }
    func units(_ process: ProcessType) -> Int { activeUnits[process] ?? 0 }

    var maxProcessWPH: Double { processWPH.values.max() ?? 0 }
    var marketIndex: Double { cycleFactor * walkFactor }
    var marketCondition: MarketCondition { MarketCondition(index: marketIndex) }
}

enum MarketCondition: Equatable {
    case boom
    case normal
    case slump

    init(index: Double) {
        if index >= 1.1 {
            self = .boom
        } else if index <= 0.9 {
            self = .slump
        } else {
            self = .normal
        }
    }

    var label: String {
        switch self {
        case .boom: return "好況"
        case .normal: return "平常"
        case .slump: return "不況"
        }
    }
}

struct TickResult: Equatable {
    var producedWafers: Double
    var goodChips: Double
    /// 純売上（市場不良ペナルティ控除後）
    var revenueYen: Double
    /// 販売分に含まれていた不良チップ数
    var shippedDefectChips: Double = 0
    var marketPenaltyYen: Double = 0

    static let zero = TickResult(producedWafers: 0, goodChips: 0, revenueYen: 0)
}

struct OfflineReport: Identifiable, Equatable {
    let id = UUID()
    /// 上限適用後の不在時間（実秒）
    var elapsedSeconds: Double
    /// 効率適用後にシミュレートした時間（実秒）
    var effectiveSeconds: Double
    var producedWafers: Double
    var goodChips: Double
    var revenueYen: Double
}

enum BuyBlockReason: Equatable {
    case unknownModel
    /// 対応ノード外・研究が必要など（スライス1では購入不可）
    case locked([String])
    case noFreeSlot
    case insufficientCash(shortfallYen: Double)

    var isLock: Bool {
        switch self {
        case .unknownModel, .locked: return true
        case .noFreeSlot, .insufficientCash: return false
        }
    }
}

// MARK: - エンジン

enum Engine {
    static let uptime = 0.85
    /// 実1秒 = ゲーム内10分（×600）。生産単位は WPH（ゲーム内1時間あたり枚数）
    static let gameMinutesPerRealSecond = 10.0
    static let inventoryCap = 10_000.0
    static let offlineCapSeconds = 4.0 * 3_600
    static let offlineEfficiency = 0.5
    static let offlineStepSeconds = 60.0
    /// 市況サイクル周期（ゲーム内分 = 1週間）
    static let marketCycleMinutes = 10_080.0
    static let marketCycleAmplitude = 0.3
    static let walkStep = 0.05
    static let walkRange = 0.6...1.5
    static let maxWalkStepsPerTick = 500
    static let maxLevel = 5
    static let upgradeCostRate = 0.2
    static let sellRefundRate = 0.5
    static let recentPriceSmoothing = 0.1
    /// 改良1レベルごとの欠陥寄与の残存率（−8%/Lv）
    static let defectReductionPerLevel = 0.92
    /// 検出率の上限
    static let maxDetectionRate = 0.95
    /// 検査能力の余裕度による検出率の上乗せ幅
    static let detectionHeadroomBonus = 0.30
    /// 市場不良1個あたりの返品・対応コスト（販売額に対する倍率）
    static let marketDefectPenaltyRate = 1.5

    // 次ラウンドの製品選択機能のための継ぎ目。現在は全て 1.0（製品選択UIは未実装）
    /// 製品ごとの歩留まり倍率（lineYield の最終段に乗算）
    static let productYieldMultiplier = 1.0
    /// 製品ごとの単価倍率（currentPriceYen に乗算）
    static let productPriceMultiplier = 1.0
    /// 製品ごとの市場不良ペナルティ倍率（ペナルティ額に乗算）
    static let productMarketPenaltyMultiplier = 1.0

    // MARK: 派生計算

    static func currentNode(state: GameState) -> NodeSpec {
        Catalog.node(id: state.fab.currentNodeId) ?? Catalog.defaultNode
    }

    static func isActive(_ model: EquipmentModel, nodeId: String) -> Bool {
        model.supports(nodeId: nodeId)
    }

    static func levelMultiplier(_ level: Int) -> Double {
        1 + 0.1 * Double(level - 1)
    }

    /// 稼働中の露光機のうち最上位の露光クラス
    static func topLithoClass(state: GameState) -> LithoClass? {
        let nodeId = state.fab.currentNodeId
        return state.fab.equipment
            .compactMap { Catalog.model(id: $0.modelId) }
            .filter { $0.process == .lithography && isActive($0, nodeId: nodeId) }
            .compactMap { $0.lithoClass }
            .max()
    }

    static func passCount(for process: ProcessType, node: NodeSpec, topLitho: LithoClass?) -> Int {
        if process == .lithography, let litho = topLitho, let override = node.lithoPassOverrides[litho] {
            return max(1, override)
        }
        return max(1, node.passes[process] ?? 1)
    }

    /// 1台あたりの実効WPH（稼働率適用前）。現在ノード非対応なら 0
    static func unitWPH(model: EquipmentModel, level: Int, state: GameState) -> Double {
        let node = currentNode(state: state)
        guard isActive(model, nodeId: node.id) else { return 0 }
        let passes = passCount(for: model.process, node: node, topLitho: topLithoClass(state: state))
        return model.nominalWPH * levelMultiplier(level) / Double(passes)
    }

    static func derived(state: GameState) -> DerivedState {
        let node = currentNode(state: state)
        let topLitho = topLithoClass(state: state)

        var wph: [ProcessType: Double] = [:]
        var units: [ProcessType: Int] = [:]
        for process in ProcessType.allCases {
            wph[process] = 0
            units[process] = 0
        }

        // 工程歩留まり用：unitWPH（稼働率適用前）で重み付けした effFactor の合計
        var weightedFactor: [ProcessType: Double] = [:]
        var detectionBase = 0.0
        for instance in state.fab.equipment {
            guard let model = Catalog.model(id: instance.modelId), isActive(model, nodeId: node.id) else { continue }
            let passes = passCount(for: model.process, node: node, topLitho: topLitho)
            let unit = model.nominalWPH * levelMultiplier(instance.level) / Double(passes)
            wph[model.process, default: 0] += unit
            units[model.process, default: 0] += 1
            weightedFactor[model.process, default: 0] += unit * effectiveYieldFactor(model, level: instance.level)
            if model.process == .inspection {
                detectionBase = max(detectionBase, model.detectionBase)
            }
        }
        var processYields: [ProcessType: Double] = [:]
        for process in ProcessType.allCases {
            let raw = wph[process] ?? 0
            processYields[process] = (units[process] ?? 0) > 0 && raw > 0 ? (weightedFactor[process] ?? 0) / raw : 0
            wph[process] = raw * uptime
        }

        let lineWPH = ProcessType.allCases.map { wph[$0] ?? 0 }.min() ?? 0
        let ranked = ProcessType.allCases.sorted { a, b in
            let wa = wph[a] ?? 0
            let wb = wph[b] ?? 0
            return wa != wb ? wa < wb : a.order < b.order
        }

        // 学習曲線は「欠陥の縮小」として効く（開始時 1.0）
        let learned = state.learningWafers[node.id] ?? 0
        let learnedYield = node.yieldMax - (node.yieldMax - node.yieldInit) * exp(-learned / node.learnWafers)
        let learningDefectScale = node.yieldInit < 1 ? (1 - learnedYield) / (1 - node.yieldInit) : 0
        let processProduct = ProcessType.allCases.reduce(1.0) { $0 * (processYields[$1] ?? 0) }
        let rawLineYield = 1 - (1 - processProduct) * learningDefectScale
        let lineYield = min(max(rawLineYield * productYieldMultiplier, 0), 0.99)

        // 検査スクリーニング：基礎検出率＋検査能力の余裕度
        let inspectionWPH = wph[.inspection] ?? 0
        var detectionRate = 0.0
        if (units[.inspection] ?? 0) > 0, inspectionWPH > 0 {
            let headroom = inspectionWPH / max(lineWPH, 1e-9)
            detectionRate = min(maxDetectionRate, max(0, detectionBase + detectionHeadroomBonus * (1 - 1 / headroom)))
        }
        let shippedDefectFraction = (1 - lineYield) * (1 - detectionRate)
        let shippedTotal = lineYield + shippedDefectFraction
        let shippedYield = shippedTotal > 0 ? lineYield / shippedTotal : 1
        let marketDefectRate = shippedTotal > 0 ? shippedDefectFraction / shippedTotal : 0

        let cycleFactor = 1 + marketCycleAmplitude * sin(2 * Double.pi * state.market.gameTimeMinutes / marketCycleMinutes)
        let price = node.chipBasePriceYen * cycleFactor * state.market.walkFactor * productPriceMultiplier
        // 純売上 = (良品+出荷不良)×単価 − 出荷不良×単価×1.5×製品倍率 をウェハ1枚あたりに直したもの
        let penaltyRate = marketDefectPenaltyRate * productMarketPenaltyMultiplier
        let marginPerWafer = Double(node.diesPerWafer) * price
            * (lineYield + shippedDefectFraction * (1 - penaltyRate)) - node.waferCostYen

        return DerivedState(
            nodeId: node.id,
            processWPH: wph,
            activeUnits: units,
            lithoPasses: passCount(for: .lithography, node: node, topLitho: topLitho),
            lineWPH: lineWPH,
            bottleneck: ranked.first,
            secondBottleneck: ranked.count > 1 ? ranked[1] : nil,
            currentYield: lineYield,
            learnedYield: learnedYield,
            processYields: processYields,
            lineYield: lineYield,
            detectionRate: detectionRate,
            shippedDefectFraction: shippedDefectFraction,
            shippedYield: shippedYield,
            marketDefectRate: marketDefectRate,
            isLearning: learnedYield < node.yieldMax - 0.005,
            cycleFactor: cycleFactor,
            walkFactor: state.market.walkFactor,
            currentPriceYen: price,
            // lineWPH はゲーム内1時間あたり → 実1分 = ゲーム内 gameMinutesPerRealSecond 時間
            incomePerMinuteYen: lineWPH * marginPerWafer * gameMinutesPerRealSecond
        )
    }

    /// 装置1台の実効歩留まり寄与。改良1レベルごとに欠陥寄与が8%減る
    static func effectiveYieldFactor(_ model: EquipmentModel, level: Int) -> Double {
        1 - (1 - model.yieldFactor) * pow(defectReductionPerLevel, Double(level - 1))
    }

    /// 出荷チップの純売上（不良混入率 defectRate の分だけ販売額の150%×製品倍率を差し引く）
    static func netSale(chips: Double, defectRate: Double, priceYen: Double)
        -> (revenueYen: Double, defectChips: Double, penaltyYen: Double) {
        let defects = chips * defectRate
        let penalty = defects * priceYen * marketDefectPenaltyRate * productMarketPenaltyMultiplier
        return (chips * priceYen - penalty, defects, penalty)
    }

    // MARK: Tick

    @discardableResult
    static func tick(state: inout GameState, dtRealSeconds: Double, frozenPriceYen: Double? = nil) -> TickResult {
        guard dtRealSeconds > 0, dtRealSeconds.isFinite else { return .zero }
        let gameMinutes = dtRealSeconds * gameMinutesPerRealSecond

        // 市場時間とランダムウォーク（ゲーム内1時間境界ごと）
        let before = state.market.gameTimeMinutes
        let after = before + gameMinutes
        state.market.gameTimeMinutes = after
        if frozenPriceYen == nil {
            let crossings = Int(floor(after / 60)) - Int(floor(before / 60))
            let steps = min(max(crossings, 0), maxWalkStepsPerTick)
            for _ in 0..<steps {
                let factor = state.market.walkFactor * (1 + Double.random(in: -walkStep...walkStep))
                state.market.walkFactor = min(max(factor, walkRange.lowerBound), walkRange.upperBound)
            }
        }

        state.stats.playSeconds += dtRealSeconds
        state.gameHoursElapsed += gameMinutes / 60

        let d = derived(state: state)
        let node = currentNode(state: state)
        let price = frozenPriceYen ?? d.currentPriceYen

        // 投入ウェハ（lineWPH はゲーム内1時間あたり）
        var flow = d.lineWPH * gameMinutes / 60
        if node.waferCostYen > 0, flow * node.waferCostYen > state.cashYen {
            flow = max(0, state.cashYen / node.waferCostYen)
        }
        guard flow > 0 else {
            state.fab.running = false
            return .zero
        }
        state.fab.running = true

        let materialCost = flow * node.waferCostYen
        state.cashYen = max(0, state.cashYen - materialCost)
        state.learningWafers[node.id, default: 0] += flow
        state.stats.totalWafersInput += flow
        state.fab.wipWafers = (state.fab.wipWafers + flow).truncatingRemainder(dividingBy: 1)

        // 不良は各工程で生まれ、検査で見つかった分だけ廃棄される。残りは良品に混ざって出荷される
        let grossDies = flow * Double(node.diesPerWafer)
        let goodDies = grossDies * d.lineYield
        let defectDies = grossDies - goodDies
        let detectedDies = defectDies * d.detectionRate
        let shippedDefectDies = defectDies - detectedDies
        state.stats.totalGoodChips += goodDies
        state.stats.totalDefectChips += detectedDies
        state.stats.defectLossYen += detectedDies * price

        let outputChips = goodDies + shippedDefectDies
        let defectMix = outputChips > 0 ? shippedDefectDies / outputChips : 0
        var soldChips = 0.0
        if state.fab.autoSellEnabled {
            soldChips = outputChips
        } else {
            // 不良は区別できないので在庫に混ざる
            state.fab.inventoryChips += outputChips
            if state.fab.inventoryChips > inventoryCap {
                soldChips = state.fab.inventoryChips - inventoryCap
                state.fab.inventoryChips = inventoryCap
            }
        }
        var sale = (revenueYen: 0.0, defectChips: 0.0, penaltyYen: 0.0)
        if soldChips > 0 {
            sale = netSale(chips: soldChips, defectRate: defectMix, priceYen: price)
            state.stats.totalShippedChips += soldChips
            state.stats.totalMarketDefectChips += sale.defectChips
            state.stats.totalMarketPenaltyYen += sale.penaltyYen
            recordSale(state: &state, revenueYen: sale.revenueYen, priceYen: price)
        }

        return TickResult(
            producedWafers: flow,
            goodChips: goodDies,
            revenueYen: sale.revenueYen,
            shippedDefectChips: sale.defectChips,
            marketPenaltyYen: sale.penaltyYen
        )
    }

    private static func recordSale(state: inout GameState, revenueYen: Double, priceYen: Double) {
        // 不良が多すぎると純売上がマイナスになりうるため、現金は0で下げ止める
        state.cashYen = max(0, state.cashYen + revenueYen)
        state.stats.totalRevenueYen += revenueYen
        state.market.recentAvgPriceYen =
            state.market.recentAvgPriceYen * (1 - recentPriceSmoothing) + priceYen * recentPriceSmoothing
    }

    // MARK: オフライン

    static func offlineProgress(state: inout GameState, elapsedRealSeconds: Double) -> OfflineReport {
        let capped = min(max(elapsedRealSeconds, 0), offlineCapSeconds)
        let effective = capped * offlineEfficiency
        let frozenPrice = state.market.recentAvgPriceYen
        // オフライン中はゲーム内時計を進めない（tick が加算した分をループ後に戻す）
        let savedGameHours = state.gameHoursElapsed

        var remaining = effective
        var produced = 0.0
        var good = 0.0
        var revenue = 0.0
        while remaining > 0 {
            let step = min(offlineStepSeconds, remaining)
            let result = tick(state: &state, dtRealSeconds: step, frozenPriceYen: frozenPrice)
            produced += result.producedWafers
            good += result.goodChips
            revenue += result.revenueYen
            remaining -= step
        }
        state.gameHoursElapsed = savedGameHours

        return OfflineReport(
            elapsedSeconds: capped,
            effectiveSeconds: effective,
            producedWafers: produced,
            goodChips: good,
            revenueYen: revenue
        )
    }

    // MARK: 売買

    static func upgradeCostYen(state: GameState, instance: EquipmentInstance) -> Double? {
        guard instance.level < maxLevel, let model = Catalog.model(id: instance.modelId) else { return nil }
        return model.priceYen * upgradeCostRate * Double(instance.level)
    }

    static func sellRefundYen(instance: EquipmentInstance) -> Double {
        guard let model = Catalog.model(id: instance.modelId) else { return 0 }
        return model.priceYen * sellRefundRate
    }

    /// スライス1で購入できない理由（対応ノード外・研究が必要）
    static func lockReasons(model: EquipmentModel, nodeId: String) -> [String] {
        var reasons: [String] = []
        if !isActive(model, nodeId: nodeId) {
            let nodeName = Catalog.node(id: nodeId)?.displayName ?? nodeId
            reasons.append("対応ノード外（\(nodeName)非対応）")
        }
        if let note = model.unlockNote {
            reasons.append("\(note)が必要（スライス2以降）")
        }
        return reasons
    }

    static func buyBlockReason(state: GameState, modelId: String) -> BuyBlockReason? {
        guard let model = Catalog.model(id: modelId) else { return .unknownModel }
        let locks = lockReasons(model: model, nodeId: state.fab.currentNodeId)
        if !locks.isEmpty { return .locked(locks) }
        if state.fab.freeSlots <= 0 { return .noFreeSlot }
        if state.cashYen < model.priceYen {
            return .insufficientCash(shortfallYen: model.priceYen - state.cashYen)
        }
        return nil
    }

    static func canBuy(state: GameState, modelId: String) -> Bool {
        buyBlockReason(state: state, modelId: modelId) == nil
    }

    @discardableResult
    static func buy(state: inout GameState, modelId: String, now: Date = Date()) -> Bool {
        guard canBuy(state: state, modelId: modelId), let model = Catalog.model(id: modelId) else { return false }
        state.cashYen -= model.priceYen
        state.fab.equipment.append(EquipmentInstance(modelId: modelId, level: 1, purchasedAt: now))
        return true
    }

    @discardableResult
    static func upgrade(state: inout GameState, instanceId: UUID) -> Bool {
        guard let index = state.fab.equipment.firstIndex(where: { $0.id == instanceId }),
              let cost = upgradeCostYen(state: state, instance: state.fab.equipment[index]),
              state.cashYen >= cost
        else { return false }
        state.cashYen -= cost
        state.fab.equipment[index].level += 1
        return true
    }

    @discardableResult
    static func sellEquipment(state: inout GameState, instanceId: UUID) -> Bool {
        guard let index = state.fab.equipment.firstIndex(where: { $0.id == instanceId }) else { return false }
        let refund = sellRefundYen(instance: state.fab.equipment[index])
        state.fab.equipment.remove(at: index)
        state.cashYen += refund
        return true
    }

    /// 在庫チップを一括売却した場合の純売上（現在の市場不良率を混入率とみなす）
    static func inventorySaleValueYen(state: GameState, priceYen: Double) -> Double {
        netSale(chips: state.fab.inventoryChips, defectRate: derived(state: state).marketDefectRate, priceYen: priceYen).revenueYen
    }

    /// 在庫チップを指定価格で一括売却し、純売上（市場不良ペナルティ控除後）を返す
    @discardableResult
    static func sellInventory(state: inout GameState, priceYen: Double) -> Double {
        let chips = state.fab.inventoryChips
        guard chips > 0 else { return 0 }
        let sale = netSale(chips: chips, defectRate: derived(state: state).marketDefectRate, priceYen: priceYen)
        state.fab.inventoryChips = 0
        state.stats.totalShippedChips += chips
        state.stats.totalMarketDefectChips += sale.defectChips
        state.stats.totalMarketPenaltyYen += sale.penaltyYen
        recordSale(state: &state, revenueYen: sale.revenueYen, priceYen: priceYen)
        return sale.revenueYen
    }

    // MARK: プレビュー

    private static func stateAfterAdding(_ state: GameState, modelId: String) -> GameState {
        var copy = state
        copy.fab.equipment.append(EquipmentInstance(modelId: modelId))
        return copy
    }

    private static func stateAfterUpgrading(_ state: GameState, instanceId: UUID) -> GameState {
        var copy = state
        if let index = copy.fab.equipment.firstIndex(where: { $0.id == instanceId }) {
            copy.fab.equipment[index].level = min(copy.fab.equipment[index].level + 1, maxLevel)
        }
        return copy
    }

    private static func stateAfterSelling(_ state: GameState, instanceId: UUID) -> GameState {
        var copy = state
        copy.fab.equipment.removeAll { $0.id == instanceId }
        return copy
    }

    private static func processOf(instanceId: UUID, in state: GameState) -> ProcessType? {
        guard let instance = state.fab.equipment.first(where: { $0.id == instanceId }) else { return nil }
        return Catalog.model(id: instance.modelId)?.process
    }

    /// 指定モデルを1台追加した場合のラインWPH（資金・スロットは無視）
    static func lineWPHAfterAdding(state: GameState, modelId: String) -> Double {
        derived(state: stateAfterAdding(state, modelId: modelId)).lineWPH
    }

    /// 指定装置を1段階改良した場合のラインWPH（資金は無視）
    static func lineWPHAfterUpgrading(state: GameState, instanceId: UUID) -> Double {
        derived(state: stateAfterUpgrading(state, instanceId: instanceId)).lineWPH
    }

    /// 指定装置を売却した場合のラインWPH
    static func lineWPHAfterSelling(state: GameState, instanceId: UUID) -> Double {
        derived(state: stateAfterSelling(state, instanceId: instanceId)).lineWPH
    }

    /// 指定モデルを1台追加した場合の、そのモデルの工程の工程歩留まり
    static func processYieldAfterAdding(state: GameState, modelId: String) -> Double {
        guard let process = Catalog.model(id: modelId)?.process else { return 0 }
        return derived(state: stateAfterAdding(state, modelId: modelId)).processYields[process] ?? 0
    }

    /// 指定装置を1段階改良した場合の、その装置の工程の工程歩留まり
    static func processYieldAfterUpgrading(state: GameState, instanceId: UUID) -> Double {
        guard let process = processOf(instanceId: instanceId, in: state) else { return 0 }
        return derived(state: stateAfterUpgrading(state, instanceId: instanceId)).processYields[process] ?? 0
    }

    /// 指定装置を売却した場合の、その装置の工程の工程歩留まり
    static func processYieldAfterSelling(state: GameState, instanceId: UUID) -> Double {
        guard let process = processOf(instanceId: instanceId, in: state) else { return 0 }
        return derived(state: stateAfterSelling(state, instanceId: instanceId)).processYields[process] ?? 0
    }

    static func lineYieldAfterAdding(state: GameState, modelId: String) -> Double {
        derived(state: stateAfterAdding(state, modelId: modelId)).lineYield
    }

    static func lineYieldAfterUpgrading(state: GameState, instanceId: UUID) -> Double {
        derived(state: stateAfterUpgrading(state, instanceId: instanceId)).lineYield
    }

    static func lineYieldAfterSelling(state: GameState, instanceId: UUID) -> Double {
        derived(state: stateAfterSelling(state, instanceId: instanceId)).lineYield
    }

    static func detectionRateAfterAdding(state: GameState, modelId: String) -> Double {
        derived(state: stateAfterAdding(state, modelId: modelId)).detectionRate
    }

    static func detectionRateAfterUpgrading(state: GameState, instanceId: UUID) -> Double {
        derived(state: stateAfterUpgrading(state, instanceId: instanceId)).detectionRate
    }

    static func detectionRateAfterSelling(state: GameState, instanceId: UUID) -> Double {
        derived(state: stateAfterSelling(state, instanceId: instanceId)).detectionRate
    }
}
