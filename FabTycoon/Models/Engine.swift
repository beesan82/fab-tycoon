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
    /// 検査ボーナス込み・クランプ済みの歩留まり
    var currentYield: Double
    /// 学習曲線のみの歩留まり（ボーナス前）
    var learnedYield: Double
    var inspectionBonus: Double
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
    var revenueYen: Double

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
    /// 実1秒 = ゲーム内1分
    static let gameMinutesPerRealSecond = 1.0
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

        var inspectionBonus = 0.0
        for instance in state.fab.equipment {
            guard let model = Catalog.model(id: instance.modelId), isActive(model, nodeId: node.id) else { continue }
            let passes = passCount(for: model.process, node: node, topLitho: topLitho)
            wph[model.process, default: 0] += model.nominalWPH * levelMultiplier(instance.level) / Double(passes)
            units[model.process, default: 0] += 1
            if model.process == .inspection {
                inspectionBonus = max(inspectionBonus, model.yieldBonus)
            }
        }
        for process in ProcessType.allCases {
            wph[process] = (wph[process] ?? 0) * uptime
        }

        let lineWPH = ProcessType.allCases.map { wph[$0] ?? 0 }.min() ?? 0
        let ranked = ProcessType.allCases.sorted { a, b in
            let wa = wph[a] ?? 0
            let wb = wph[b] ?? 0
            return wa != wb ? wa < wb : a.order < b.order
        }

        let learned = state.learningWafers[node.id] ?? 0
        let learnedYield = node.yieldMax - (node.yieldMax - node.yieldInit) * exp(-learned / node.learnWafers)
        let currentYield = min(max(learnedYield + inspectionBonus, 0), 0.99)

        let cycleFactor = 1 + marketCycleAmplitude * sin(2 * Double.pi * state.market.gameTimeMinutes / marketCycleMinutes)
        let price = node.chipBasePriceYen * cycleFactor * state.market.walkFactor
        let marginPerWafer = Double(node.diesPerWafer) * currentYield * price - node.waferCostYen

        return DerivedState(
            nodeId: node.id,
            processWPH: wph,
            activeUnits: units,
            lithoPasses: passCount(for: .lithography, node: node, topLitho: topLitho),
            lineWPH: lineWPH,
            bottleneck: ranked.first,
            secondBottleneck: ranked.count > 1 ? ranked[1] : nil,
            currentYield: currentYield,
            learnedYield: learnedYield,
            inspectionBonus: inspectionBonus,
            isLearning: learnedYield < node.yieldMax - 0.005,
            cycleFactor: cycleFactor,
            walkFactor: state.market.walkFactor,
            currentPriceYen: price,
            incomePerMinuteYen: lineWPH * marginPerWafer
        )
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

        let chips = flow * Double(node.diesPerWafer)
        let good = chips * d.currentYield
        let defect = chips * (1 - d.currentYield)
        state.stats.totalGoodChips += good
        state.stats.totalDefectChips += defect
        state.stats.defectLossYen += defect * price

        var soldChips = 0.0
        if state.fab.autoSellEnabled {
            soldChips = good
        } else {
            state.fab.inventoryChips += good
            if state.fab.inventoryChips > inventoryCap {
                soldChips = state.fab.inventoryChips - inventoryCap
                state.fab.inventoryChips = inventoryCap
            }
        }
        let revenue = soldChips * price
        if revenue > 0 {
            recordSale(state: &state, revenueYen: revenue, priceYen: price)
        }

        return TickResult(producedWafers: flow, goodChips: good, revenueYen: revenue)
    }

    private static func recordSale(state: inout GameState, revenueYen: Double, priceYen: Double) {
        state.cashYen += revenueYen
        state.stats.totalRevenueYen += revenueYen
        state.market.recentAvgPriceYen =
            state.market.recentAvgPriceYen * (1 - recentPriceSmoothing) + priceYen * recentPriceSmoothing
    }

    // MARK: オフライン

    static func offlineProgress(state: inout GameState, elapsedRealSeconds: Double) -> OfflineReport {
        let capped = min(max(elapsedRealSeconds, 0), offlineCapSeconds)
        let effective = capped * offlineEfficiency
        let frozenPrice = state.market.recentAvgPriceYen

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

    /// 在庫チップを指定価格で一括売却し、売上額を返す
    @discardableResult
    static func sellInventory(state: inout GameState, priceYen: Double) -> Double {
        let chips = state.fab.inventoryChips
        guard chips > 0 else { return 0 }
        state.fab.inventoryChips = 0
        let revenue = chips * priceYen
        recordSale(state: &state, revenueYen: revenue, priceYen: priceYen)
        return revenue
    }

    // MARK: プレビュー

    /// 指定モデルを1台追加した場合のラインWPH（資金・スロットは無視）
    static func lineWPHAfterAdding(state: GameState, modelId: String) -> Double {
        var copy = state
        copy.fab.equipment.append(EquipmentInstance(modelId: modelId))
        return derived(state: copy).lineWPH
    }

    /// 指定装置を1段階改良した場合のラインWPH（資金は無視）
    static func lineWPHAfterUpgrading(state: GameState, instanceId: UUID) -> Double {
        var copy = state
        if let index = copy.fab.equipment.firstIndex(where: { $0.id == instanceId }) {
            copy.fab.equipment[index].level = min(copy.fab.equipment[index].level + 1, maxLevel)
        }
        return derived(state: copy).lineWPH
    }

    /// 指定装置を売却した場合のラインWPH
    static func lineWPHAfterSelling(state: GameState, instanceId: UUID) -> Double {
        var copy = state
        copy.fab.equipment.removeAll { $0.id == instanceId }
        return derived(state: copy).lineWPH
    }
}
