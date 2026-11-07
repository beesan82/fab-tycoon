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

    // 「なぜ？」内訳（derived の計算途中の値をそのまま保持する）
    /// 検出率の基礎値（稼働中の検査装置の最大値。検査装置が無い場合は 0）
    var detectionBase: Double
    /// 検査能力の余裕度 = 検査WPH ÷ ラインWPH。検査装置が無い・ライン停止時は 0
    var detectionHeadroom: Double
    /// 余裕度による上乗せ幅（上限適用前）= detectionHeadroomBonus定数 × (1 − 1/余裕度)。検査装置が無い場合は 0
    var detectionHeadroomBonus: Double
    /// 工程歩留まりの積
    var processYieldProduct: Double
    /// 学習による欠陥縮小率（1.0 で学習前）
    var learningDefectScale: Double
    /// 製品倍率を掛ける前のライン歩留まり
    var rawLineYield: Double

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
    /// 純売上（市場不良ペナルティ・売上原価控除後）
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
    /// 対応ノード外・研究が必要など（現状は購入不可）
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
    static let inventoryCap = 200_000.0
    static let offlineCapSeconds = 4.0 * 3_600
    static let offlineEfficiency = 0.5
    static let offlineStepSeconds = 60.0
    /// 市況サイクル周期（ゲーム内分。実2.5時間）
    static let marketCycleMinutes = 90_000.0
    static let marketCycleAmplitude = 0.3
    static let walkStep = 0.02
    /// ランダムウォークの間隔（ゲーム内分 = 6ゲーム時間）
    static let walkIntervalMinutes = 360.0
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
    /// 補助金の審査期間（ゲーム内5日）
    static let subsidyReviewHours = 120.0
    /// 補助金のクールダウン（前回交付からゲーム内30日）
    static let subsidyCooldownHours = 720.0
    /// 交付上限は累計設備投資の1/3
    static let subsidyRate = 1.0 / 3.0
    /// 交付可能額が1000万円未満なら申請不可
    static let subsidyMinimumGrantYen = 10_000_000.0
    /// 増床の初回価格（第1ファブ、DESIGN.md §2.7）
    static let expansionBasePriceYen = 3_000_000_000.0
    /// 増床1回ごとの価格倍率
    static let expansionPriceGrowth = 1.6
    /// 増床1回で増えるスロット数
    static let expansionSlotCount = 4

    // MARK: 製品倍率

    static func currentProduct(state: GameState) -> ProductSpec {
        Catalog.product(id: state.currentProductId) ?? Catalog.defaultProduct
    }

    /// 製品ごとの歩留まり倍率（欠陥側に 1/倍率 で効く）
    static func productYieldMultiplier(state: GameState) -> Double {
        currentProduct(state: state).yieldMultiplier
    }

    /// 製品ごとのダイ1個の基準単価（円）
    static func productDiePriceYen(state: GameState) -> Double {
        currentProduct(state: state).diePriceYen
    }

    /// 製品ごとのウェハ1枚あたりのダイ数
    static func productDiesPerWafer(state: GameState) -> Int {
        currentProduct(state: state).diesPerWafer
    }

    /// 製品ごとの売上原価率
    static func productCogsRate(state: GameState) -> Double {
        currentProduct(state: state).cogsRate
    }

    /// 製品ごとの市場不良ペナルティ倍率（ペナルティ額に乗算）
    static func productMarketPenaltyMultiplier(state: GameState) -> Double {
        currentProduct(state: state).marketPenaltyMultiplier
    }

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
        // 製品倍率は欠陥側に効く（倍率 >1 で欠陥が 1/倍率 に縮み、<1 で増える）
        let lineYield = min(max(1 - (1 - rawLineYield) / productYieldMultiplier(state: state), 0), 0.99)

        // 検査スクリーニング：基礎検出率＋検査能力の余裕度
        let inspectionWPH = wph[.inspection] ?? 0
        var detectionRate = 0.0
        var headroom = 0.0
        var headroomBonus = 0.0
        if (units[.inspection] ?? 0) > 0, inspectionWPH > 0 {
            headroom = inspectionWPH / max(lineWPH, 1e-9)
            headroomBonus = detectionHeadroomBonus * (1 - 1 / headroom)
            detectionRate = min(maxDetectionRate, max(0, detectionBase + headroomBonus))
        }
        let shippedDefectFraction = (1 - lineYield) * (1 - detectionRate)
        let shippedTotal = lineYield + shippedDefectFraction
        let shippedYield = shippedTotal > 0 ? lineYield / shippedTotal : 1
        let marketDefectRate = shippedTotal > 0 ? shippedDefectFraction / shippedTotal : 0

        let cycleFactor = 1 + marketCycleAmplitude * sin(2 * Double.pi * state.market.gameTimeMinutes / marketCycleMinutes)
        let price = productDiePriceYen(state: state) * cycleFactor * state.market.walkFactor
        // 純売上（原価・ペナルティ控除後）をウェハ1枚あたりに直したもの
        // = (良品+出荷不良)×単価×(1−原価率) − 出荷不良×単価×1.5×製品倍率
        let penaltyRate = marketDefectPenaltyRate * productMarketPenaltyMultiplier(state: state)
        let dies = Double(productDiesPerWafer(state: state))
        let grossPerWafer = dies * price * (lineYield + shippedDefectFraction)
        let penaltyPerWafer = dies * price * shippedDefectFraction * penaltyRate
        let marginPerWafer = grossPerWafer * (1 - productCogsRate(state: state)) - penaltyPerWafer

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
            incomePerMinuteYen: lineWPH * marginPerWafer * gameMinutesPerRealSecond,
            detectionBase: detectionBase,
            // ライン停止時は余裕度が意味を持たないので 0 として表示する
            detectionHeadroom: lineWPH > 0 ? headroom : 0,
            detectionHeadroomBonus: headroomBonus,
            processYieldProduct: processProduct,
            learningDefectScale: learningDefectScale,
            rawLineYield: rawLineYield
        )
    }

    /// 装置1台の実効歩留まり寄与。改良1レベルごとに欠陥寄与が8%減る
    static func effectiveYieldFactor(_ model: EquipmentModel, level: Int) -> Double {
        1 - (1 - model.yieldFactor) * pow(defectReductionPerLevel, Double(level - 1))
    }

    /// 出荷チップの純売上（不良混入率 defectRate の分だけ販売額の150%×製品倍率を差し引く）
    static func netSale(chips: Double, defectRate: Double, priceYen: Double, penaltyMultiplier: Double)
        -> (revenueYen: Double, defectChips: Double, penaltyYen: Double) {
        let defects = chips * defectRate
        let penalty = defects * priceYen * marketDefectPenaltyRate * penaltyMultiplier
        return (chips * priceYen - penalty, defects, penalty)
    }

    // MARK: Tick

    @discardableResult
    static func tick(state: inout GameState, dtRealSeconds: Double, frozenPriceYen: Double? = nil) -> TickResult {
        guard dtRealSeconds > 0, dtRealSeconds.isFinite else { return .zero }
        let gameMinutes = dtRealSeconds * gameMinutesPerRealSecond

        // 市場時間とランダムウォーク（6ゲーム時間ごとの境界で1歩）
        let before = state.market.gameTimeMinutes
        let after = before + gameMinutes
        state.market.gameTimeMinutes = after
        if frozenPriceYen == nil {
            let crossings = Int(floor(after / walkIntervalMinutes)) - Int(floor(before / walkIntervalMinutes))
            let steps = min(max(crossings, 0), maxWalkStepsPerTick)
            for _ in 0..<steps {
                let factor = state.market.walkFactor * (1 + Double.random(in: -walkStep...walkStep))
                state.market.walkFactor = min(max(factor, walkRange.lowerBound), walkRange.upperBound)
            }
        }

        state.stats.playSeconds += dtRealSeconds
        state.gameHoursElapsed += gameMinutes / 60
        // 補助金の交付はオンライン中のみ進める。offlineProgress は frozenPriceYen を渡して
        // tick を呼ぶので、frozenPriceYen が nil のときだけ精算する（オフラインでは審査が進まない）
        if frozenPriceYen == nil {
            settleSubsidyIfDue(state: &state)
        }
        evaluateMilestones(state: &state)

        let d = derived(state: state)
        let node = currentNode(state: state)
        let price = frozenPriceYen ?? d.currentPriceYen

        // 投入ウェハ（lineWPH はゲーム内1時間あたり）
        let flow = d.lineWPH * gameMinutes / 60
        guard flow > 0 else {
            state.fab.running = false
            return .zero
        }
        state.fab.running = true

        state.learningWafers[node.id, default: 0] += flow
        state.stats.totalWafersInput += flow
        state.fab.wipWafers = (state.fab.wipWafers + flow).truncatingRemainder(dividingBy: 1)

        // 不良は各工程で生まれ、検査で見つかった分だけ廃棄される。残りは良品に混ざって出荷される
        let grossDies = flow * Double(productDiesPerWafer(state: state))
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
        var netYen = 0.0
        if soldChips > 0 {
            let grossYen = soldChips * price
            sale = netSale(chips: soldChips, defectRate: defectMix, priceYen: price,
                           penaltyMultiplier: productMarketPenaltyMultiplier(state: state))
            let cogsYen = grossYen * productCogsRate(state: state)
            netYen = sale.revenueYen - cogsYen
            state.stats.totalGrossSalesYen += grossYen
            state.stats.totalCogsYen += cogsYen
            state.stats.totalShippedChips += soldChips
            state.stats.totalMarketDefectChips += sale.defectChips
            state.stats.totalMarketPenaltyYen += sale.penaltyYen
            recordSale(state: &state, revenueYen: netYen, priceYen: price)
        }
        // 生産・販売で累計値が動いた分を評価する
        evaluateMilestones(state: &state)

        return TickResult(
            producedWafers: flow,
            goodChips: goodDies,
            revenueYen: netYen,
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
        // オフライン中はゲーム内時計・市況位相・プレイ時間を進めない（tick が加算した分をループ後に戻す）
        let savedGameHours = state.gameHoursElapsed
        let savedMarketMinutes = state.market.gameTimeMinutes
        let savedPlaySeconds = state.stats.playSeconds

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
        state.market.gameTimeMinutes = savedMarketMinutes
        state.stats.playSeconds = savedPlaySeconds
        // 不在中に達成した目標は、戻した時計の「今」に達成したものとして記録する
        for (id, hours) in state.stats.achievedMilestones where hours > savedGameHours {
            state.stats.achievedMilestones[id] = savedGameHours
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

    /// 購入できない理由（対応ノード外・研究が必要）
    static func lockReasons(model: EquipmentModel, nodeId: String) -> [String] {
        var reasons: [String] = []
        if !isActive(model, nodeId: nodeId) {
            let nodeName = Catalog.node(id: nodeId)?.displayName ?? nodeId
            reasons.append("対応ノード外（\(nodeName)非対応）")
        }
        if let note = model.unlockNote {
            reasons.append("\(note)が必要（研究で解放・準備中）")
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
        state.subsidy.totalInvestedYen += model.priceYen
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
        state.subsidy.totalInvestedYen += cost
        return true
    }

    @discardableResult
    static func sellEquipment(state: inout GameState, instanceId: UUID) -> Bool {
        // 設置中・倉庫のどちらからでも売却できる
        if let index = state.fab.equipment.firstIndex(where: { $0.id == instanceId }) {
            let refund = sellRefundYen(instance: state.fab.equipment[index])
            state.fab.equipment.remove(at: index)
            state.cashYen += refund
            return true
        }
        if let index = state.fab.storedEquipment.firstIndex(where: { $0.id == instanceId }) {
            let refund = sellRefundYen(instance: state.fab.storedEquipment[index])
            state.fab.storedEquipment.remove(at: index)
            state.cashYen += refund
            return true
        }
        return false
    }

    // MARK: 付け替え（倉庫）

    /// 設置中の装置を倉庫へ外す（無料。レベル・購入日時は保持）
    @discardableResult
    static func detachEquipment(state: inout GameState, instanceId: UUID) -> Bool {
        guard let index = state.fab.equipment.firstIndex(where: { $0.id == instanceId }) else { return false }
        let instance = state.fab.equipment.remove(at: index)
        state.fab.storedEquipment.append(instance)
        return true
    }

    /// 倉庫の装置を再設置できるか（倉庫に存在し、空きスロットがある）
    static func canAttachEquipment(state: GameState, instanceId: UUID) -> Bool {
        state.fab.storedEquipment.contains { $0.id == instanceId } && state.fab.freeSlots > 0
    }

    /// 倉庫の装置をラインに設置する（空きスロットが必要）
    @discardableResult
    static func attachEquipment(state: inout GameState, instanceId: UUID) -> Bool {
        guard state.fab.freeSlots > 0,
              let index = state.fab.storedEquipment.firstIndex(where: { $0.id == instanceId })
        else { return false }
        let instance = state.fab.storedEquipment.remove(at: index)
        state.fab.equipment.append(instance)
        return true
    }

    // MARK: 増床

    /// 次回の増床価格（初回価格 × 1.6^増床回数）
    static func expansionCostYen(state: GameState) -> Double {
        expansionBasePriceYen * pow(expansionPriceGrowth, Double(state.fab.expansionCount))
    }

    static func canExpandFab(state: GameState) -> Bool {
        state.cashYen >= expansionCostYen(state: state)
    }

    /// 増床してスロットを +4 する。補助金の累計設備投資には数えない
    @discardableResult
    static func expandFab(state: inout GameState) -> Bool {
        let cost = expansionCostYen(state: state)
        guard state.cashYen >= cost else { return false }
        state.cashYen -= cost
        state.fab.slots += expansionSlotCount
        state.fab.expansionCount += 1
        return true
    }

    /// 在庫チップを一括売却した場合の純売上（現在の市場不良率を混入率とみなす。売上原価控除後）
    static func inventorySaleValueYen(state: GameState, priceYen: Double) -> Double {
        netSale(chips: state.fab.inventoryChips, defectRate: derived(state: state).marketDefectRate, priceYen: priceYen,
                penaltyMultiplier: productMarketPenaltyMultiplier(state: state)).revenueYen
            - state.fab.inventoryChips * priceYen * productCogsRate(state: state)
    }

    /// 在庫チップを指定価格で一括売却し、純売上（市場不良ペナルティ・売上原価控除後）を返す
    @discardableResult
    static func sellInventory(state: inout GameState, priceYen: Double) -> Double {
        let chips = state.fab.inventoryChips
        guard chips > 0 else { return 0 }
        let sale = netSale(chips: chips, defectRate: derived(state: state).marketDefectRate, priceYen: priceYen,
                           penaltyMultiplier: productMarketPenaltyMultiplier(state: state))
        let grossYen = chips * priceYen
        let cogsYen = grossYen * productCogsRate(state: state)
        let netYen = sale.revenueYen - cogsYen
        state.fab.inventoryChips = 0
        state.stats.totalGrossSalesYen += grossYen
        state.stats.totalCogsYen += cogsYen
        state.stats.totalShippedChips += chips
        state.stats.totalMarketDefectChips += sale.defectChips
        state.stats.totalMarketPenaltyYen += sale.penaltyYen
        recordSale(state: &state, revenueYen: netYen, priceYen: priceYen)
        return netYen
    }

    // MARK: 製品

    /// 所有装置（設置中＋倉庫）のうち modelIds に含まれる台数。要求はファブの設備能力に対する条件なので、
    /// 現在ノードで稼働しているか（isActive）や設置中かどうかは問わない
    static func ownedCount(state: GameState, modelIds: [String]) -> Int {
        (state.fab.equipment + state.fab.storedEquipment).filter { modelIds.contains($0.modelId) }.count
    }

    /// 要求の選択肢のいずれかを満たしていれば充足
    static func isSatisfied(state: GameState, requirement: ProductRequirement) -> Bool {
        requirement.options.contains { ownedCount(state: state, modelIds: $0.modelIds) >= $0.count }
    }

    /// 未充足の要求ラベル（空なら選択可能）
    static func productBlockReasons(state: GameState, productId: String) -> [String] {
        guard let product = Catalog.product(id: productId) else { return ["不明な製品です"] }
        return product.requirements
            .filter { !isSatisfied(state: state, requirement: $0) }
            .map { $0.label }
    }

    static func canSelectProduct(state: GameState, productId: String) -> Bool {
        Catalog.product(id: productId) != nil && productBlockReasons(state: state, productId: productId).isEmpty
    }

    /// 指定製品に切り替えた場合の派生状態（プレビュー用）
    static func derived(state: GameState, asProduct productId: String) -> DerivedState {
        var copy = state
        copy.currentProductId = productId
        return derived(state: copy)
    }

    @discardableResult
    static func switchProduct(state: inout GameState, productId: String) -> Bool {
        guard Catalog.product(id: productId) != nil, productId != state.currentProductId else { return false }
        guard canSelectProduct(state: state, productId: productId) else { return false }
        if state.fab.inventoryChips > 0 {
            // 在庫は旧製品の単価・不良率で精算してから切り替える
            sellInventory(state: &state, priceYen: derived(state: state).currentPriceYen)
        }
        state.currentProductId = productId
        return true
    }

    // MARK: 国庫補助金

    /// 今申請した場合の交付額（累計設備投資の1/3 − 受給済み）
    static func subsidyCapYen(state: GameState) -> Double {
        max(0, state.subsidy.totalInvestedYen * subsidyRate - state.subsidy.totalReceivedYen)
    }

    /// 申請できない理由（nil なら申請可能）
    static func subsidyBlockReason(state: GameState) -> String? {
        if state.subsidy.pendingGrantAtHours != nil { return "審査中です" }
        if let last = state.subsidy.lastGrantAtHours,
           state.gameHoursElapsed - last < subsidyCooldownHours { return "クールダウン中です" }
        if subsidyCapYen(state: state) < subsidyMinimumGrantYen { return "交付可能額が1,000万円未満のため申請できません" }
        return nil
    }

    static func canApplySubsidy(state: GameState) -> Bool { subsidyBlockReason(state: state) == nil }

    @discardableResult
    static func applySubsidy(state: inout GameState) -> Bool {
        guard canApplySubsidy(state: state) else { return false }
        // 申請時点で額を確定する
        state.subsidy.pendingGrantYen = subsidyCapYen(state: state)
        state.subsidy.pendingGrantAtHours = state.gameHoursElapsed + subsidyReviewHours
        return true
    }

    /// 審査期間が明けていれば交付する
    static func settleSubsidyIfDue(state: inout GameState) {
        guard let due = state.subsidy.pendingGrantAtHours, state.gameHoursElapsed >= due else { return }
        let grant = state.subsidy.pendingGrantYen
        state.cashYen += grant
        state.subsidy.totalReceivedYen += grant
        state.subsidy.lastGrantAtHours = state.gameHoursElapsed
        state.subsidy.pendingGrantYen = 0
        state.subsidy.pendingGrantAtHours = nil
    }

    // 緊急救済枠：工程の装置がなくなりラインが止まり、買い戻す資金もない詰み状態からの救済

    static let emergencyMarginRate = 0.2   // 緊急交付の余裕分（最安機種価格の20%）

    /// 指定工程で、現行ノードで購入可能な機種（lockReasons が空）の最安価格。該当機種がなければ nil
    static func cheapestModelPriceYen(state: GameState, process: ProcessType) -> Double? {
        Catalog.models(for: process)
            .filter { lockReasons(model: $0, nodeId: state.fab.currentNodeId).isEmpty }
            .map { $0.priceYen }
            .min()
    }

    /// ラインが止まっている工程（稼働装置0台）について、現行ノードで購入可能な機種の最安価格。
    /// 全工程が稼働中なら nil。要求判定と同じく、対象は設置済み台数ではなく derived の稼働台数で見る。
    static func cheapestStoppedProcessPriceYen(state: GameState) -> Double? {
        let d = derived(state: state)
        return ProcessType.allCases
            .filter { d.units($0) == 0 }
            .compactMap { cheapestModelPriceYen(state: state, process: $0) }
            .min()
    }

    /// 緊急救済で今すぐ交付できる額（常に > 0）。対象外なら nil。
    /// 対象：ラインWPHが0（いずれかの工程に稼働装置がない）かつ、所持金が「止まっている工程の最安機種価格」未満。
    /// 額：最安機種価格 − 所持金 ＋ 最安機種価格 × emergencyMarginRate（余裕分）
    static func emergencyGrantYen(state: GameState) -> Double? {
        let d = derived(state: state)
        guard d.lineWPH <= 0, let cheapest = cheapestStoppedProcessPriceYen(state: state) else { return nil }
        guard state.cashYen < cheapest else { return nil }
        return cheapest - state.cashYen + cheapest * emergencyMarginRate
    }

    static func canApplyEmergencySubsidy(state: GameState) -> Bool {
        emergencyGrantYen(state: state) != nil
    }

    @discardableResult
    static func applyEmergencySubsidy(state: inout GameState) -> Bool {
        guard let amount = emergencyGrantYen(state: state) else { return false }
        // 審査なしで即時交付。受給累計に数え、通常補助金のクールダウン起算点もここに置く
        // （緊急交付を使うと通常申請も30日不可）。緊急枠自体はクールダウンで止めない
        // （複数工程が止まっている場合に繰り返し使って立て直すための救済措置のため）。
        state.cashYen += amount
        state.subsidy.totalReceivedYen += amount
        state.subsidy.lastGrantAtHours = state.gameHoursElapsed
        return true
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
        copy.fab.storedEquipment.removeAll { $0.id == instanceId }
        return copy
    }

    private static func processOf(instanceId: UUID, in state: GameState) -> ProcessType? {
        guard let instance = (state.fab.equipment + state.fab.storedEquipment).first(where: { $0.id == instanceId })
        else { return nil }
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

    /// 指定装置を売却した場合の、その装置の工程の稼働台数（derived 基準）
    static func activeUnitsAfterSelling(state: GameState, instanceId: UUID) -> Int {
        guard let process = processOf(instanceId: instanceId, in: state) else { return 0 }
        return derived(state: stateAfterSelling(state, instanceId: instanceId)).units(process)
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

// MARK: - マイルストーン

extension Engine {
    /// 設置中＋倉庫の全装置の最大レベル（装置が無ければ 0）
    static func maxOwnedLevel(state: GameState) -> Int {
        (state.fab.equipment + state.fab.storedEquipment).map { $0.level }.max() ?? 0
    }

    static func milestoneAchieved(_ spec: MilestoneSpec, state: GameState, derived: DerivedState) -> Bool {
        switch spec.condition {
        case .firstInvestment:
            return state.subsidy.totalInvestedYen > 0
        case .lineWPHAtLeast(let target):
            return derived.lineWPH >= target
        case .lineYieldAtLeast(let target):
            return derived.lineYield >= target
        case .detectionRateAtLeast(let target):
            return derived.detectionRate >= target
        case .cumulativeWafersAtLeast(let target):
            return state.stats.totalWafersInput >= target
        case .cumulativeGrossSalesAtLeast(let target):
            return state.stats.totalGrossSalesYen >= target
        case .expansionCountAtLeast(let target):
            return state.fab.expansionCount >= target
        case .maxLevelAtLeast(let target):
            return maxOwnedLevel(state: state) >= target
        case .subsidyReceived:
            return state.subsidy.totalReceivedYen > 0
        case .nonDefaultProduct:
            return state.currentProductId != Catalog.defaultProductId
        }
    }

    /// 未達成のマイルストーンを評価し、達成したものを記録する。今回達成した id を返す
    @discardableResult
    static func evaluateMilestones(state: inout GameState) -> [String] {
        let pending = Catalog.milestones.filter { state.stats.achievedMilestones[$0.id] == nil }
        guard !pending.isEmpty else { return [] }
        let d = derived(state: state)
        var achieved: [String] = []
        for spec in pending where milestoneAchieved(spec, state: state, derived: d) {
            state.stats.achievedMilestones[spec.id] = state.gameHoursElapsed
            achieved.append(spec.id)
        }
        return achieved
    }

    /// Catalog 順で最初の未達成マイルストーン（全達成なら nil）
    static func nextMilestone(state: GameState) -> MilestoneSpec? {
        Catalog.milestones.first { state.stats.achievedMilestones[$0.id] == nil }
    }

    /// 達成までの進捗（0...1）
    static func milestoneProgress(state: GameState, derived: DerivedState, spec: MilestoneSpec) -> Double {
        func ratio(_ current: Double, _ target: Double) -> Double {
            target > 0 ? min(max(current / target, 0), 1) : 1
        }
        switch spec.condition {
        case .firstInvestment, .subsidyReceived, .nonDefaultProduct:
            return milestoneAchieved(spec, state: state, derived: derived) ? 1 : 0
        case .lineWPHAtLeast(let target):
            return ratio(derived.lineWPH, target)
        case .lineYieldAtLeast(let target):
            return ratio(derived.lineYield, target)
        case .detectionRateAtLeast(let target):
            return ratio(derived.detectionRate, target)
        case .cumulativeWafersAtLeast(let target):
            return ratio(state.stats.totalWafersInput, target)
        case .cumulativeGrossSalesAtLeast(let target):
            return ratio(state.stats.totalGrossSalesYen, target)
        case .expansionCountAtLeast(let target):
            return ratio(Double(state.fab.expansionCount), Double(target))
        case .maxLevelAtLeast(let target):
            return ratio(Double(maxOwnedLevel(state: state)), Double(target))
        }
    }

    /// 進捗の表示用テキスト（現在値・目標値）
    static func milestoneProgressTexts(state: GameState, derived: DerivedState, spec: MilestoneSpec)
        -> (current: String, target: String) {
        let achieved = milestoneAchieved(spec, state: state, derived: derived)
        switch spec.condition {
        case .firstInvestment:
            return (achieved ? "達成" : "未達成", "設備投資を行う")
        case .subsidyReceived:
            return (achieved ? "達成" : "未達成", "補助金を受け取る")
        case .nonDefaultProduct:
            return (achieved ? "達成" : "未達成", "他製品を製造する")
        case .lineWPHAtLeast(let target):
            return (MoneyFormat.decimal(derived.lineWPH, digits: 2), MoneyFormat.decimal(target, digits: 2))
        case .lineYieldAtLeast(let target):
            return (MoneyFormat.percent(derived.lineYield), MoneyFormat.percent(target))
        case .detectionRateAtLeast(let target):
            return (MoneyFormat.percent(derived.detectionRate), MoneyFormat.percent(target))
        case .cumulativeWafersAtLeast(let target):
            return (MoneyFormat.count(state.stats.totalWafersInput) + "枚", MoneyFormat.count(target) + "枚")
        case .cumulativeGrossSalesAtLeast(let target):
            return (MoneyFormat.yen(state.stats.totalGrossSalesYen), MoneyFormat.yen(target))
        case .expansionCountAtLeast(let target):
            return ("\(state.fab.expansionCount)回", "\(target)回")
        case .maxLevelAtLeast(let target):
            return ("Lv\(maxOwnedLevel(state: state))", "Lv\(target)")
        }
    }
}

// MARK: - 図鑑

/// 図鑑の1エントリ（表示用）
struct GlossaryEntryInfo: Identifiable, Equatable {
    enum Kind: Equatable {
        case equipment
        case process
        case term
    }

    let id: String
    let kind: Kind
    /// 装置=モデル名、工程=displayName、用語=term
    let title: String
    let unlocked: Bool
    /// stats.readGlossaryIds に含まれる
    let isRead: Bool
}

extension Engine {
    static func isGlossaryUnlocked(_ unlock: GlossaryUnlock, state: GameState) -> Bool {
        switch unlock {
        case .always:
            return true
        case .ownModel(let modelId):
            return ownedCount(state: state, modelIds: [modelId]) > 0
        case .milestone(let id):
            return state.stats.achievedMilestones[id] != nil
        case .grossSalesAtLeast(let yen):
            return state.stats.totalGrossSalesYen >= yen
        case .defectDetected:
            return state.stats.totalDefectChips > 0
        case .marketDefectOccurred:
            return state.stats.totalMarketDefectChips > 0
        }
    }

    /// 装置（Catalog.equipment 順）→工程（allCases 順）→用語（Catalog.glossaryTerms 順）の全エントリ
    static func glossaryEntries(state: GameState) -> [GlossaryEntryInfo] {
        let read = state.stats.readGlossaryIds
        let equipment = Catalog.equipment.map { model -> GlossaryEntryInfo in
            let id = Catalog.equipmentGlossaryId(model.id)
            return GlossaryEntryInfo(id: id, kind: .equipment, title: model.name,
                                     unlocked: isGlossaryUnlocked(.ownModel(model.id), state: state),
                                     isRead: read.contains(id))
        }
        let processes = ProcessType.allCases.map { process -> GlossaryEntryInfo in
            let id = Catalog.processGlossaryId(process)
            return GlossaryEntryInfo(id: id, kind: .process, title: process.displayName,
                                     unlocked: true, isRead: read.contains(id))
        }
        let terms = Catalog.glossaryTerms.map { term in
            GlossaryEntryInfo(id: term.id, kind: .term, title: term.term,
                              unlocked: isGlossaryUnlocked(term.unlock, state: state),
                              isRead: read.contains(term.id))
        }
        return equipment + processes + terms
    }

    static func glossaryUnlockedCount(state: GameState) -> Int {
        glossaryEntries(state: state).filter { $0.unlocked }.count
    }
}

// MARK: - 次の一手アドバイザー

extension Engine {
    /// 今いちばん効く次の一手を1行で返す（優先順位の高いルールから順に判定）
    static func advisorMessage(state: GameState, derived: DerivedState) -> String {
        // 1. ライン停止
        if derived.lineWPH <= 0 {
            let stopped = ProcessType.allCases.first { derived.units($0) == 0 } ?? derived.bottleneck
            var message = "ラインが止まっています。\(stopped?.displayName ?? "いずれかの工程")の装置がありません。装置タブで最安の装置を設置しましょう。"
            if emergencyGrantYen(state: state) != nil {
                message += " 統計タブの緊急補助金で立て直せます。"
            }
            return message
        }

        // 2. 補助金を申請できる
        if canApplySubsidy(state: state) {
            return "国庫補助金を申請できます（交付予定 \(MoneyFormat.yen(subsidyCapYen(state: state)))）。統計タブから申請しましょう。"
        }

        // 3. 在庫が上限間近
        if !state.fab.autoSellEnabled && state.fab.inventoryChips > inventoryCap * 0.9 {
            return "在庫が上限に近づいています（\(MoneyFormat.percent(state.fab.inventoryChips / inventoryCap, digits: 0))）。一括売却か自動販売への切り替えがおすすめです。"
        }

        // 4. ボトルネックに最安の購入可能機を足す
        if let process = derived.bottleneck,
           let model = Catalog.models(for: process)
               .filter({ lockReasons(model: $0, nodeId: state.fab.currentNodeId).isEmpty })
               .min(by: { $0.priceYen < $1.priceYen }) {
            let after = lineWPHAfterAdding(state: state, modelId: model.id)
            if after > derived.lineWPH + 1e-9 {
                if state.fab.freeSlots <= 0 {
                    if canExpandFab(state: state) {
                        return "設置スロットが満杯です。増床（\(MoneyFormat.yen(expansionCostYen(state: state)))）すると、ボトルネックの\(process.displayName)に装置を足せるようになります。"
                    }
                    return "設置スロットが満杯です。余裕のある工程の装置を倉庫へ外して\(process.displayName)に付け替えるか、増床の資金を貯めましょう。"
                }
                if state.cashYen >= model.priceYen {
                    return "ボトルネックの\(process.displayName)に\(model.name)（\(MoneyFormat.yen(model.priceYen))）を足すと、ラインWPH \(MoneyFormat.decimal(derived.lineWPH, digits: 2)) → \(MoneyFormat.decimal(after, digits: 2)) になります。"
                }
                return "次の一手は\(process.displayName)の\(model.name)（\(MoneyFormat.yen(model.priceYen))）です。あと\(MoneyFormat.yen(model.priceYen - state.cashYen))で購入できます。"
            }
        }

        // 5. 検出率が低い
        if derived.detectionRate < 0.80 && derived.units(.inspection) != 0 {
            return "検出率が\(MoneyFormat.percent(derived.detectionRate))です。検査工程を増強すると、市場不良のペナルティを減らせます。"
        }

        // 6. 次の目標
        if let spec = nextMilestone(state: state) {
            let progress = milestoneProgress(state: state, derived: derived, spec: spec)
            return "次の目標は『\(spec.title)』です（進捗 \(MoneyFormat.percent(progress, digits: 0))）。"
        }
        return "全ての目標を達成しました。ラインは順調に稼働しています。"
    }
}
