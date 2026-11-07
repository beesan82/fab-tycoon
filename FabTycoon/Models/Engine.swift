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
    /// 発生中の歩留まり異常の原因工程（異常が無ければ nil）
    var excursionProcess: ProcessType?
    /// 歩留まり異常によるライン歩留まりの低下分（比率。異常が無ければ 0）
    var excursionYieldLoss: Double

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

/// 歩留まり異常の対策を実行した結果
enum ExcursionCountermeasureResult: Equatable {
    case resolved
    case wrongProcess
    case insufficientCash
    case noActiveExcursion
}

// MARK: - エンジン

enum Engine {
    static let uptime = 0.85
    /// 実1秒 = ゲーム内10分（×600）。生産単位は WPH（ゲーム内1時間あたり枚数）
    static let gameMinutesPerRealSecond = 10.0
    static let inventoryCap = 200_000.0
    /// 1ゲーム時間あたりの実秒数（= 6秒）
    static let realSecondsPerGameHour = 60.0 / gameMinutesPerRealSecond
    /// オフライン上限の基礎値（研究で加算される）
    static let baseOfflineCapSeconds = 4.0 * 3_600
    /// オフライン効率の基礎値（研究で加算される）
    static let baseOfflineEfficiency = 0.5
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
    /// 補助金の審査期間（実12分）
    static let subsidyReviewSeconds = 720.0
    /// 補助金のクールダウン（前回交付から実72分）
    static let subsidyCooldownSeconds = 4_320.0
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
    /// 歩留まり異常：新規開始から発生しない期間（ゲーム内時間。実24分相当）
    static let excursionGraceGameHours = 240.0
    /// 歩留まり異常：発生間隔の期待値（ゲーム内時間。実2.5時間相当）
    static let excursionMeanIntervalGameHours = 1_500.0
    /// 歩留まり異常：解決後、次が発生するまでの最短間隔（ゲーム内時間。実1.5時間相当）
    static let excursionCooldownGameHours = 900.0
    /// 歩留まり異常：対策費用の下限
    static let excursionMinimumCostYen = 5_000_000.0
    /// 歩留まり異常の発生抽選用の乱数源（0以上1未満）。テストで差し替え可能
    static var excursionRandomUnit: () -> Double = { Double.random(in: 0..<1) }

    // MARK: 製品倍率

    static func currentProduct(state: GameState) -> ProductSpec {
        Catalog.product(id: state.currentProductId) ?? Catalog.defaultProduct
    }

    /// 製品ごとの歩留まり倍率（欠陥側に 1/倍率 で効く）
    static func productYieldMultiplier(state: GameState) -> Double {
        currentProduct(state: state).yieldMultiplier
    }

    /// ダイ1個の基準単価（円）= 製品のダイ単価 × 現在ノードの単価倍率
    static func productDiePriceYen(state: GameState) -> Double {
        currentProduct(state: state).diePriceYen * nodePriceMultiplier(state: state)
    }

    /// 製品ごとのウェハ1枚あたりのダイ数
    static func productDiesPerWafer(state: GameState) -> Int {
        currentProduct(state: state).diesPerWafer
    }

    /// 製品単体の売上原価率（ノード加算前）
    static func productCogsRate(state: GameState) -> Double {
        currentProduct(state: state).cogsRate
    }

    // MARK: ノード経済

    /// 現在ノードのダイ単価倍率
    static func nodePriceMultiplier(state: GameState) -> Double {
        currentNode(state: state).priceMultiplier
    }

    /// 実際に適用する売上原価率 = 製品の原価率 + 現在ノードの加算（0...0.95）
    static func cogsRate(state: GameState) -> Double {
        cogsRate(state: state, productId: state.currentProductId)
    }

    /// 指定製品を現在ノードで作った場合の売上原価率（表示用）
    static func cogsRate(state: GameState, productId: String) -> Double {
        let product = Catalog.product(id: productId) ?? Catalog.defaultProduct
        return min(max(product.cogsRate + currentNode(state: state).cogsAddition, 0), 0.95)
    }

    /// 指定製品を現在ノードで作った場合のダイ単価（市況適用前、表示用）
    static func diePriceYen(state: GameState, productId: String) -> Double {
        let product = Catalog.product(id: productId) ?? Catalog.defaultProduct
        return product.diePriceYen * nodePriceMultiplier(state: state)
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

    /// 1台あたりの実効WPH（稼働率適用前、研究のスループット倍率は適用済み）。現在ノード非対応なら 0
    static func unitWPH(model: EquipmentModel, level: Int, state: GameState) -> Double {
        let node = currentNode(state: state)
        guard isActive(model, nodeId: node.id) else { return 0 }
        let passes = passCount(for: model.process, node: node, topLitho: topLithoClass(state: state))
        let throughput = researchEffects(state: state).throughputMultiplier
        return model.nominalWPH * levelMultiplier(level) / Double(passes) * throughput
    }

    static func derived(state: GameState) -> DerivedState {
        let node = currentNode(state: state)
        let topLitho = topLithoClass(state: state)
        let fx = researchEffects(state: state)

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
            // スループット倍率は unitWPH 側に含まれる（ここで重ねて掛けない）
            let unit = unitWPH(model: model, level: instance.level, state: state)
            wph[model.process, default: 0] += unit
            units[model.process, default: 0] += 1
            // 研究による欠陥寄与の縮小は装置ごとの (1 − 実効寄与) に掛ける
            let factor = 1 - (1 - effectiveYieldFactor(model, level: instance.level)) * fx.yieldDefectMultiplier
            weightedFactor[model.process, default: 0] += unit * factor
            if model.process == .inspection {
                detectionBase = max(detectionBase, model.detectionBase)
            }
        }
        var processYields: [ProcessType: Double] = [:]
        for process in ProcessType.allCases {
            let raw = wph[process] ?? 0
            processYields[process] = (units[process] ?? 0) > 0 && raw > 0 ? (weightedFactor[process] ?? 0) / raw : 0
            wph[process] = raw * min(uptime + fx.uptimeAddition, 0.99)
        }

        let lineWPH = ProcessType.allCases.map { wph[$0] ?? 0 }.min() ?? 0
        let ranked = ProcessType.allCases.sorted { a, b in
            let wa = wph[a] ?? 0
            let wb = wph[b] ?? 0
            return wa != wb ? wa < wb : a.order < b.order
        }

        // 学習曲線は「欠陥の縮小」として効く（開始時 1.0）
        let learned = state.learningWafers[node.id] ?? 0
        let learnedYield = node.yieldMax - (node.yieldMax - node.yieldInit) * exp(-learned / (node.learnWafers * fx.learnWafersMultiplier))
        let learningDefectScale = node.yieldInit < 1 ? (1 - learnedYield) / (1 - node.yieldInit) : 0
        let processProduct = ProcessType.allCases.reduce(1.0) { $0 * (processYields[$1] ?? 0) }
        // 歩留まり異常：原因工程の欠陥は学習では縮まない独立の欠陥として、
        // 工程歩留まりの積から差し引く形で加算する（工程歩留まりの表示も悪化させる）
        var excursionProcess: ProcessType? = nil
        var excursionDefectAdd = 0.0
        if let excursion = state.activeExcursion, let spec = Catalog.excursion(id: excursion.specId) {
            excursionProcess = spec.causeProcess
            let causeYield = processYields[spec.causeProcess] ?? 0
            if (units[spec.causeProcess] ?? 0) > 0, causeYield > 0 {
                let degraded = max(0, 1 - (1 - causeYield) * spec.defectMultiplier)
                excursionDefectAdd = processProduct * (1 - degraded / causeYield)
                processYields[spec.causeProcess] = degraded
            }
        }
        let rawLineYield = 1 - ((1 - processProduct) * learningDefectScale + excursionDefectAdd)
        // 製品倍率は欠陥側に効く（倍率 >1 で欠陥が 1/倍率 に縮み、<1 で増える）
        let lineYield = min(max(1 - (1 - rawLineYield) / productYieldMultiplier(state: state), 0), 0.99)
        // 異常が無かった場合との差（「なぜ？」内訳の表示用）
        let rawLineYieldWithoutExcursion = 1 - (1 - processProduct) * learningDefectScale
        let lineYieldWithoutExcursion = min(max(1 - (1 - rawLineYieldWithoutExcursion) / productYieldMultiplier(state: state), 0), 0.99)
        let excursionYieldLoss = max(0, lineYieldWithoutExcursion - lineYield)

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
        let marginPerWafer = grossPerWafer * (1 - cogsRate(state: state)) - penaltyPerWafer

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
            rawLineYield: rawLineYield,
            excursionProcess: excursionProcess,
            excursionYieldLoss: excursionYieldLoss
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
        // 補助金の審査は実時間で進む（オフライン中も時計は進むので、復帰直後の tick で交付される）。
        // offlineProgress は frozenPriceYen を渡して tick を呼ぶので、そのシミュレーション中は精算しない
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
        // 歩留まり異常の発生抽選はプレイ中のみ（オフライン進行の frozenPrice 経路では発生しない）
        if frozenPriceYen == nil {
            maybeStartExcursion(state: &state, dtGameHours: gameMinutes / 60, derived: d)
        }

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
            let cogsYen = grossYen * cogsRate(state: state)
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

    /// オフライン上限（基礎値＋研究による加算）
    static func offlineCapSeconds(state: GameState) -> Double {
        baseOfflineCapSeconds + researchEffects(state: state).offlineCapAdditionalSeconds
    }

    /// オフライン効率（基礎値＋研究による加算）
    static func offlineEfficiency(state: GameState) -> Double {
        baseOfflineEfficiency + researchEffects(state: state).offlineEfficiencyAddition
    }

    static func offlineProgress(state: inout GameState, elapsedRealSeconds: Double) -> OfflineReport {
        let capped = min(max(elapsedRealSeconds, 0), offlineCapSeconds(state: state))
        let effective = capped * offlineEfficiency(state: state)
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
    static func lockReasons(model: EquipmentModel, state: GameState) -> [String] {
        let nodeId = state.fab.currentNodeId
        // 解放研究があり、完了済みか
        let researchDone = model.unlockResearchId.map { state.research.completedIds.contains($0) } ?? false
        var reasons: [String] = []
        if !isActive(model, nodeId: nodeId) {
            if researchDone,
               let firstNode = Catalog.nodes.first(where: { model.supportedNodeIds.contains($0.id) }) {
                // 研究で解放済み：稼働できる最も若いノードを案内する
                reasons.append("\(firstNode.displayName) で稼働")
            } else {
                let nodeName = Catalog.node(id: nodeId)?.displayName ?? nodeId
                reasons.append("対応ノード外（\(nodeName)非対応）")
            }
        }
        if model.unlockResearchId != nil {
            if !researchDone {
                reasons.append("\(model.unlockNote ?? "")が必要（研究で解放）")
            }
        } else if let note = model.unlockNote {
            // 研究がまだ実装されていない装置
            reasons.append("\(note)が必要（研究で解放・準備中）")
        }
        return reasons
    }

    static func buyBlockReason(state: GameState, modelId: String) -> BuyBlockReason? {
        guard let model = Catalog.model(id: modelId) else { return .unknownModel }
        let locks = lockReasons(model: model, state: state)
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
            - state.fab.inventoryChips * priceYen * cogsRate(state: state)
    }

    /// 在庫チップを指定価格で一括売却し、純売上（市場不良ペナルティ・売上原価控除後）を返す
    @discardableResult
    static func sellInventory(state: inout GameState, priceYen: Double) -> Double {
        let chips = state.fab.inventoryChips
        guard chips > 0 else { return 0 }
        let sale = netSale(chips: chips, defectRate: derived(state: state).marketDefectRate, priceYen: priceYen,
                           penaltyMultiplier: productMarketPenaltyMultiplier(state: state))
        let grossYen = chips * priceYen
        let cogsYen = grossYen * cogsRate(state: state)
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

    /// 所有装置（設置中＋倉庫）のうち modelIds に含まれる台数（図鑑の解放・ショップの所持台数用）。
    /// 稼働しているかどうかは問わない
    static func ownedCount(state: GameState, modelIds: [String]) -> Int {
        (state.fab.equipment + state.fab.storedEquipment).filter { modelIds.contains($0.modelId) }.count
    }

    /// 設置中の装置のうち modelIds に含まれ、現在のノードで稼働している台数
    static func activeCount(state: GameState, modelIds: [String]) -> Int {
        let nodeId = state.fab.currentNodeId
        return state.fab.equipment.filter { instance in
            guard modelIds.contains(instance.modelId), let model = Catalog.model(id: instance.modelId) else { return false }
            return isActive(model, nodeId: nodeId)
        }.count
    }

    /// 要求の選択肢のいずれかを満たしていれば充足（設置中かつ現在のノードで稼働している台数で判定）
    static func isSatisfied(state: GameState, requirement: ProductRequirement) -> Bool {
        requirement.options.contains { activeCount(state: state, modelIds: $0.modelIds) >= $0.count }
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

    // MARK: 待機（スタンバイ）

    /// 設置中だが、モデルが現在のノードに非対応で稼働していない
    static func isStandby(_ instance: EquipmentInstance, state: GameState) -> Bool {
        guard state.fab.equipment.contains(where: { $0.id == instance.id }),
              let model = Catalog.model(id: instance.modelId)
        else { return false }
        return !isActive(model, nodeId: state.fab.currentNodeId)
    }

    /// 工程別の待機台数
    static func standbyCount(state: GameState, process: ProcessType) -> Int {
        let nodeId = state.fab.currentNodeId
        return state.fab.equipment.filter { instance in
            guard let model = Catalog.model(id: instance.modelId), model.process == process else { return false }
            return !isActive(model, nodeId: nodeId)
        }.count
    }

    // MARK: ノード切替

    /// ノードの解放に必要な研究の解放キー（キーが無いノードは研究不要）
    private static let nodeUnlockKeys: [String: String] = ["n14": "node14"]

    /// ノードを解放する研究（研究不要・未実装なら nil）
    static func nodeUnlockResearch(nodeId: String) -> ResearchSpec? {
        guard let key = nodeUnlockKeys[nodeId] else { return nil }
        return Catalog.research.first { $0.effect == .unlock(key) }
    }

    /// ノードの解放研究が完了しているか（研究不要のノードは true）
    static func isNodeUnlocked(state: GameState, nodeId: String) -> Bool {
        guard let key = nodeUnlockKeys[nodeId] else { return true }
        return isResearchUnlocked(state: state, key: key)
    }

    /// ノードへ切り替えられない理由（nil なら切替可能）
    static func nodeSwitchBlockReason(state: GameState, toNodeId: String) -> String? {
        guard let node = Catalog.node(id: toNodeId) else { return "不明なノードです" }
        if toNodeId == state.fab.currentNodeId { return "現在のノードです" }
        guard Catalog.isPlayable(nodeId: toNodeId) else { return "\(node.displayName)は今後のアップデートで解放されます" }
        if !isNodeUnlocked(state: state, nodeId: toNodeId) {
            let researchName = nodeUnlockResearch(nodeId: toNodeId)?.name ?? "\(node.displayName)プロセス"
            return "研究「\(researchName)」が必要です"
        }
        return nil
    }

    static func canSwitchNode(state: GameState, toNodeId: String) -> Bool {
        nodeSwitchBlockReason(state: state, toNodeId: toNodeId) == nil
    }

    /// ノード切替後の状態（在庫売却なし。製品が選択不可なら既定製品に戻す）
    private static func stateAfterSwitchingNode(_ state: GameState, toNodeId: String) -> GameState {
        var copy = state
        copy.fab.currentNodeId = toNodeId
        if !canSelectProduct(state: copy, productId: copy.currentProductId) {
            copy.currentProductId = Catalog.defaultProductId
        }
        return copy
    }

    /// 指定ノードへ切り替えた場合の派生状態（プレビュー用。製品が戻る場合は戻した後の値）
    static func derived(state: GameState, asNode nodeId: String) -> DerivedState {
        derived(state: stateAfterSwitchingNode(state, toNodeId: nodeId))
    }

    /// 指定ノードで稼働台数 0 になる工程
    static func stoppedProcesses(state: GameState, atNode nodeId: String) -> [ProcessType] {
        let d = derived(state: state, asNode: nodeId)
        return ProcessType.allCases.filter { d.units($0) == 0 }
    }

    /// 移行確認シート用の警告文
    static func nodeSwitchWarnings(state: GameState, toNodeId: String) -> [String] {
        guard let target = Catalog.node(id: toNodeId) else { return [] }
        let after = stateAfterSwitchingNode(state, toNodeId: toNodeId)
        var warnings: [String] = []
        for process in stoppedProcesses(state: state, atNode: toNodeId) {
            var text = "\(process.displayName)の装置が稼働しません（ラインが停止します）"
            if let model = Catalog.models(for: process)
                .filter({ $0.supports(nodeId: toNodeId) })
                .min(by: { $0.priceYen < $1.priceYen }) {
                text += "。\(model.name)（\(model.id)）の購入が必要です"
                if let researchId = model.unlockResearchId, !state.research.completedIds.contains(researchId) {
                    text += "（\(model.unlockNote ?? "研究")で解放）"
                } else if state.cashYen < model.priceYen {
                    text += "（資金があと\(MoneyFormat.yen(model.priceYen - state.cashYen))不足）"
                }
            }
            warnings.append(text)
        }
        let standby = after.fab.equipment.filter { isStandby($0, state: after) }.count
        if standby > 0 {
            warnings.append("\(standby)台の装置が\(target.displayName)非対応のため待機になります")
        }
        if after.currentProductId != state.currentProductId {
            let name = currentProduct(state: state).name
            warnings.append("現在の製品『\(name)』は移行先で製造できないため、\(Catalog.defaultProduct.name)に戻ります")
        }
        if state.fab.inventoryChips > 0 {
            warnings.append("在庫チップは現在の単価で売却されます")
        }
        return warnings
    }

    /// ノードを切り替える。在庫は旧ノードの単価で精算し、新ノードで作れない製品は既定製品に戻す
    @discardableResult
    static func switchNode(state: inout GameState, toNodeId: String) -> Bool {
        guard canSwitchNode(state: state, toNodeId: toNodeId) else { return false }
        if state.fab.inventoryChips > 0 {
            sellInventory(state: &state, priceYen: derived(state: state).currentPriceYen)
        }
        state.fab.currentNodeId = toNodeId
        if !canSelectProduct(state: state, productId: state.currentProductId) {
            state.currentProductId = Catalog.defaultProductId
        }
        evaluateMilestones(state: &state)
        return true
    }

    // MARK: 国庫補助金

    /// 今申請した場合の交付額（累計設備投資の1/3 − 受給済み）
    static func subsidyCapYen(state: GameState) -> Double {
        max(0, state.subsidy.totalInvestedYen * subsidyRate - state.subsidy.totalReceivedYen)
    }

    /// 申請できない理由（nil なら申請可能）
    static func subsidyBlockReason(state: GameState, now: Date = Date()) -> String? {
        if state.subsidy.pendingGrantAt != nil { return "審査中です" }
        if subsidyCooldownRemainingSeconds(state: state, now: now) != nil { return "クールダウン中です" }
        if subsidyCapYen(state: state) < subsidyMinimumGrantYen { return "交付可能額が1,000万円未満のため申請できません" }
        return nil
    }

    static func canApplySubsidy(state: GameState, now: Date = Date()) -> Bool {
        subsidyBlockReason(state: state, now: now) == nil
    }

    @discardableResult
    static func applySubsidy(state: inout GameState, now: Date = Date()) -> Bool {
        guard canApplySubsidy(state: state, now: now) else { return false }
        // 申請時点で額を確定する
        state.subsidy.pendingGrantYen = subsidyCapYen(state: state)
        state.subsidy.pendingGrantAt = now.addingTimeInterval(subsidyReviewSeconds)
        return true
    }

    /// 審査期間が明けていれば交付する（実時間基準なので何度呼んでもよい）
    static func settleSubsidyIfDue(state: inout GameState, now: Date = Date()) {
        guard let due = state.subsidy.pendingGrantAt, due <= now else { return }
        let grant = state.subsidy.pendingGrantYen
        state.cashYen += grant
        state.subsidy.totalReceivedYen += grant
        state.subsidy.lastGrantAt = now
        state.subsidy.pendingGrantYen = 0
        state.subsidy.pendingGrantAt = nil
    }

    /// 審査の残り時間（実秒）。審査中でなければ nil
    static func subsidyReviewRemainingSeconds(state: GameState, now: Date = Date()) -> Double? {
        guard let due = state.subsidy.pendingGrantAt else { return nil }
        return max(0, due.timeIntervalSince(now))
    }

    /// 次回申請までのクールダウン残り時間（実秒）。クールダウン中でなければ nil
    static func subsidyCooldownRemainingSeconds(state: GameState, now: Date = Date()) -> Double? {
        guard let last = state.subsidy.lastGrantAt else { return nil }
        let remaining = subsidyCooldownSeconds - now.timeIntervalSince(last)
        return remaining > 0 ? remaining : nil
    }

    /// v2以前のセーブの補助金時刻（gameHoursElapsed 基準）を実時刻へ移す。
    /// 残り審査時間・残りクールダウンはプレイ中の換算（1ゲーム時間 = 実6秒）のまま引き継ぐ
    static func migrateSubsidyTimeline(state: inout GameState, now: Date) {
        if let hours = state.subsidy.pendingGrantAtHours {
            if state.subsidy.pendingGrantAt == nil {
                let remaining = (hours - state.gameHoursElapsed) * realSecondsPerGameHour
                state.subsidy.pendingGrantAt = now.addingTimeInterval(remaining)
            }
            state.subsidy.pendingGrantAtHours = nil
        }
        if let hours = state.subsidy.lastGrantAtHours {
            if state.subsidy.lastGrantAt == nil {
                let elapsed = (state.gameHoursElapsed - hours) * realSecondsPerGameHour
                state.subsidy.lastGrantAt = now.addingTimeInterval(-elapsed)
            }
            state.subsidy.lastGrantAtHours = nil
        }
    }

    // 緊急救済枠：工程の装置がなくなりラインが止まり、買い戻す資金もない詰み状態からの救済

    static let emergencyMarginRate = 0.2   // 緊急交付の余裕分（最安機種価格の20%）

    /// 指定工程で、現行ノードで購入可能な機種（lockReasons が空）の最安価格。該当機種がなければ nil
    static func cheapestModelPriceYen(state: GameState, process: ProcessType) -> Double? {
        Catalog.models(for: process)
            .filter { lockReasons(model: $0, state: state).isEmpty }
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

    /// 所有装置（設置中＋倉庫）すべてを設置した仮定の状態。
    /// 倉庫からの再設置は無料なので、詰み判定では所有装置すべてを使えるものとして評価する
    private static func stateWithAllOwnedEquipmentInstalled(_ state: GameState) -> GameState {
        var copy = state
        copy.fab.equipment += copy.fab.storedEquipment
        copy.fab.storedEquipment = []
        return copy
    }

    /// 切替可能なノード（プレイ可能かつ解放済み）のいずれかで、所有装置を使ってラインが再稼働するか。
    /// 再稼働するなら、ノード切替と無料の付け替えで立て直せる（＝詰みではない）。
    /// 待機装置を倉庫へ外しても所有関係は変わらないため、この判定は付け替えで回避できない
    static func canRestartLineWithOwnedEquipment(state: GameState) -> Bool {
        let fielded = stateWithAllOwnedEquipmentInstalled(state)
        return Catalog.nodes.contains { node in
            Catalog.isPlayable(nodeId: node.id)
                && isNodeUnlocked(state: state, nodeId: node.id)
                && derived(state: fielded, asNode: node.id).lineWPH > 0
        }
    }

    /// 緊急救済で今すぐ交付できる額（常に > 0）。対象外なら nil。
    /// 対象：ラインWPHが0（いずれかの工程に稼働装置がない）かつ、所持金が「止まっている工程の最安機種価格」未満、
    /// かつ解放済みノードへの切替（と無料の付け替え）でも再稼働しない、本当に詰んだ場合のみ。
    /// 額：最安機種価格 − 所持金 ＋ 最安機種価格 × emergencyMarginRate（余裕分）
    static func emergencyGrantYen(state: GameState) -> Double? {
        let d = derived(state: state)
        guard d.lineWPH <= 0, let cheapest = cheapestStoppedProcessPriceYen(state: state) else { return nil }
        guard !canRestartLineWithOwnedEquipment(state: state) else { return nil }
        guard state.cashYen < cheapest else { return nil }
        return cheapest - state.cashYen + cheapest * emergencyMarginRate
    }

    static func canApplyEmergencySubsidy(state: GameState) -> Bool {
        emergencyGrantYen(state: state) != nil
    }

    @discardableResult
    static func applyEmergencySubsidy(state: inout GameState, now: Date = Date()) -> Bool {
        guard let amount = emergencyGrantYen(state: state) else { return false }
        // 審査なしで即時交付。受給累計に数え、通常補助金のクールダウン起算点もここに置く
        // （緊急交付を使うと通常申請も72分不可）。緊急枠自体はクールダウンで止めない
        // （複数工程が止まっている場合に繰り返し使って立て直すための救済措置のため）。
        state.cashYen += amount
        state.subsidy.totalReceivedYen += amount
        state.subsidy.lastGrantAt = now
        return true
    }

    // MARK: 研究

    /// 完了済み研究の効果を集約したもの
    struct ResearchEffects: Equatable {
        var throughputMultiplier: Double = 1
        var uptimeAddition: Double = 0
        var yieldDefectMultiplier: Double = 1
        var learnWafersMultiplier: Double = 1
        var offlineEfficiencyAddition: Double = 0
        var offlineCapAdditionalSeconds: Double = 0
        var unlockedKeys: Set<String> = []
    }

    /// 完了済み研究の効果を畳み込む（倍率系は乗算、加算系は加算）
    static func researchEffects(state: GameState) -> ResearchEffects {
        var fx = ResearchEffects()
        for spec in Catalog.research where state.research.completedIds.contains(spec.id) {
            switch spec.effect {
            case .throughput(let multiplier):
                fx.throughputMultiplier *= multiplier
            case .uptime(let addition):
                fx.uptimeAddition += addition
            case .yieldDefect(let multiplier):
                fx.yieldDefectMultiplier *= multiplier
            case .learnWafers(let multiplier):
                fx.learnWafersMultiplier *= multiplier
            case .offlineEfficiency(let addition):
                fx.offlineEfficiencyAddition += addition
            case .offlineCap(let additionalSeconds):
                fx.offlineCapAdditionalSeconds += additionalSeconds
            case .unlock(let key):
                fx.unlockedKeys.insert(key)
            }
        }
        return fx
    }

    static func isResearchUnlocked(state: GameState, key: String) -> Bool {
        researchEffects(state: state).unlockedKeys.contains(key)
    }

    /// 研究を開始できない理由（nil なら開始可能）
    static func researchBlockReason(state: GameState, researchId: String) -> String? {
        guard let spec = Catalog.research(id: researchId) else { return "不明な研究です" }
        if state.research.completedIds.contains(researchId) { return "完了済みです" }
        if let current = state.research.inProgressId {
            return current == researchId ? "研究中です" : "他の研究が進行中です"
        }
        if let prerequisite = spec.prerequisiteId, !state.research.completedIds.contains(prerequisite) {
            return "前提の研究が未完了です"
        }
        if state.cashYen < spec.costYen { return "資金が不足しています" }
        return nil
    }

    static func canStartResearch(state: GameState, researchId: String) -> Bool {
        researchBlockReason(state: state, researchId: researchId) == nil
    }

    /// 費用を払って研究を開始する（同時に進められるのは1件）
    @discardableResult
    static func startResearch(state: inout GameState, researchId: String, now: Date) -> Bool {
        guard canStartResearch(state: state, researchId: researchId),
              let spec = Catalog.research(id: researchId)
        else { return false }
        state.cashYen -= spec.costYen
        state.research.inProgressId = researchId
        state.research.inProgressStartedAt = now
        return true
    }

    /// 進行中の研究の残り時間（実秒）。進行中がなければ nil
    static func researchRemainingSeconds(state: GameState, now: Date) -> Double? {
        guard let id = state.research.inProgressId,
              let spec = Catalog.research(id: id),
              let startedAt = state.research.inProgressStartedAt
        else { return nil }
        return max(0, startedAt.addingTimeInterval(spec.durationSeconds).timeIntervalSince(now))
    }

    /// 研究は実時間で進む（オフライン中も進む）。期限が来ていれば完了させ、その id を返す
    @discardableResult
    static func settleResearchIfDue(state: inout GameState, now: Date) -> String? {
        guard let id = state.research.inProgressId,
              let remaining = researchRemainingSeconds(state: state, now: now),
              remaining <= 0
        else { return nil }
        state.research.completedIds.insert(id)
        state.research.inProgressId = nil
        state.research.inProgressStartedAt = nil
        state.research.hasUnseenCompletion = true
        return id
    }

    // MARK: 歩留まり異常

    /// 発生中の異常のスペック（なければ nil）
    static func excursionSpec(state: GameState) -> ExcursionSpec? {
        guard let excursion = state.activeExcursion else { return nil }
        return Catalog.excursion(id: excursion.specId)
    }

    /// 稼働中の検査装置の最良グレード（Q1=1、Q2=2、Q3=3、検査なし=0）
    static func bestInspectionGrade(state: GameState) -> Int {
        let nodeId = state.fab.currentNodeId
        let best = state.fab.equipment
            .compactMap { Catalog.model(id: $0.modelId) }
            .filter { $0.process == .inspection && isActive($0, nodeId: nodeId) }
            .map { $0.detectionBase }
            .max() ?? 0
        if best >= 0.80 { return 3 }
        if best >= 0.65 { return 2 }
        if best > 0 { return 1 }
        return 0
    }

    /// 対策の候補工程（order 昇順）。ヒントの段階と検査グレードで絞り込まれる
    static func excursionCandidates(state: GameState) -> [ProcessType] {
        guard let excursion = state.activeExcursion, let spec = Catalog.excursion(id: excursion.specId) else { return [] }
        let cause = spec.causeProcess
        let d = derived(state: state)
        // 稼働中装置のある工程。原因工程は装置を売っていても候補から外さない
        var pool = ProcessType.allCases.filter { d.units($0) > 0 }
        if !pool.contains(cause) { pool.append(cause) }

        let gradeCount: Int
        switch bestInspectionGrade(state: state) {
        case 3: gradeCount = 1
        case 2: gradeCount = 2
        default: gradeCount = 3
        }
        let count: Int
        switch excursion.hintsRevealed {
        case ...0: count = pool.count
        case 1: count = gradeCount
        case 2: count = max(1, gradeCount - 1)
        default: count = 1
        }

        // 原因工程に近い工程から順に残す（同点は上流側を優先）
        let ranked = pool.sorted { a, b in
            let da = abs(a.order - cause.order)
            let db = abs(b.order - cause.order)
            return da != db ? da < db : a.order < b.order
        }
        return ranked.prefix(count).sorted { $0.order < $1.order }
    }

    /// 対策費用
    static func excursionCountermeasureCostYen(state: GameState) -> Double {
        // 純益1日分（ゲーム内1日 = 実2.4分）の25%。構造的に純益1日分を超えない
        let dailyNet = max(derived(state: state).incomePerMinuteYen, 0) * 24 * realSecondsPerGameHour / 60
        guard dailyNet > 0 else { return excursionMinimumCostYen }
        return min(max(dailyNet * 0.25, excursionMinimumCostYen), dailyNet)
    }

    /// 追加分析（ヒント1段階）の費用 = 対策費用の20%
    static func excursionHintCostYen(state: GameState) -> Double {
        excursionCountermeasureCostYen(state: state) * 0.2
    }

    /// 費用を払ってヒントを1段階開示する
    @discardableResult
    static func revealExcursionHint(state: inout GameState) -> Bool {
        guard let excursion = state.activeExcursion, excursion.hintsRevealed < 3 else { return false }
        let cost = excursionHintCostYen(state: state)
        guard state.cashYen >= cost else { return false }
        state.cashYen -= cost
        state.activeExcursion?.hintsRevealed += 1
        return true
    }

    /// 費用を払って指定工程に対策を実行する。原因工程なら異常が解消する
    @discardableResult
    static func applyExcursionCountermeasure(state: inout GameState, process: ProcessType) -> ExcursionCountermeasureResult {
        guard let spec = excursionSpec(state: state) else { return .noActiveExcursion }
        let cost = excursionCountermeasureCostYen(state: state)
        guard state.cashYen >= cost else { return .insufficientCash }
        state.cashYen -= cost
        if process == spec.causeProcess {
            state.activeExcursion = nil
            state.stats.excursionsResolved += 1
            state.nextExcursionEarliestGameHours = state.gameHoursElapsed + excursionCooldownGameHours
            return .resolved
        }
        state.activeExcursion?.wrongGuesses += 1
        return .wrongProcess
    }

    /// テスト・検証用の強制発生（猶予・クールダウンは無視する）
    @discardableResult
    static func forceStartExcursion(state: inout GameState, causeProcess: ProcessType) -> Bool {
        guard state.activeExcursion == nil,
              let spec = Catalog.excursion(for: causeProcess),
              derived(state: state).units(causeProcess) > 0
        else { return false }
        state.activeExcursion = ActiveExcursion(specId: spec.id, startedAtGameHours: state.gameHoursElapsed)
        return true
    }

    /// 発生抽選。発生間隔の期待値どおりになるよう、経過時間に比例した確率で発生させる
    private static func maybeStartExcursion(state: inout GameState, dtGameHours: Double, derived: DerivedState) {
        guard state.activeExcursion == nil,
              state.gameHoursElapsed >= state.nextExcursionEarliestGameHours,
              derived.lineWPH > 0
        else { return }
        let p = min(dtGameHours / excursionMeanIntervalGameHours, 1)
        guard excursionRandomUnit() < p else { return }
        // 原因工程は稼働中装置のある工程から一様に選ぶ
        let candidates = ProcessType.allCases.filter { derived.units($0) > 0 }
        guard !candidates.isEmpty else { return }
        let index = min(max(Int(excursionRandomUnit() * Double(candidates.count)), 0), candidates.count - 1)
        guard let spec = Catalog.excursion(for: candidates[index]) else { return }
        state.activeExcursion = ActiveExcursion(specId: spec.id, startedAtGameHours: state.gameHoursElapsed)
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
        case .currentNodeIs(let nodeId):
            return state.fab.currentNodeId == nodeId
        case .lineYieldAtLeastOnNode(let nodeId, let target):
            return state.fab.currentNodeId == nodeId && derived.lineYield >= target
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
        case .firstInvestment, .subsidyReceived, .nonDefaultProduct, .currentNodeIs:
            return milestoneAchieved(spec, state: state, derived: derived) ? 1 : 0
        case .lineYieldAtLeastOnNode(let nodeId, let target):
            // 対象ノードにいないときの歩留まりは別ノードの値なので進捗に数えない
            return state.fab.currentNodeId == nodeId ? ratio(derived.lineYield, target) : 0
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
        case .currentNodeIs(let nodeId):
            let name = Catalog.node(id: nodeId)?.displayName ?? nodeId
            return (achieved ? "達成" : "未達成", "\(name)へ移行する")
        case .lineYieldAtLeastOnNode(let nodeId, let target):
            let name = Catalog.node(id: nodeId)?.displayName ?? nodeId
            let current = state.fab.currentNodeId == nodeId ? MoneyFormat.percent(derived.lineYield) : "未移行"
            return (current, "\(name)で\(MoneyFormat.percent(target))")
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
            if let stopped, standbyCount(state: state, process: stopped) > 0 {
                let nodeName = currentNode(state: state).displayName
                return "ラインが止まっています。\(stopped.displayName)の装置が\(nodeName)では稼働しません（待機中）。\(nodeName)対応の装置を購入するか、ノードを戻しましょう。"
            }
            var message = "ラインが止まっています。\(stopped?.displayName ?? "いずれかの工程")の装置がありません。装置タブで最安の装置を設置しましょう。"
            if emergencyGrantYen(state: state) != nil {
                message += " 統計タブの緊急補助金で立て直せます。"
            }
            return message
        }

        // 2. 歩留まり異常が発生中
        if state.activeExcursion != nil {
            return "歩留まり異常が発生しています。フロアの検査ベイから欠陥分析を開いて、原因工程を特定しましょう。"
        }

        // 3. 補助金を申請できる
        if canApplySubsidy(state: state) {
            return "国庫補助金を申請できます（交付予定 \(MoneyFormat.yen(subsidyCapYen(state: state)))）。統計タブから申請しましょう。"
        }

        // 4. 在庫が上限間近
        if !state.fab.autoSellEnabled && state.fab.inventoryChips > inventoryCap * 0.9 {
            return "在庫が上限に近づいています（\(MoneyFormat.percent(state.fab.inventoryChips / inventoryCap, digits: 0))）。一括売却か自動販売への切り替えがおすすめです。"
        }

        // 5. ボトルネックに最安の購入可能機を足す
        if let process = derived.bottleneck,
           let model = Catalog.models(for: process)
               .filter({ lockReasons(model: $0, state: state).isEmpty })
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

        // 6. 検出率が低い
        if derived.detectionRate < 0.80 && derived.units(.inspection) != 0 {
            return "検出率が\(MoneyFormat.percent(derived.detectionRate))です。検査工程を増強すると、市場不良のペナルティを減らせます。"
        }

        // 7. 次の目標
        if let spec = nextMilestone(state: state) {
            let progress = milestoneProgress(state: state, derived: derived, spec: spec)
            return "次の目標は『\(spec.title)』です（進捗 \(MoneyFormat.percent(progress, digits: 0))）。"
        }
        return "全ての目標を達成しました。ラインは順調に稼働しています。"
    }
}
