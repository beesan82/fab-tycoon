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
    /// 実時間1分あたりの純収入（円）。SimCore に完了ロットがあれば実測値、無ければ理論値
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

    // 実測値（P4。fab.sim の観測 EMA。sim が無ければ 0）。lineWPH 等の上の値は理論値のまま（§9-14）
    /// 完了ウェハ/時（throughputEMA）
    var measuredThroughputWPH: Double = 0
    /// 完了ロットの歩留まり（yieldEMA）
    var measuredYield: Double = 0
    /// 完了ロットの検出率（detectionEMA）
    var measuredDetectionRate: Double = 0
    /// 実時間1分あたりの純収入の実測値（incomeEMA × gameMinutesPerRealSecond）
    var measuredIncomePerMinuteYen: Double = 0
    /// 実時間1分あたりの純収入の理論値（従来式）
    var theoreticalIncomePerMinuteYen: Double = 0

    func wph(_ process: ProcessType) -> Double { processWPH[process] ?? 0 }
    func units(_ process: ProcessType) -> Int { activeUnits[process] ?? 0 }

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
    case insufficientCash(shortfallYen: Double)
    /// 指定位置に置けない（理由の文言）
    case cannotPlace(String)
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

    /// 設置中の装置（装置の正は fab.placed）。placed が空でレイアウトも無ければ旧形式・手作り状態とみなし、
    /// fab.equipment から作る。レイアウトがある状態の placed が空なのは「全台を外した・売った」なので、
    /// 据え置きの fab.equipment（初期装備のまま）を読み戻さない
    static func installedTools(state: GameState) -> [ToolInstance] {
        state.fab.placed.isEmpty && state.fab.layout == nil
            ? state.fab.equipment.map { ToolInstance(instance: $0) }
            : state.fab.placed
    }

    /// 旧形式状態（placed が空・レイアウト無し）を編集する前に、fab.equipment から placed を作る。
    /// 以降の編集は placed に対して行う（fab.equipment には書き込まない）
    private static func adoptLegacyInstalledTools(state: inout GameState) {
        if state.fab.placed.isEmpty && state.fab.layout == nil {
            state.fab.placed = installedTools(state: state)
        }
    }

    /// 倉庫・旧 API 用の EquipmentInstance（id・modelId・level・purchasedAt を保持）
    static func equipmentInstance(_ tool: ToolInstance) -> EquipmentInstance {
        EquipmentInstance(id: tool.id, modelId: tool.modelId, level: tool.level, purchasedAt: tool.purchasedAt)
    }

    /// 稼働中の露光機のうち最上位の露光クラス
    static func topLithoClass(state: GameState) -> LithoClass? {
        let nodeId = state.fab.currentNodeId
        return installedTools(state: state)
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

    /// レイアウト上で未接続（入口・出口のいずれか）の装置 id。レイアウトが無ければ空
    private static func unconnectedToolIds(state: GameState) -> Set<UUID> {
        var ids = Set<UUID>()
        for problem in layoutProblems(state: state) {
            switch problem {
            case .unconnectedInput(let toolId, _), .unconnectedOutput(let toolId, _):
                ids.insert(toolId)
            case .lineBreak:
                break
            }
        }
        return ids
    }

    /// 理論値の派生状態。レイアウト上で未接続の装置は WPH・歩留まり・検出率の集計から除外する
    static func derived(state: GameState) -> DerivedState {
        derived(state: state, countUnconnected: false)
    }

    /// countUnconnected が true なら未接続の装置も集計に含める（プレビュー・所有装置での再稼働判定用）
    static func derived(state: GameState, countUnconnected: Bool) -> DerivedState {
        let node = currentNode(state: state)
        let topLitho = topLithoClass(state: state)
        let fx = researchEffects(state: state)
        let excluded: Set<UUID> = countUnconnected ? [] : unconnectedToolIds(state: state)

        var wph: [ProcessType: Double] = [:]
        var units: [ProcessType: Int] = [:]
        for process in ProcessType.allCases {
            wph[process] = 0
            units[process] = 0
        }

        // 工程歩留まり用：unitWPH（稼働率適用前）で重み付けした effFactor の合計
        var weightedFactor: [ProcessType: Double] = [:]
        // 装置ごとの寄与（歩留まり異常の装置1台の悪化に使う）
        var contributions: [(toolId: UUID, process: ProcessType, unit: Double, factor: Double)] = []
        var detectionBase = 0.0
        for tool in installedTools(state: state) {
            guard !excluded.contains(tool.id),
                  let model = Catalog.model(id: tool.modelId), isActive(model, nodeId: node.id) else { continue }
            // スループット倍率は unitWPH 側に含まれる（ここで重ねて掛けない）
            let unit = unitWPH(model: model, level: tool.level, state: state)
            wph[model.process, default: 0] += unit
            units[model.process, default: 0] += 1
            // 研究による欠陥寄与の縮小は装置ごとの (1 − 実効寄与) に掛ける
            let factor = 1 - (1 - effectiveYieldFactor(model, level: tool.level)) * fx.yieldDefectMultiplier
            weightedFactor[model.process, default: 0] += unit * factor
            contributions.append((toolId: tool.id, process: model.process, unit: unit, factor: factor))
            if model.process == .inspection {
                detectionBase = max(detectionBase, model.detectionBase)
            }
        }
        var processYields: [ProcessType: Double] = [:]
        // 稼働率適用前の工程WPH（容量シェアの分母）
        var rawWPH: [ProcessType: Double] = [:]
        for process in ProcessType.allCases {
            let raw = wph[process] ?? 0
            rawWPH[process] = raw
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
                let degraded: Double
                if let causeToolId = excursion.causeToolId {
                    // 装置1台の悪化（§4・§9-7）：工程全体の倍率を原因装置の容量シェア s で割り戻し
                    // （M' = 1 + (M − 1) / s）、悪化後の寄与で加重平均した工程歩留まりを使う。
                    // 同一機種2台・片方だけ原因なら、加重平均の悪化は工程全体×M と一致する。
                    // 原因装置が集計対象外（未接続・待機・撤去）なら悪化しない
                    let total = rawWPH[spec.causeProcess] ?? 0
                    var weighted = 0.0
                    for c in contributions where c.process == spec.causeProcess {
                        var factor = c.factor
                        if c.toolId == causeToolId, c.unit > 0 {
                            let corrected = 1 + (spec.defectMultiplier - 1) / (c.unit / total)
                            factor = max(0.5, 1 - (1 - factor) * corrected)
                        }
                        weighted += c.unit * factor
                    }
                    degraded = weighted / total
                } else {
                    // 原因装置の無い異常（互換）：工程全体を悪化させる
                    degraded = max(0, 1 - (1 - causeYield) * spec.defectMultiplier)
                }
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
        // lineWPH はゲーム内1時間あたり → 実1分 = ゲーム内 gameMinutesPerRealSecond 時間
        let theoreticalIncome = lineWPH * marginPerWafer * gameMinutesPerRealSecond
        // 実測値は SimCore の観測 EMA（/ゲーム時間）。完了ロットが出るまでは理論値で見せる
        let sim = state.fab.sim
        let measuredIncome = (sim?.incomeEMA ?? 0) * gameMinutesPerRealSecond
        let hasMeasurement = (sim?.stats.completedLots ?? 0) > 0

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
            incomePerMinuteYen: hasMeasurement ? measuredIncome : theoreticalIncome,
            detectionBase: detectionBase,
            // ライン停止時は余裕度が意味を持たないので 0 として表示する
            detectionHeadroom: lineWPH > 0 ? headroom : 0,
            detectionHeadroomBonus: headroomBonus,
            processYieldProduct: processProduct,
            learningDefectScale: learningDefectScale,
            rawLineYield: rawLineYield,
            excursionProcess: excursionProcess,
            excursionYieldLoss: excursionYieldLoss,
            measuredThroughputWPH: sim?.throughputEMA ?? 0,
            measuredYield: sim?.yieldEMA ?? 0,
            measuredDetectionRate: sim?.detectionEMA ?? 0,
            measuredIncomePerMinuteYen: measuredIncome,
            theoreticalIncomePerMinuteYen: theoreticalIncome
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
        // frozenPriceYen を渡した呼び出し（価格固定のシミュレーション）では精算・評価・異常の抽選をしない
        // tick 前の価格（derived を1回だけ計算して使い回す。価格固定の経路では計算しない）
        var livePriceYen: Double? = nil
        if frozenPriceYen == nil {
            settleSubsidyIfDue(state: &state)
            evaluateMilestones(state: &state)
            let preTickDerived = derived(state: state)
            livePriceYen = preTickDerived.currentPriceYen
            // 歩留まり異常の発生抽選はプレイ中のみ
            maybeStartExcursion(state: &state, dtGameHours: gameMinutes / 60, derived: preTickDerived)
        }

        // ゲームループの正は SimCore（§1.2）。配置と整合させたスナップショットから復元してステップ実行する
        // 異常の抽選・配置整合は価格（製品・ノード・市況）を変えないので、tick 前の価格をそのまま渡せる
        var sim = reconciledSim(state: &state, knownPriceYen: livePriceYen)
        // livePriceYen は frozenPriceYen が nil のとき必ずある（最後の ?? は init が計算した同じ値）
        sim.settlementPriceYen = frozenPriceYen ?? livePriceYen ?? sim.settlementPriceYen
        if let excursion = state.activeExcursion, let spec = Catalog.excursion(id: excursion.specId) {
            sim.excursionToolId = excursion.causeToolId
            sim.excursionDefectMultiplier = spec.defectMultiplier
        } else {
            sim.excursionToolId = nil
            sim.excursionDefectMultiplier = 1
        }
        // ノード切替の予約中は投入を止めて仕掛かりを流し切る（排出モード）
        sim.releasesEnabled = state.fab.nodeSwitch.pendingNodeId == nil
        sim.wipCap = SimCore.operatingWipCap(layout: state.fab.layout)

        // 1ステップ = ゲーム内1分。端数は pendingMinutes に繰り越す
        let totalMinutes = sim.pendingMinutes + gameMinutes
        let steps = Int(totalMinutes)
        sim.pendingMinutes = totalMinutes - Double(steps)
        let statsBefore = sim.stats
        for _ in 0..<steps {
            sim.step()
        }
        let statsAfter = sim.stats

        // 増分を state へ反映する（OfflineProgress.advance と同じ式・同じ項目）
        let price = sim.settlementPriceYen
        let released = statsAfter.releasedWafers - statsBefore.releasedWafers
        let goodChips = statsAfter.sumGoodChips - statsBefore.sumGoodChips
        let detectedDefectChips = statsAfter.sumDetectedDefectChips - statsBefore.sumDetectedDefectChips
        let shippedDefectChips = statsAfter.sumShippedDefectChips - statsBefore.sumShippedDefectChips
        let penaltyYen = statsAfter.sumPenaltyYen - statsBefore.sumPenaltyYen
        let netYen = statsAfter.sumNetYen - statsBefore.sumNetYen
        let completedLots = statsAfter.completedLots - statsBefore.completedLots
        let shippedChips = goodChips + shippedDefectChips
        // 生産系は全額
        state.learningWafers[sim.releaseNodeId, default: 0] += released
        state.stats.totalWafersInput += released
        state.stats.totalGoodChips += goodChips
        state.stats.totalDefectChips += detectedDefectChips
        state.stats.defectLossYen += detectedDefectChips * price
        state.stats.completedLots += completedLots

        var realizedYen = 0.0
        // 売上として計上する割合（自動販売は全量、手動販売は在庫上限を超えて現金化した分だけ）
        var soldFraction = 1.0
        if state.fab.autoSellEnabled {
            // 不良が多すぎると純収入がマイナスになりうるため、現金は0で下げ止める
            state.cashYen = max(0, state.cashYen + netYen)
            realizedYen = netYen
        } else {
            // 不良は区別できないので在庫に混ざる。上限を超えた分は平均純益/チップで現金化する
            state.fab.inventoryChips += shippedChips
            var overflow = 0.0
            if state.fab.inventoryChips > inventoryCap {
                overflow = state.fab.inventoryChips - inventoryCap
                state.fab.inventoryChips = inventoryCap
                let netPerChip = shippedChips > 0 ? netYen / shippedChips : 0
                realizedYen = overflow * netPerChip
                state.cashYen = max(0, state.cashYen + realizedYen)
            }
            soldFraction = shippedChips > 0 ? overflow / shippedChips : 0
        }
        // 売上系は売れた割合で按分する（在庫に残った分は sellInventory で計上するので二重にしない。§7.1）
        state.stats.totalShippedChips += shippedChips * soldFraction
        state.stats.totalMarketDefectChips += shippedDefectChips * soldFraction
        state.stats.totalMarketPenaltyYen += penaltyYen * soldFraction
        state.stats.totalGrossSalesYen += (statsAfter.sumGrossYen - statsBefore.sumGrossYen) * soldFraction
        state.stats.totalCogsYen += (statsAfter.sumCogsYen - statsBefore.sumCogsYen) * soldFraction
        state.stats.totalRevenueYen += netYen * soldFraction
        if completedLots > 0 {
            state.market.recentAvgPriceYen =
                state.market.recentAvgPriceYen * (1 - recentPriceSmoothing) + price * recentPriceSmoothing
        }

        // 書き戻し（装置の正は fab.placed、シミュレーション状態は fab.sim）
        state.fab.placed = sim.tools
        state.fab.sim = sim.snapshot()
        state.fab.running = released > 0 || completedLots > 0 || !sim.lots.isEmpty

        // 排出モードのノード切替：仕掛かりを流し切ったら切り替える
        if let pendingNodeId = state.fab.nodeSwitch.pendingNodeId,
           state.fab.nodeSwitch.mode == .drain, sim.lots.isEmpty {
            completeNodeSwitch(state: &state, toNodeId: pendingNodeId)
        }

        // 生産・販売で累計値が動いた分を評価する
        evaluateMilestones(state: &state)

        return TickResult(
            producedWafers: released,
            goodChips: goodChips,
            revenueYen: realizedYen,
            shippedDefectChips: shippedDefectChips,
            marketPenaltyYen: penaltyYen
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

    /// オフライン進行（§1.8 のハイブリッド方式）。OfflineProgress.advance の結果を OfflineReport に詰め替える
    static func offlineProgress(state: inout GameState, elapsedRealSeconds: Double) -> OfflineReport {
        // OfflineProgress は fab.sim をそのまま使うので、先に配置と整合させておく
        state.fab.sim = reconciledSnapshot(state: &state)
        let report = OfflineProgress.advance(state: &state, elapsedRealSeconds: elapsedRealSeconds)
        return OfflineReport(
            elapsedSeconds: report.elapsedRealSeconds,
            effectiveSeconds: report.effectiveRealSeconds,
            producedWafers: report.releasedWafers,
            goodChips: report.goodChips,
            revenueYen: report.netYen
        )
    }

    // MARK: SimCore の復元と配置整合

    /// fab.sim を fab.placed と整合させたスナップショット（sim が無ければ新規）。
    /// placed に無い装置は除去し、そのポートにいたロットと、その装置へ向かっていた搬送中（レール上・仮想搬送）のロットは
    /// ストッカーへ手運び（満杯なら廃棄して scrappedLots に数える）。
    /// placed にある装置は Lv・配置を同期し、スナップショットに無い装置は追加する。lots の投入順は保持する
    static func reconciledSnapshot(state: inout GameState) -> SimSnapshot {
        let installed = installedTools(state: state)
        var snapshot = state.fab.sim
            ?? SimCore.freshSnapshot(state: state, tools: installed, layout: state.fab.layout)
        let installedById = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let removedIds = Set(snapshot.tools.map { $0.id }).subtracting(installedById.keys)
        if !removedIds.isEmpty {
            var scrappedIds: Set<UUID> = []
            for index in snapshot.lots.indices {
                let lot = snapshot.lots[index]
                let orphaned: Bool
                switch lot.location {
                case .port(let toolId, _):
                    orphaned = removedIds.contains(toolId)
                case .inTransit(_, let destId):
                    // 行き先を失った搬送中ロットはレール端で待ち続けるので、ポートロットと同じく退避する
                    orphaned = destId.map { removedIds.contains($0) } ?? false
                case .rail:
                    orphaned = lot.destinationToolId.map { removedIds.contains($0) } ?? false
                case .entry, .stocker:
                    orphaned = false
                }
                guard orphaned else { continue }
                if snapshot.stocker.lotIds.count < snapshot.stocker.capacity {
                    handCarryToStocker(&snapshot, lotIndex: index)
                } else {
                    scrappedIds.insert(snapshot.lots[index].id)
                }
            }
            if !scrappedIds.isEmpty {
                snapshot.lots.removeAll { scrappedIds.contains($0.id) }
                state.stats.scrappedLots += scrappedIds.count
            }
            snapshot.tools.removeAll { removedIds.contains($0.id) }
        }

        var knownIds = Set<UUID>()
        for index in snapshot.tools.indices {
            guard let tool = installedById[snapshot.tools[index].id] else { continue }
            knownIds.insert(tool.id)
            snapshot.tools[index].level = tool.level
            snapshot.tools[index].origin = tool.origin
            snapshot.tools[index].rotation = tool.rotation
            snapshot.tools[index].mirrored = tool.mirrored
        }
        // スナップショットに無い装置は placed のものをそのまま追加する（新規設置なのでポートは空）
        for tool in installed where !knownIds.contains(tool.id) {
            snapshot.tools.append(tool)
            knownIds.insert(tool.id)
        }
        return snapshot
    }

    /// reconciledSnapshot から復元した SimCore。knownPriceYen が nil なら精算価格を derived から計算する
    static func reconciledSim(state: inout GameState, knownPriceYen: Double? = nil) -> SimCore {
        let snapshot = reconciledSnapshot(state: &state)
        var sim = SimCore(state: state, snapshot: snapshot, knownPriceYen: knownPriceYen)
        resyncLearningWafersBase(&sim, state: state)
        return sim
    }

    /// 学習 W の起点を state.learningWafers から引き直す（自己修復）。
    /// 不変条件「learningWafers[node] = base ＋ その sim で投入した累計」を、learningWafers が外部で
    /// 変更された場合（移行・テスト等）にも保つ。freshSnapshot（base = learningWafers[node]、投入 0）とも整合する
    static func resyncLearningWafersBase(_ sim: inout SimCore, state: GameState) {
        sim.learningWafersBase = (state.learningWafers[sim.releaseNodeId] ?? 0) - sim.stats.releasedWafers
    }

    /// スナップショット上でロットを手運びでストッカーへ移す（空き確認は呼び出し側）
    private static func handCarryToStocker(_ snapshot: inout SimSnapshot, lotIndex index: Int) {
        snapshot.lots[index].location = .stocker
        snapshot.lots[index].destination = nil
        snapshot.lots[index].destinationToolId = nil
        snapshot.lots[index].path = []
        snapshot.lots[index].stockerHandlingUntilGameMin = snapshot.currentGameMin + snapshot.stocker.handlingGameMin
        snapshot.stocker.lotIds.append(snapshot.lots[index].id)
    }

    /// 装置のポートにいるロットをスナップショット上でストッカーへ手運びし、ポートを空ける（§2.4）。
    /// ストッカーに収まらなければ何も変えず false。sim が無い・ポートにロットが無ければ true
    private static func evacuatePortLots(state: inout GameState, toolId: UUID) -> Bool {
        guard var snapshot = state.fab.sim else { return true }
        let indices = snapshot.lots.indices.filter { index in
            guard case .port(let id, _) = snapshot.lots[index].location else { return false }
            return id == toolId
        }
        guard !indices.isEmpty else { return true }
        guard snapshot.stocker.lotIds.count + indices.count <= snapshot.stocker.capacity else { return false }
        for index in indices {
            handCarryToStocker(&snapshot, lotIndex: index)
        }
        if let t = snapshot.tools.firstIndex(where: { $0.id == toolId }) {
            snapshot.tools[t].ports = snapshot.tools[t].ports.map { _ in LoadPort(lotId: nil) }
        }
        state.fab.sim = snapshot
        return true
    }

    /// WIP 上限の運転点をレイアウトに合わせる（レール編集後）
    private static func syncWipCap(state: inout GameState) {
        state.fab.sim?.wipCap = SimCore.operatingWipCap(layout: state.fab.layout)
    }

    // MARK: ライン状態（ビュー・検証用）

    /// レイアウト上の問題（寸断・未接続）。レイアウトが無ければ空
    static func layoutProblems(state: GameState) -> [LayoutProblem] {
        guard let layout = state.fab.layout else { return [] }
        return LayoutAnalysis.analyze(layout: layout, tools: installedTools(state: state),
                                      nodeId: state.fab.currentNodeId,
                                      lithoClass: topLithoClass(state: state) ?? .duvDry).problems
    }

    /// セーブ中のシミュレーションがデッドロックしているか（sim が無ければ false）
    static func isSimDeadlocked(state: GameState) -> Bool {
        guard let snapshot = state.fab.sim else { return false }
        return SimCore(state: state, snapshot: snapshot).isDeadlocked
    }

    /// 「詰まりを解消」（§1.7）：レール上・搬送中・処理済みのロットを手運びでストッカーへ。満杯なら廃棄する
    @discardableResult
    static func resolveDeadlock(state: inout GameState) -> (moved: Int, scrapped: Int) {
        var sim = reconciledSim(state: &state)
        let result = sim.resolveDeadlockByHandCarry()
        state.fab.placed = sim.tools
        state.fab.sim = sim.snapshot()
        state.stats.scrappedLots += result.scrapped
        return result
    }

    // MARK: 売買

    static func upgradeCostYen(state: GameState, instance: EquipmentInstance) -> Double? {
        upgradeCostYen(modelId: instance.modelId, level: instance.level)
    }

    /// 改良費（価格 × 20% × 現在Lv）。最大レベル・不明な機種なら nil
    private static func upgradeCostYen(modelId: String, level: Int) -> Double? {
        guard level < maxLevel, let model = Catalog.model(id: modelId) else { return nil }
        return model.priceYen * upgradeCostRate * Double(level)
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

    /// 購入できない理由。床面積が上限なのでスロット不足ではブロックしない（置けなければ倉庫へ）
    static func buyBlockReason(state: GameState, modelId: String) -> BuyBlockReason? {
        guard let model = Catalog.model(id: modelId) else { return .unknownModel }
        let locks = lockReasons(model: model, state: state)
        if !locks.isEmpty { return .locked(locks) }
        if state.cashYen < model.priceYen {
            return .insufficientCash(shortfallYen: model.priceYen - state.cashYen)
        }
        return nil
    }

    /// 指定位置に買って置けない理由。購入自体の可否を先に見て、可能なら配置可否（§2.4）を検証する
    static func buyBlockReason(state: GameState, modelId: String, origin: GridPoint, rotation: Int) -> BuyBlockReason? {
        if let reason = buyBlockReason(state: state, modelId: modelId) { return reason }
        guard let layout = state.fab.layout else { return .cannotPlace("レイアウトがありません") }
        let tool = ToolInstance(instance: EquipmentInstance(modelId: modelId, level: 1, purchasedAt: Date()))
        if let error = layout.toolPlacementError(tool, origin: origin, rotation: rotation, among: state.fab.placed) {
            return .cannotPlace(error)
        }
        return nil
    }

    static func canBuy(state: GameState, modelId: String) -> Bool {
        buyBlockReason(state: state, modelId: modelId) == nil
    }

    /// 購入して自動配置する。レイアウトがあれば接続できる空きへ置き、無ければ倉庫へ。
    /// レイアウトが無い（旧形式）なら原点に置く
    @discardableResult
    static func buy(state: inout GameState, modelId: String, now: Date = Date()) -> Bool {
        guard canBuy(state: state, modelId: modelId), let model = Catalog.model(id: modelId) else { return false }
        adoptLegacyInstalledTools(state: &state)
        state.cashYen -= model.priceYen
        let instance = EquipmentInstance(modelId: modelId, level: 1, purchasedAt: now)
        let tool = ToolInstance(instance: instance)
        if state.fab.layout != nil {
            if let placedTool = autoPlaced(state: state, tool: tool) {
                state.fab.placed.append(placedTool)
            } else {
                state.fab.storedEquipment.append(instance)
            }
        } else {
            state.fab.placed.append(tool)
        }
        state.subsidy.totalInvestedYen += model.priceYen
        return true
    }

    /// 購入して指定位置に置く。購入・配置の可否は課金前にすべて判定し、置けなければ state を変えずに false
    @discardableResult
    static func buyAndPlace(state: inout GameState, modelId: String, origin: GridPoint, rotation: Int,
                            now: Date = Date()) -> Bool {
        guard buyBlockReason(state: state, modelId: modelId, origin: origin, rotation: rotation) == nil,
              let model = Catalog.model(id: modelId),
              let layout = state.fab.layout
        else { return false }
        let instance = EquipmentInstance(modelId: modelId, level: 1, purchasedAt: now)
        guard let placedTool = layout.placed(ToolInstance(instance: instance), origin: origin, rotation: rotation,
                                             among: state.fab.placed)
        else { return false }
        let lineWPHBefore = derived(state: state).lineWPH
        state.cashYen -= model.priceYen
        state.fab.placed.append(placedTool)
        state.subsidy.totalInvestedYen += model.priceYen
        // 現場ノート fn.not_bottleneck 用：この購入がラインを速くしなかった（ラインWPHの上昇が閾値未満）
        // という事実だけを記録する。ノートを出すかどうかは pendingFieldNotes が判定する
        if derived(state: state).lineWPH - lineWPHBefore < notBottleneckMinGainWPH {
            state.stats.noteTriggerMemo[notBottleneckMemoKey] = state.gameHoursElapsed
        }
        return true
    }

    /// 自動配置の位置（§2.4 の配置可＋入口・出口とも接続できる）。レイアウトが無い・接続できる空きが無ければ nil。
    /// 走査は y 昇順 → x 昇順（購入済み区画の広がり範囲内）、各原点で回転 0 → 90。最初に見つかった候補を返す
    static func autoPlaceOrigin(state: GameState, tool: ToolInstance) -> (origin: GridPoint, rotation: Int)? {
        guard let layout = state.fab.layout else { return nil }
        let graph = RailGraph(layout: layout)
        let stockerPorts = graph.portCells(footprint: layout.stockerCells())
        // 入口側：投入口・ストッカーのポートから到達できるセル
        let fromEntry = graph.reachableCells(from: graph.portCells(footprint: layout.entryCells()) + stockerPorts)
        // 出口側：出荷口・ストッカーのポート
        let exitPorts = Set(graph.portCells(footprint: layout.shippingCells()) + stockerPorts)
        let extent = floorExtent(layout)
        for y in 0..<extent.height {
            for x in 0..<extent.width {
                let origin = GridPoint(x: x, y: y)
                for rotation in [0, 90] {
                    guard layout.placed(tool, origin: origin, rotation: rotation, among: state.fab.placed) != nil
                    else { continue }
                    let footprint = FloorLayout.cells(
                        origin: origin, size: FloorLayout.footprintSize(modelId: tool.modelId, rotation: rotation))
                    let ports = graph.portCells(footprint: footprint)
                    guard ports.contains(where: { fromEntry.contains($0) }) else { continue }
                    guard !graph.reachableCells(from: ports).isDisjoint(with: exitPorts) else { continue }
                    return (origin: origin, rotation: rotation)
                }
            }
        }
        return nil
    }

    /// autoPlaceOrigin の位置に置いたコピー（ポートは元のまま）。置けなければ nil
    private static func autoPlaced(state: GameState, tool: ToolInstance) -> ToolInstance? {
        guard let layout = state.fab.layout, let spot = autoPlaceOrigin(state: state, tool: tool) else { return nil }
        return layout.placed(tool, origin: spot.origin, rotation: spot.rotation, among: state.fab.placed)
    }

    /// 購入済み区画を含む矩形の大きさ（セル。原点 0,0 から）
    private static func floorExtent(_ layout: FloorLayout) -> (width: Int, height: Int) {
        let width = ((layout.parcels.map { $0.x }.max() ?? 0) + 1) * FloorLayout.parcelSize
        let height = ((layout.parcels.map { $0.y }.max() ?? 0) + 1) * FloorLayout.parcelSize
        return (width: width, height: height)
    }

    /// 設置中（placed）の同 id、無ければ倉庫の同 id を1段階改良する
    @discardableResult
    static func upgrade(state: inout GameState, instanceId: UUID) -> Bool {
        adoptLegacyInstalledTools(state: &state)
        if let index = state.fab.placed.firstIndex(where: { $0.id == instanceId }) {
            let tool = state.fab.placed[index]
            guard let cost = upgradeCostYen(modelId: tool.modelId, level: tool.level), state.cashYen >= cost
            else { return false }
            state.cashYen -= cost
            state.fab.placed[index].level += 1
            state.subsidy.totalInvestedYen += cost
            return true
        }
        if let index = state.fab.storedEquipment.firstIndex(where: { $0.id == instanceId }) {
            guard let cost = upgradeCostYen(state: state, instance: state.fab.storedEquipment[index]),
                  state.cashYen >= cost
            else { return false }
            state.cashYen -= cost
            state.fab.storedEquipment[index].level += 1
            state.subsidy.totalInvestedYen += cost
            return true
        }
        return false
    }

    @discardableResult
    static func sellEquipment(state: inout GameState, instanceId: UUID) -> Bool {
        // 設置中・倉庫のどちらからでも売却できる。設置中のポートのロットは次の reconcile でストッカーへ退避される
        adoptLegacyInstalledTools(state: &state)
        if let index = state.fab.placed.firstIndex(where: { $0.id == instanceId }) {
            let refund = sellRefundYen(instance: equipmentInstance(state.fab.placed[index]))
            state.fab.placed.remove(at: index)
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

    /// 設置中の装置を倉庫へ外す（無料。レベル・購入日時は保持）。
    /// ポートのロットはストッカーへ手運びする。ストッカーに収まらなければ外せない（§2.4）
    @discardableResult
    static func detachEquipment(state: inout GameState, instanceId: UUID) -> Bool {
        adoptLegacyInstalledTools(state: &state)
        guard let index = state.fab.placed.firstIndex(where: { $0.id == instanceId }),
              evacuatePortLots(state: &state, toolId: instanceId)
        else { return false }
        let tool = state.fab.placed.remove(at: index)
        state.fab.storedEquipment.append(equipmentInstance(tool))
        return true
    }

    /// 倉庫の装置を接続できる空きへ自動配置する（ポートは空）。置けなければ false
    @discardableResult
    static func attachEquipment(state: inout GameState, instanceId: UUID) -> Bool {
        guard let index = state.fab.storedEquipment.firstIndex(where: { $0.id == instanceId }),
              let tool = autoPlaced(state: state, tool: ToolInstance(instance: state.fab.storedEquipment[index]))
        else { return false }
        state.fab.storedEquipment.remove(at: index)
        state.fab.placed.append(tool)
        return true
    }

    // MARK: 配置編集（配置モード）
    // プレイヤーの配置は未接続でも許可する（グレー表示＋問題リストで示す）

    /// 倉庫の装置を指定位置に置く（§2.4 の配置バリデーションのみ）
    @discardableResult
    static func placeStoredTool(state: inout GameState, toolId: UUID, origin: GridPoint, rotation: Int) -> Bool {
        guard let layout = state.fab.layout,
              let index = state.fab.storedEquipment.firstIndex(where: { $0.id == toolId }),
              let tool = layout.placed(ToolInstance(instance: state.fab.storedEquipment[index]),
                                       origin: origin, rotation: rotation, among: state.fab.placed)
        else { return false }
        state.fab.storedEquipment.remove(at: index)
        state.fab.placed.append(tool)
        return true
    }

    /// 設置中の装置を移動する。ポートのロットはストッカーへ手運びし（収まらなければ移動不可）、ポートは空になる
    @discardableResult
    static func movePlacedTool(state: inout GameState, toolId: UUID, origin: GridPoint, rotation: Int) -> Bool {
        guard let layout = state.fab.layout,
              let index = state.fab.placed.firstIndex(where: { $0.id == toolId })
        else { return false }
        let current = state.fab.placed[index]
        if current.origin == origin && current.rotation == rotation { return true }
        let others = state.fab.placed.filter { $0.id != toolId }
        guard var moved = layout.placed(current, origin: origin, rotation: rotation, among: others),
              evacuatePortLots(state: &state, toolId: toolId)
        else { return false }
        moved.ports = moved.ports.map { _ in LoadPort(lotId: nil) }
        state.fab.placed[index] = moved
        return true
    }

    /// 同じ原点で 90° 回す（0 → 90 → 180 → 270 → 0）。検証・ロットの退避は movePlacedTool と同じ
    @discardableResult
    static func rotatePlacedTool(state: inout GameState, toolId: UUID) -> Bool {
        guard let tool = state.fab.placed.first(where: { $0.id == toolId }) else { return false }
        let rotation = (((tool.rotation % 360) + 360) % 360 + 90) % 360
        return movePlacedTool(state: &state, toolId: toolId, origin: tool.origin, rotation: rotation)
    }

    /// 設置中の装置を倉庫へ（detachEquipment と同じ）
    @discardableResult
    static func removePlacedToolToStorage(state: inout GameState, toolId: UUID) -> Bool {
        detachEquipment(state: &state, instanceId: toolId)
    }

    // MARK: レール編集（§3.1・§9-9）

    /// レール1セルの敷設費（200万円）。撤去の返金は購入したセルだけ全額で、テンプレート等の
    /// 無償セルは 0（P6先行分：無償レールの売却益の抜け穴対策）。補助金の累計設備投資には数えない
    static let railCellCostYen = 2_000_000.0

    /// 撤去時の返金額。購入記録（layout.paidRailPoints）にあるセルだけ railCellCostYen、無償分は 0
    static func railRefundYen(state: GameState, at point: GridPoint) -> Double {
        guard let layout = state.fab.layout, layout.railIndex[point] != nil else { return 0 }
        return layout.paidRailPoints.contains(point) ? railCellCostYen : 0
    }

    /// 複数セルの撤去時の返金額合計（ビューのプレビュー表示用）
    static func railRefundYen(state: GameState, points: [GridPoint]) -> Double {
        points.reduce(0) { $0 + railRefundYen(state: state, at: $1) }
    }

    /// レールを敷く・描き替える。既存セルの描き替えは無償（購入記録もそのまま）、新規セルは railCellCostYen
    @discardableResult
    static func setRail(state: inout GameState, cell: RailCell) -> Bool {
        guard var layout = state.fab.layout else { return false }
        let existing = layout.railIndex[cell.point]
        if let existing = existing, existing.direction == cell.direction, existing.kind == cell.kind { return true }
        let isNew = existing == nil
        if isNew && state.cashYen < railCellCostYen { return false }
        guard layout.setRail(cell, among: state.fab.placed) else { return false }
        if isNew {
            layout.paidRailPoints.insert(cell.point)
        }
        state.fab.layout = layout
        if isNew {
            state.cashYen -= railCellCostYen
            state.stats.railCellsBuilt += 1
        }
        syncWipCap(state: &state)
        return true
    }

    /// レールを撤去する。返金は購入したセルだけ全額、無償セルは 0。
    /// そのセルを通るレール上のロットはストッカーへ手運びし、
    /// ストッカーに収まらなければ撤去できない（§3.1）
    @discardableResult
    static func removeRail(state: inout GameState, at point: GridPoint) -> Bool {
        guard var layout = state.fab.layout, layout.railIndex[point] != nil else { return false }
        let refundYen = layout.paidRailPoints.contains(point) ? railCellCostYen : 0
        if var snapshot = state.fab.sim {
            let indices = snapshot.lots.indices.filter { index in
                guard case .rail = snapshot.lots[index].location else { return false }
                return snapshot.lots[index].path.contains(point)
            }
            if !indices.isEmpty {
                guard snapshot.stocker.lotIds.count + indices.count <= snapshot.stocker.capacity else { return false }
                for index in indices {
                    handCarryToStocker(&snapshot, lotIndex: index)
                }
                state.fab.sim = snapshot
            }
        }
        layout.removeRail(at: point)
        state.fab.layout = layout
        state.cashYen += refundYen
        syncWipCap(state: &state)
        return true
    }

    // MARK: 増床（区画購入、§2.5）

    /// 次回の増床価格（初回価格 × 1.6^増床回数）
    static func expansionCostYen(state: GameState) -> Double {
        expansionBasePriceYen * pow(expansionPriceGrowth, Double(state.fab.expansionCount))
    }

    /// 区画を購入する（既存区画と辺で接する範囲内の未購入区画）。補助金の累計設備投資には数えない
    @discardableResult
    static func buyParcel(state: inout GameState, coord: ParcelCoord) -> Bool {
        guard var layout = state.fab.layout, layout.canAddParcel(coord) else { return false }
        let cost = expansionCostYen(state: state)
        guard state.cashYen >= cost else { return false }
        state.cashYen -= cost
        layout.addParcel(coord)
        state.fab.layout = layout
        state.fab.expansionCount += 1
        state.stats.parcelsBought += 1
        return true
    }

    /// 読み順（y が外側、x が内側）で最初に追加できる区画（migrateToLayout の無償付与と同じ走査順）
    private static func firstAddableParcel(_ layout: FloorLayout) -> ParcelCoord? {
        for y in 0...FloorLayout.maxParcel {
            for x in 0...FloorLayout.maxParcel {
                let coord = ParcelCoord(x: x, y: y)
                if layout.canAddParcel(coord) { return coord }
            }
        }
        return nil
    }

    static func canExpandFab(state: GameState) -> Bool {
        if let layout = state.fab.layout {
            return firstAddableParcel(layout) != nil && state.cashYen >= expansionCostYen(state: state)
        }
        return state.cashYen >= expansionCostYen(state: state)
    }

    /// 増床する。レイアウトがあれば読み順で最初に追加できる区画を買い、
    /// 無ければ（旧形式）スロットを +4 する。補助金の累計設備投資には数えない
    @discardableResult
    static func expandFab(state: inout GameState) -> Bool {
        if let layout = state.fab.layout {
            guard let coord = firstAddableParcel(layout) else { return false }
            return buyParcel(state: &state, coord: coord)
        }
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
        let owned = installedTools(state: state).map { $0.modelId } + state.fab.storedEquipment.map { $0.modelId }
        return owned.filter { modelIds.contains($0) }.count
    }

    /// 設置中の装置のうち modelIds に含まれ、現在のノードで稼働している台数
    static func activeCount(state: GameState, modelIds: [String]) -> Int {
        let nodeId = state.fab.currentNodeId
        return installedTools(state: state).filter { tool in
            guard modelIds.contains(tool.modelId), let model = Catalog.model(id: tool.modelId) else { return false }
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
        isStandby(toolId: instance.id, modelId: instance.modelId, state: state)
    }

    static func isStandby(_ tool: ToolInstance, state: GameState) -> Bool {
        isStandby(toolId: tool.id, modelId: tool.modelId, state: state)
    }

    private static func isStandby(toolId: UUID, modelId: String, state: GameState) -> Bool {
        guard installedTools(state: state).contains(where: { $0.id == toolId }),
              let model = Catalog.model(id: modelId)
        else { return false }
        return !isActive(model, nodeId: state.fab.currentNodeId)
    }

    /// 工程別の待機台数
    static func standbyCount(state: GameState, process: ProcessType) -> Int {
        let nodeId = state.fab.currentNodeId
        return installedTools(state: state).filter { tool in
            guard let model = Catalog.model(id: tool.modelId), model.process == process else { return false }
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

    /// ノード切替後の状態（在庫売却なし。製品が選択不可なら既定製品に戻す）。
    /// プレビューに古い実測値や予約を持ち込まないよう、sim と切替予約はクリアする
    private static func stateAfterSwitchingNode(_ state: GameState, toNodeId: String) -> GameState {
        var copy = state
        copy.fab.sim = nil
        copy.fab.nodeSwitch = NodeSwitchState()
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
        let standby = installedTools(state: after).filter { isStandby($0, state: after) }.count
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

    /// ノードを今すぐ切り替える。在庫は旧ノードの単価で精算し、残っている仕掛かりは廃棄、
    /// 新ノードで作れない製品は既定製品に戻す（completeNodeSwitch）
    @discardableResult
    static func switchNode(state: inout GameState, toNodeId: String) -> Bool {
        guard canSwitchNode(state: state, toNodeId: toNodeId) else { return false }
        completeNodeSwitch(state: &state, toNodeId: toNodeId)
        return true
    }

    /// ノード切替を要求する。即時なら今すぐ切り替え、排出なら仕掛かりが無ければ今すぐ、
    /// あれば予約して投入を止める（流し切った時点で tick が切り替える）
    @discardableResult
    static func requestNodeSwitch(state: inout GameState, toNodeId: String, mode: NodeSwitchMode) -> Bool {
        guard canSwitchNode(state: state, toNodeId: toNodeId) else { return false }
        switch mode {
        case .immediate:
            return switchNode(state: &state, toNodeId: toNodeId)
        case .drain:
            if state.fab.sim?.lots.isEmpty ?? true {
                return switchNode(state: &state, toNodeId: toNodeId)
            }
            state.fab.nodeSwitch = NodeSwitchState(pendingNodeId: toNodeId, mode: .drain)
            return true
        }
    }

    /// ノード切替の予約を取り消す（投入を再開する）
    static func cancelNodeSwitch(state: inout GameState) {
        state.fab.nodeSwitch = NodeSwitchState()
    }

    /// ノード切替の確定（排出完了・即時切替の共通部）。在庫は旧ノードの単価で精算し、
    /// 残っている仕掛かりは廃棄、新ノードで作れない製品は既定製品に戻し、シミュレーションを作り直す
    private static func completeNodeSwitch(state: inout GameState, toNodeId: String) {
        if state.fab.inventoryChips > 0 {
            sellInventory(state: &state, priceYen: derived(state: state).currentPriceYen)
        }
        state.stats.scrappedLots += state.fab.sim?.lots.count ?? 0
        state.fab.currentNodeId = toNodeId
        if !canSelectProduct(state: state, productId: state.currentProductId) {
            state.currentProductId = Catalog.defaultProductId
        }
        state.fab.nodeSwitch = NodeSwitchState()
        // 廃棄したロットが残らないようポートを空にしてから作り直す（学習 W の起点は新ノードの値になる）
        let tools = installedTools(state: state).map { tool -> ToolInstance in
            var cleared = tool
            cleared.ports = tool.ports.map { _ in LoadPort(lotId: nil) }
            cleared.processingRemainderGameMin = 0
            return cleared
        }
        state.fab.placed = tools
        state.fab.sim = SimCore.freshSnapshot(state: state, tools: tools, layout: state.fab.layout)
        evaluateMilestones(state: &state)
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

    /// v3 → v4：フロアをテンプレートで再構成する（設計書 §7.2）。
    /// 設置済み装置（fab.equipment）はテンプレート → 貪欲配置 → 倉庫の順で fab.placed / fab.storedEquipment へ置き、
    /// Lv・購入日・id は保持する。
    /// 増床回数ぶんの区画は無償付与する。仕掛かりの端数（wipWafers）と発生中の異常は破棄する
    static func migrateToLayout(state: inout GameState) {
        let template = LayoutTemplate.starter16(equipment: state.fab.equipment)
        var layout = template.layout
        var placed = template.placed
        var stored = template.stored

        // 増床回数ぶんの区画を無償付与する。6×6 の区画グリッドを読み順（y が外側、x が内側）で走査し、
        // 追加できる区画（既存区画と辺で接する）を順に足す。「右 → 下」の順に広げる近似として読み順を使う
        var granted = 0
        while granted < state.fab.expansionCount {
            var added = false
            scan: for y in 0...FloorLayout.maxParcel {
                for x in 0...FloorLayout.maxParcel {
                    guard granted < state.fab.expansionCount else { break scan }
                    let coord = ParcelCoord(x: x, y: y)
                    if layout.canAddParcel(coord) {
                        layout.addParcel(coord)
                        granted += 1
                        added = true
                    }
                }
            }
            if !added { break }   // 6×6 を使い切った
        }

        // 区画が増えたら、倉庫行きになった装置を y → x の走査順で最初に置ける空きへ（回転 0）
        if granted > 0 && !stored.isEmpty {
            let maxX = ((layout.parcels.map { $0.x }.max() ?? 0) + 1) * FloorLayout.parcelSize
            let maxY = ((layout.parcels.map { $0.y }.max() ?? 0) + 1) * FloorLayout.parcelSize
            var remaining: [ToolInstance] = []
            for tool in stored {
                var result: ToolInstance?
                scan: for y in 0..<maxY {
                    for x in 0..<maxX {
                        if let candidate = layout.placed(tool, origin: GridPoint(x: x, y: y), rotation: 0, among: placed) {
                            result = candidate
                            break scan
                        }
                    }
                }
                if let result = result {
                    placed.append(result)
                } else {
                    remaining.append(tool)
                }
            }
            stored = remaining
        }

        // 装置の正は placed（配置済み）と storedEquipment（倉庫）。fab.equipment は移行元として読むだけで書き戻さない
        state.fab.layout = layout
        state.fab.placed = placed
        state.fab.storedEquipment += stored.map { equipmentInstance($0) }
        // 移行時点ではロットは流れていない（wipWafers の端数は破棄、§7.2）。
        // SimCore の init は state を読むので、layout・placed を設定した後に作る
        state.fab.sim = SimCore.freshSnapshot(state: state, tools: placed, layout: layout)
        // 発生中の異常は装置への紐づけが無いため解除する（nextExcursionEarliestGameHours は据え置き）
        state.activeExcursion = nil
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

    /// 所有装置（設置中＋倉庫）すべてを設置した仮定の状態（配置・接続は問わない。sim は持ち込まない）。
    /// 倉庫からの再設置は無料なので、詰み判定では所有装置すべてを使えるものとして評価する
    private static func stateWithAllOwnedEquipmentInstalled(_ state: GameState) -> GameState {
        var copy = state
        copy.fab.placed = installedTools(state: state) + state.fab.storedEquipment.map { ToolInstance(instance: $0) }
        copy.fab.storedEquipment = []
        copy.fab.sim = nil
        return copy
    }

    /// 切替可能なノード（プレイ可能かつ解放済み）のいずれかで、所有装置を使ってラインが再稼働するか。
    /// 再稼働するなら、ノード切替と無料の付け替え・レール敷設で立て直せる（＝詰みではない）。
    /// 未接続の装置も数える（レール欠落による寸断は救済の対象外、§4）。
    /// 待機装置を倉庫へ外しても所有関係は変わらないため、この判定は付け替えで回避できない
    static func canRestartLineWithOwnedEquipment(state: GameState) -> Bool {
        let fielded = stateWithAllOwnedEquipmentInstalled(state)
        return Catalog.nodes.contains { node in
            Catalog.isPlayable(nodeId: node.id)
                && isNodeUnlocked(state: state, nodeId: node.id)
                && derived(state: stateAfterSwitchingNode(fielded, toNodeId: node.id), countUnconnected: true).lineWPH > 0
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
        let best = installedTools(state: state)
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
              derived(state: state).units(causeProcess) > 0,
              let tool = excursionCauseTools(state: state)[causeProcess]?.first
        else { return false }
        state.activeExcursion = ActiveExcursion(specId: spec.id, startedAtGameHours: state.gameHoursElapsed,
                                                causeToolId: tool.id)
        return true
    }

    /// 工程ごとの原因装置の候補：設置中で現在のノードに対応し、derived の集計対象（レイアウト上で接続済み）の装置。
    /// id（uuidString）順
    private static func excursionCauseTools(state: GameState) -> [ProcessType: [ToolInstance]] {
        let nodeId = state.fab.currentNodeId
        let excluded = unconnectedToolIds(state: state)
        var result: [ProcessType: [ToolInstance]] = [:]
        for tool in installedTools(state: state).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard !excluded.contains(tool.id),
                  let model = Catalog.model(id: tool.modelId), isActive(model, nodeId: nodeId) else { continue }
            result[model.process, default: []].append(tool)
        }
        return result
    }

    /// 発生抽選。発生間隔の期待値どおりになるよう、経過時間に比例した確率で発生させる
    private static func maybeStartExcursion(state: inout GameState, dtGameHours: Double, derived: DerivedState) {
        guard state.activeExcursion == nil,
              state.gameHoursElapsed >= state.nextExcursionEarliestGameHours,
              derived.lineWPH > 0
        else { return }
        let p = min(dtGameHours / excursionMeanIntervalGameHours, 1)
        guard excursionRandomUnit() < p else { return }
        // 原因工程は稼働中装置のある工程から一様に選ぶ（原因装置の候補が無い工程は除く）
        let causeTools = excursionCauseTools(state: state)
        let candidates = ProcessType.allCases.filter { derived.units($0) > 0 && !(causeTools[$0] ?? []).isEmpty }
        guard !candidates.isEmpty else { return }
        let index = min(max(Int(excursionRandomUnit() * Double(candidates.count)), 0), candidates.count - 1)
        guard let spec = Catalog.excursion(for: candidates[index]),
              let tools = causeTools[candidates[index]] else { return }
        // 原因装置は工程内の候補から一様に選ぶ（§4・§9-7）
        let toolIndex = min(max(Int(excursionRandomUnit() * Double(tools.count)), 0), tools.count - 1)
        state.activeExcursion = ActiveExcursion(specId: spec.id, startedAtGameHours: state.gameHoursElapsed,
                                                causeToolId: tools[toolIndex].id)
    }

    // MARK: プレビュー

    /// 1台追加した状態（原点に置く。配置・接続は問わない）。プレビューは derivedAfterAdding で見る
    private static func stateAfterAdding(_ state: GameState, modelId: String) -> GameState {
        var copy = state
        adoptLegacyInstalledTools(state: &copy)
        copy.fab.placed.append(ToolInstance(instance: EquipmentInstance(modelId: modelId)))
        return copy
    }

    /// 追加プレビューの派生状態。追加した装置は未配置なので、未接続の装置も集計に含める
    private static func derivedAfterAdding(_ state: GameState, modelId: String) -> DerivedState {
        derived(state: stateAfterAdding(state, modelId: modelId), countUnconnected: true)
    }

    private static func stateAfterUpgrading(_ state: GameState, instanceId: UUID) -> GameState {
        var copy = state
        adoptLegacyInstalledTools(state: &copy)
        if let index = copy.fab.placed.firstIndex(where: { $0.id == instanceId }) {
            copy.fab.placed[index].level = min(copy.fab.placed[index].level + 1, maxLevel)
        }
        return copy
    }

    private static func stateAfterSelling(_ state: GameState, instanceId: UUID) -> GameState {
        var copy = state
        adoptLegacyInstalledTools(state: &copy)
        copy.fab.placed.removeAll { $0.id == instanceId }
        copy.fab.storedEquipment.removeAll { $0.id == instanceId }
        return copy
    }

    private static func processOf(instanceId: UUID, in state: GameState) -> ProcessType? {
        let modelId = installedTools(state: state).first(where: { $0.id == instanceId })?.modelId
            ?? state.fab.storedEquipment.first(where: { $0.id == instanceId })?.modelId
        return modelId.flatMap { Catalog.model(id: $0)?.process }
    }

    /// 指定モデルを1台追加した場合のラインWPH（資金・スロットは無視）
    static func lineWPHAfterAdding(state: GameState, modelId: String) -> Double {
        derivedAfterAdding(state, modelId: modelId).lineWPH
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
        return derivedAfterAdding(state, modelId: modelId).processYields[process] ?? 0
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

    static func detectionRateAfterAdding(state: GameState, modelId: String) -> Double {
        derivedAfterAdding(state, modelId: modelId).detectionRate
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
        (installedTools(state: state).map { $0.level } + state.fab.storedEquipment.map { $0.level }).max() ?? 0
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
        case .railCellsBuiltAtLeast(let target):
            return state.stats.railCellsBuilt >= target
        case .completedLotsAtLeast(let target):
            return state.stats.completedLots >= target
        case .lineConnected:
            return isLineConnected(state: state, derived: derived)
        case .returnLaneBuilt:
            return railLoopCount(state: state) >= 1
        case .railLoopsAtLeast(let target):
            return railLoopCount(state: state) >= target
        case .noStallForGameHours(let hours):
            return !hasRailStall(state: state)
                && derived.lineWPH > 0
                && (state.fab.sim?.stats.releasedLots ?? 0) > 0
                && state.gameHoursElapsed - lastStallGameHours(state: state) >= hours
        case .cycleTimeBelow(let hours):
            let cycleTimeHours = cycleTimeGameHours(state: state)
            return cycleTimeHours > 0 && cycleTimeHours < hours
        }
    }

    /// 最後に滞留を観測した gameHoursElapsed を残すメモキー
    static let lastStallMemoKey = "ms.lastStallGameHours"

    /// 最後に滞留を観測した gameHoursElapsed（未観測なら 0）
    private static func lastStallGameHours(state: GameState) -> Double {
        state.stats.noteTriggerMemo[lastStallMemoKey] ?? 0
    }

    /// サイクルタイム（cycleTimeEMA はゲーム分）をゲーム時間に直したもの。sim が無ければ 0
    private static func cycleTimeGameHours(state: GameState) -> Double {
        (state.fab.sim?.cycleTimeEMA ?? 0) / 60
    }

    /// ライン成立：寸断が無く、ラインが流れている（マイルストーン lineConnected・ミッション段「つなぐ」で共用）
    private static func isLineConnected(state: GameState, derived: DerivedState) -> Bool {
        !layoutProblems(state: state).contains { problem in
            if case .lineBreak = problem { return true }
            return false
        } && derived.lineWPH > 0
    }

    /// 滞留があるか：レール上で止まっているロット（.rail で progress >= 0.999）がある、またはデッドロック中
    private static func hasRailStall(state: GameState) -> Bool {
        let stopped = state.fab.sim?.lots.contains { lot in
            if case .rail(_, let progress) = lot.location { return progress >= 0.999 }
            return false
        } ?? false
        return stopped || isSimDeadlocked(state: state)
    }

    /// レール網の「環」の数。RailGraph の exits を向きを問わない無向グラフとみなし、
    /// 循環数（辺の数 − 頂点の数 ＋ 連結成分の数）で数える。頂点は exits の始点・終点に現れるレールセルのみ、
    /// 辺は重複を除いた無向ペア。単純な一つの環なら 1、木（行き止まりのある一本道など）なら 0 になる。
    /// レイアウトが無ければ 0
    static func railLoopCount(state: GameState) -> Int {
        guard let layout = state.fab.layout else { return 0 }
        let graph = RailGraph(layout: layout)
        var vertices = Set<GridPoint>()
        var edges = Set<[GridPoint]>()
        var neighbors: [GridPoint: [GridPoint]] = [:]
        for point in graph.cells.keys {
            for exit in graph.exits(of: point) where exit.to != point && graph.cells[exit.to] != nil {
                let pair = [point, exit.to].sorted { ($0.y, $0.x) < ($1.y, $1.x) }
                guard edges.insert(pair).inserted else { continue }
                vertices.insert(point)
                vertices.insert(exit.to)
                neighbors[point, default: []].append(exit.to)
                neighbors[exit.to, default: []].append(point)
            }
        }
        var components = 0
        var visited = Set<GridPoint>()
        for seed in vertices where !visited.contains(seed) {
            components += 1
            visited.insert(seed)
            var stack = [seed]
            while let point = stack.popLast() {
                for next in neighbors[point] ?? [] where !visited.contains(next) {
                    visited.insert(next)
                    stack.append(next)
                }
            }
        }
        return edges.count - vertices.count + components
    }

    /// 未達成のマイルストーンを評価し、達成したものを記録する。今回達成した id を返す
    @discardableResult
    static func evaluateMilestones(state: inout GameState) -> [String] {
        // 滞留ゼロの継続判定（noStallForGameHours）の起点：条件判定の前に最後の滞留時刻を更新する
        if hasRailStall(state: state) {
            state.stats.noteTriggerMemo[lastStallMemoKey] = state.gameHoursElapsed
        }
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
        case .railCellsBuiltAtLeast(let target):
            return ratio(Double(state.stats.railCellsBuilt), Double(target))
        case .completedLotsAtLeast(let target):
            return ratio(Double(state.stats.completedLots), Double(target))
        case .railLoopsAtLeast(let target):
            return ratio(Double(railLoopCount(state: state)), Double(target))
        case .lineConnected, .returnLaneBuilt:
            return milestoneAchieved(spec, state: state, derived: derived) ? 1 : 0
        case .noStallForGameHours(let hours):
            guard !hasRailStall(state: state) else { return 0 }
            return ratio(state.gameHoursElapsed - lastStallGameHours(state: state), hours)
        case .cycleTimeBelow(let hours):
            let cycleTimeHours = cycleTimeGameHours(state: state)
            guard cycleTimeHours > 0 else { return 0 }
            return min(hours / cycleTimeHours, 1)
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
        case .railCellsBuiltAtLeast(let target):
            return ("\(state.stats.railCellsBuilt)セル", "\(target)セル")
        case .completedLotsAtLeast(let target):
            return ("\(state.stats.completedLots)ロット", "\(target)ロット")
        case .lineConnected:
            return (achieved ? "達成" : "未達成", "ラインをつなぐ")
        case .returnLaneBuilt:
            return (achieved ? "達成" : "未達成", "戻りレーンを完成させる")
        case .railLoopsAtLeast(let target):
            return ("\(railLoopCount(state: state))本", "\(target)本")
        case .noStallForGameHours(let hours):
            // 滞留中は evaluateMilestones が起点を今に更新するので、経過は 0 に近い値になる
            let elapsed = max(0, state.gameHoursElapsed - lastStallGameHours(state: state))
            return (MoneyFormat.decimal(elapsed, digits: 1), "\(hours)時間")
        case .cycleTimeBelow(let hours):
            let cycleTimeHours = cycleTimeGameHours(state: state)
            let current = cycleTimeHours > 0 ? MoneyFormat.decimal(cycleTimeHours, digits: 1) : "―"
            return (current, "\(hours)時間未満")
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
        case .fieldNoteSeen(let noteId):
            return state.stats.seenFieldNoteIds.contains(noteId)
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
    /// フロアに最小フットプリント（2×2、D1）の装置を置ける空きが1つも無いか（接続は問わない）。
    /// 購入済み区画内の全原点・回転 0/90 で判定する。レイアウトが無ければ満杯ではない
    static func isFloorFull(state: GameState) -> Bool {
        guard let layout = state.fab.layout else { return false }
        let probe = ToolInstance(instance: EquipmentInstance(modelId: "D1"))
        let tools = installedTools(state: state)
        let extent = floorExtent(layout)
        for y in 0..<extent.height {
            for x in 0..<extent.width {
                for rotation in [0, 90]
                where layout.placed(probe, origin: GridPoint(x: x, y: y), rotation: rotation, among: tools) != nil {
                    return false
                }
            }
        }
        return true
    }

    /// 今いちばん効く次の一手を1行で返す（優先順位の高いルールから順に判定）
    static func advisorMessage(state: GameState, derived: DerivedState) -> String {
        // 1. ライン停止
        if derived.lineWPH <= 0 {
            let stopped = ProcessType.allCases.first { derived.units($0) == 0 } ?? derived.bottleneck
            if let stopped, standbyCount(state: state, process: stopped) > 0 {
                let nodeName = currentNode(state: state).displayName
                return "ラインが止まっています。\(stopped.displayName)の装置が\(nodeName)では稼働しません（待機中）。\(nodeName)対応の装置を購入するか、ノードを戻しましょう。"
            }
            var message = "ラインが止まっています。\(stopped?.displayName ?? "いずれかの工程")の装置がありません。建設（＋）で最安の装置を置きましょう。"
            if emergencyGrantYen(state: state) != nil {
                message += " 事務所の緊急補助金で立て直せます。"
            }
            return message
        }

        // 2. 歩留まり異常が発生中
        if state.activeExcursion != nil {
            return "歩留まり異常が発生しています。検査装置をタップして欠陥分析を開いて、原因工程を特定しましょう。"
        }

        // 3. 補助金を申請できる
        if canApplySubsidy(state: state) {
            return "国庫補助金を申請できます（交付予定 \(MoneyFormat.yen(subsidyCapYen(state: state)))）。事務所から申請しましょう。"
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
                if isFloorFull(state: state) {
                    if canExpandFab(state: state) {
                        return "フロアに装置を置く空きがありません。区画を購入して増床（\(MoneyFormat.yen(expansionCostYen(state: state)))）すると、ボトルネックの\(process.displayName)に装置を足せるようになります。"
                    }
                    return "フロアに装置を置く空きがありません。余裕のある工程の装置を倉庫へ外して\(process.displayName)に付け替えるか、増床の資金を貯めましょう。"
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

// MARK: - ロット進捗・レール滞留・寸断アンカー（R2、simcity-rebuild §3.1・§3.3・§4.5・§5.4）

/// 検査通過後の FOUP の品質帯（§3.3）。検査前は none（検査するまで分からない）
enum LotQualityBand: Equatable {
    case none
    case red
    case green
}

/// FOUP 追跡（LotCard）用のロット進捗照会結果
struct LotProgress: Equatable {
    var lotId: UUID
    /// 次に処理するルートステップ（Lot.stepIndex そのまま、0始まり）
    var stepIndex: Int
    var totalSteps: Int
    /// 現工程（stepIndex がルート範囲外なら nil）
    var currentProcess: ProcessType?
    /// 現工程が何回目か（1始まり。currentProcess が nil なら 0）
    var passNumber: Int
    /// ルート全体で現工程が何回あるか（currentProcess が nil なら 0）
    var totalPasses: Int
    var nextProcess: ProcessType?
    /// ポートにいる場合の装置 id
    var currentToolId: UUID?
    /// 行き先の装置 id（destinationToolId、無ければ destination が .tool のときその id）
    var destinationToolId: UUID?
    /// 投入からの経過ゲーム分
    var elapsedGameMin: Double
    var waitedGameMin: Double
    /// 期待良品率（Lot.goodFraction）
    var expectedGoodFraction: Double
    /// 検査ステップ通過済みの場合の推定不良率 = (1 − goodFraction) × 検出率。未検査なら nil
    var lastInspectionDefectRate: Double?
    var qualityBand: LotQualityBand
}

extension Engine {
    /// 品質帯のしきい値（§3.3）：推定不良率がこれ以上なら赤帯
    static let lotQualityRedThreshold = 0.25
    /// 品質帯のしきい値（§3.3）：推定不良率がこれ未満なら緑帯
    static let lotQualityGreenThreshold = 0.10

    /// ロットのルート（ロット自身のノード・露光クラスで組む）
    private static func lotRouteSteps(_ lot: Lot) -> [ProcessType] {
        RouteBuilder.routeSteps(node: Catalog.node(id: lot.nodeId) ?? Catalog.defaultNode, lithoClass: lot.lithoClass)
    }

    /// 検査ステップを通過済み（ルート内の検査ステップが stepIndex より前にある）なら推定不良率、未検査なら nil
    private static func lotInspectionDefectRate(state: GameState, lot: Lot, steps: [ProcessType]) -> Double? {
        let passed = steps.prefix(max(0, min(lot.stepIndex, steps.count)))
        guard passed.contains(.inspection) else { return nil }
        return (1 - lot.goodFraction) * derived(state: state).detectionRate
    }

    /// 推定不良率から品質帯を決める（未検査は none、0.10〜0.25 の中間も none）
    private static func lotQualityBand(defectRate: Double?) -> LotQualityBand {
        guard let rate = defectRate else { return .none }
        if rate >= lotQualityRedThreshold { return .red }
        if rate < lotQualityGreenThreshold { return .green }
        return .none
    }

    /// ロットの品質帯。LotCard・マップの FOUP 描画・現場ノート判定で同じ物差しを使う
    static func lotQualityBand(state: GameState, lot: Lot) -> LotQualityBand {
        lotQualityBand(defectRate: lotInspectionDefectRate(state: state, lot: lot, steps: lotRouteSteps(lot)))
    }

    /// ロットの進捗（§4.5）。sim が無い・ロットが無ければ nil
    static func lotProgress(state: GameState, lotId: UUID) -> LotProgress? {
        guard let sim = state.fab.sim, let lot = sim.lots.first(where: { $0.id == lotId }) else { return nil }
        let steps = lotRouteSteps(lot)
        let index = lot.stepIndex
        let current: ProcessType? = steps.indices.contains(index) ? steps[index] : nil
        let next: ProcessType? = steps.indices.contains(index + 1) ? steps[index + 1] : nil
        var passNumber = 0
        var totalPasses = 0
        if let current {
            passNumber = steps[0...index].filter { $0 == current }.count
            totalPasses = steps.filter { $0 == current }.count
        }
        var currentToolId: UUID? = nil
        if case .port(let toolId, _) = lot.location {
            currentToolId = toolId
        }
        var destinationToolId = lot.destinationToolId
        if destinationToolId == nil, case .tool(let toolId) = lot.destination {
            destinationToolId = toolId
        }
        let defectRate = lotInspectionDefectRate(state: state, lot: lot, steps: steps)
        return LotProgress(
            lotId: lot.id,
            stepIndex: index,
            totalSteps: steps.count,
            currentProcess: current,
            passNumber: passNumber,
            totalPasses: totalPasses,
            nextProcess: next,
            currentToolId: currentToolId,
            destinationToolId: destinationToolId,
            elapsedGameMin: sim.currentGameMin - lot.releasedAtGameMin,
            waitedGameMin: lot.waitedGameMin,
            expectedGoodFraction: lot.goodFraction,
            lastInspectionDefectRate: defectRate,
            qualityBand: lotQualityBand(defectRate: defectRate)
        )
    }

    /// レール滞留（§3.1 の熱色）：停止セル → そのセルが属する連続停止区間の長さ。
    /// 停止ロット = location が .rail で progress >= 0.999 のロット（セルは lot.path[cellIndex]、範囲外は無視）。
    /// 区間の定義：RailGraph の exits で隣り合う停止セル同士を向きを問わず（双方向に）結んだ連結成分。
    /// 分岐・合流で複数方向に続く場合も、辿れる停止セルはすべて同じ1区間として数える。
    /// 長さは区間内の停止セルの数（同一セルの重複は1つと数える）。sim・layout が無ければ空
    static func railCongestion(state: GameState) -> [GridPoint: Int] {
        guard let sim = state.fab.sim, let layout = state.fab.layout else { return [:] }
        var stopped = Set<GridPoint>()
        for lot in sim.lots {
            guard case .rail(let cellIndex, let progress) = lot.location, progress >= 0.999,
                  lot.path.indices.contains(cellIndex) else { continue }
            stopped.insert(lot.path[cellIndex])
        }
        guard !stopped.isEmpty else { return [:] }

        // exits は一方向なので、停止セル間の辺を両向きに張った無向グラフにする
        let graph = RailGraph(layout: layout)
        var neighbors: [GridPoint: Set<GridPoint>] = [:]
        for point in stopped {
            for exit in graph.exits(of: point) where stopped.contains(exit.to) {
                neighbors[point, default: []].insert(exit.to)
                neighbors[exit.to, default: []].insert(point)
            }
        }

        // 連結成分ごとに大きさを数える（走査は (y, x) 順で決定的）
        var result: [GridPoint: Int] = [:]
        for seed in stopped.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) where result[seed] == nil {
            var component: [GridPoint] = [seed]
            var visited: Set<GridPoint> = [seed]
            var head = 0
            while head < component.count {
                let point = component[head]
                head += 1
                for next in (neighbors[point] ?? []).sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) })
                where !visited.contains(next) {
                    visited.insert(next)
                    component.append(next)
                }
            }
            for point in component {
                result[point] = component.count
            }
        }
        return result
    }

    /// 寸断（lineBreak）の点線矢印のアンカー（§3.1）。from・to それぞれ：
    /// 工程が nil の側は投入口（from）／出荷口（to）のセルの重心、工程がある側はその工程の設置済み装置の全セルの重心。
    /// lineBreak でない・レイアウトが無い・対象工程の装置が1台も無ければ nil
    static func lineBreakAnchors(state: GameState, problem: LayoutProblem) -> (from: GridPoint, to: GridPoint)? {
        guard case .lineBreak(let fromProcess, let toProcess) = problem,
              let layout = state.fab.layout else { return nil }
        let tools = installedTools(state: state)

        func processCells(_ process: ProcessType) -> [GridPoint] {
            tools.filter { Catalog.model(id: $0.modelId)?.process == process }.flatMap { layout.cells(of: $0) }
        }
        /// 座標の平均を最も近い整数へ丸めた点（セルが無ければ nil）
        func centroid(_ cells: [GridPoint]) -> GridPoint? {
            guard !cells.isEmpty else { return nil }
            let count = Double(cells.count)
            let x = Double(cells.reduce(0) { $0 + $1.x }) / count
            let y = Double(cells.reduce(0) { $0 + $1.y }) / count
            return GridPoint(x: Int(x.rounded()), y: Int(y.rounded()))
        }

        let fromCells = fromProcess.map { processCells($0) } ?? layout.entryCells()
        let toCells = toProcess.map { processCells($0) } ?? layout.shippingCells()
        guard let from = centroid(fromCells), let to = centroid(toCells) else { return nil }
        return (from: from, to: to)
    }
}

// MARK: - 現場ノート・ガイド付きミッション（R2、simcity-rebuild §4.6）

extension Engine {
    /// 律速が続いている起点（最初に観測した gameHoursElapsed）を残すメモキー
    static let bottleneckFirstAtMemoKey = "fn.bottleneck.firstAt"
    /// 購入してもラインWPHがほぼ上がらなかった時刻を残すメモキー
    static let notBottleneckMemoKey = "fn.not_bottleneck.at"
    /// fn.not_bottleneck の閾値：購入によるラインWPHの上昇がこれ未満なら「速くならなかった」
    static let notBottleneckMinGainWPH = 0.05
    /// レール熱色が橙以上とみなす連続停止区間の長さ（railCongestion の値）
    static let railCongestionOrangeLength = 4

    /// 現場ノート判定の補助メモを更新する。律速がある間は最初に観測した時刻を保持し（既にあれば維持）、
    /// 律速が無くなったらキーを消す
    static func updateFieldNoteMemo(state: inout GameState, derived: DerivedState) {
        if derived.bottleneck != nil {
            if state.stats.noteTriggerMemo[bottleneckFirstAtMemoKey] == nil {
                state.stats.noteTriggerMemo[bottleneckFirstAtMemoKey] = state.gameHoursElapsed
            }
        } else {
            state.stats.noteTriggerMemo[bottleneckFirstAtMemoKey] = nil
        }
    }

    /// 発生条件を満たした未読の現場ノート id（Catalog.fieldNotes の順。決定的）
    static func pendingFieldNotes(state: GameState, derived: DerivedState) -> [String] {
        let unseen = Catalog.fieldNotes.filter { !state.stats.seenFieldNoteIds.contains($0.id) }
        guard !unseen.isEmpty else { return [] }
        let sim = state.fab.sim
        let memo = state.stats.noteTriggerMemo
        let problems = layoutProblems(state: state)

        func isTriggered(_ trigger: FieldNoteTrigger) -> Bool {
            switch trigger {
            case .firstLotReleased:
                return (sim?.stats.releasedLots ?? 0) >= 1
            case .firstLotCompleted:
                return state.stats.completedLots >= 1
            case .bottleneckSustained(let minutes):
                guard let firstAt = memo[bottleneckFirstAtMemoKey], derived.bottleneck != nil else { return false }
                return state.gameHoursElapsed - firstAt >= minutes / 60
            case .purchaseWithoutWPHGain:
                return memo[notBottleneckMemoKey] != nil
            case .railCongestionOrange:
                return (railCongestion(state: state).values.max() ?? 0) >= railCongestionOrangeLength
            case .littleLawObservable(let minWIP):
                return (sim?.lots.count ?? 0) >= minWIP && (sim?.cycleTimeEMA ?? 0) > 0
            case .trackedLotReentered:
                // 追跡中のロットは GameStore の状態（Engine は知らない）なので、GameStore 側で判定する
                return false
            case .firstRailBuilt:
                return state.stats.railCellsBuilt >= 1
            case .stockerInventoryAtLeast(let count):
                return (sim?.stocker.lotIds.count ?? 0) >= count
            case .unconnectedToolAppeared:
                return problems.contains { problem in
                    switch problem {
                    case .unconnectedInput, .unconnectedOutput: return true
                    case .lineBreak: return false
                    }
                }
            case .lineBreakOccurred:
                return problems.contains { problem in
                    if case .lineBreak = problem { return true }
                    return false
                }
            case .deadlockOccurred:
                return isSimDeadlocked(state: state)
            case .redBandLotAppeared:
                return sim?.lots.contains { lotQualityBand(state: state, lot: $0) == .red } ?? false
            case .marketDefectOccurred:
                return state.stats.totalMarketDefectChips > 0
            case .learningYieldGain(let points):
                return derived.learnedYield >= (Catalog.node(id: derived.nodeId)?.yieldInit ?? 0) + points
            case .marketBoom:
                return derived.marketCondition == .boom
            }
        }

        return unseen.filter { isTriggered($0.trigger) }.map { $0.id }
    }

    /// 現場ノートのタイトル。fn.little だけはリトルの法則の実数値を埋め込む
    /// （WIP ＝ スループット[FOUP/時] × サイクルタイム[時間]）
    static func fieldNoteTitle(id: String, state: GameState, derived: DerivedState) -> String {
        if id == "fn.little", let sim = state.fab.sim {
            let wip = sim.lots.count
            let throughput = MoneyFormat.decimal(sim.throughputEMA / 25, digits: 2)
            let cycleTime = MoneyFormat.decimal(sim.cycleTimeEMA / 60, digits: 0)
            return "WIP \(wip) ＝ \(throughput) × \(cycleTime)"
        }
        return Catalog.fieldNote(id: id)?.title ?? id
    }

    /// ガイド付きミッションの段 step（0 始まり。設計書 §4.6 の段 1〜5）が状態から見て満たされているか
    static func tutorialStepSatisfied(state: GameState, step: Int) -> Bool {
        switch step {
        case 0, 1, 2:
            // 眺める・装置をタップ・律速をタップは UI イベントで、状態からは判定できない。
            // GameStore.advanceTutorial がイベントを受けて進める
            return false
        case 3:
            // 増やす
            return state.subsidy.totalInvestedYen > 0
        case 4:
            // つなぐ（寸断が無く、ラインが流れている）
            return isLineConnected(state: state, derived: derived(state: state))
        default:
            return false
        }
    }
}
