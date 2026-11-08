import Foundation

// MARK: - 1.0 シミュレーションコア（ロット単位の離散シミュレーション）
// 設計書 design/redesign-1.0.md §1・§2.2・§4。P1 では搬送をレールではなく固定遅延（仮想搬送）で表す。
// 処理済みロットは行き先の空きを待たず即座に出発し、ポートを空ける（実ファブの AMHS と同様。再入工程の循環待ちデッドロック回避）。
// 収容は到着時に行う（空きポート → ストッカー → 搬送中のまま再試行）。
// 投入はプル方式：先頭工程の装置に空きポートがあり、WIP 上限未満のときだけ1ロット投入する。
// GameState は読むだけで、シミュレーション状態は SimCore 自身が保持する。乱数は使わない。

// MARK: - エンティティ

struct GridPoint: Codable, Equatable, Hashable {
    var x: Int
    var y: Int
}

enum LoadPortState: String, Codable, Equatable {
    case empty
    case waiting
    case processing
    case done
}

/// 装置のロードポート（入力キュー容量を兼ねる）
struct LoadPort: Codable, Equatable {
    var lotId: UUID?
    var state: LoadPortState = .empty
    var remainingGameMin: Double = 0
}

/// 既存 EquipmentInstance ＋ 配置・稼働状態
struct ToolInstance: Codable, Equatable, Identifiable {
    var id: UUID
    var modelId: String
    var level: Int
    var purchasedAt: Date
    var origin: GridPoint
    /// 0 / 90 / 180 / 270
    var rotation: Int
    var mirrored: Bool
    var ports: [LoadPort]
    /// 直近24ゲーム時間の稼働率
    var busyEMA: Double = 0
    /// 故障は未実装（1.0 では常に nil）
    var downUntilGameMin: Double? = nil
    /// 処理時間の端数繰越（<= 0）
    var processingRemainderGameMin: Double = 0

    init(instance: EquipmentInstance) {
        id = instance.id
        modelId = instance.modelId
        level = instance.level
        purchasedAt = instance.purchasedAt
        origin = GridPoint(x: 0, y: 0)
        rotation = 0
        mirrored = false
        let portCount = Catalog.model(id: instance.modelId)?.simLoadPortCount ?? 2
        ports = Array(repeating: LoadPort(lotId: nil), count: portCount)
    }
}

enum LotLocation: Codable, Equatable {
    case entry
    case stocker
    /// destinationToolId が nil なら出荷口行き
    case inTransit(remainingGameMin: Double, destinationToolId: UUID?)
    /// P2 用（レール上）
    case rail(cellIndex: Int, progress: Double)
    case port(toolId: UUID, portIndex: Int)
}

/// FOUP 1個 = ウェハ25枚
struct Lot: Codable, Equatable, Identifiable {
    var id: UUID
    var nodeId: String
    var productId: String
    var lithoClass: LithoClass
    var wafers: Int = 25
    /// 次に処理するルートステップ
    var stepIndex: Int = 0
    var location: LotLocation
    var destinationToolId: UUID? = nil
    /// 期待良品率（装置寄与を累積）
    var goodFraction: Double = 1.0
    /// 検査で見逃す割合（検査パスで累積）
    var undetectedFraction: Double = 1.0
    var excursionHits: Int = 0
    var releasedAtGameMin: Double
    var waitedGameMin: Double = 0
    /// 投入時点の学習枚数 W
    var learningWafersAtRelease: Double
}

enum RailDirection: String, Codable, Equatable {
    case north, east, south, west
}

enum RailCellKind: String, Codable, Equatable {
    case straight, corner, branch, merge, cross
}

/// レール1セル（P1 では定義のみ）
struct RailCell: Codable, Equatable {
    var point: GridPoint
    var direction: RailDirection
    var kind: RailCellKind
    var occupantLotId: UUID? = nil
    /// 交差セルの第2枠
    var crossOccupantLotId: UUID? = nil
}

struct Stocker: Codable, Equatable {
    var origin: GridPoint = GridPoint(x: 0, y: 0)
    var capacity: Int = 40
    var lotIds: [UUID] = []
    var handlingGameMin: Double = 10
}

struct EntryPort: Codable, Equatable {
    var origin: GridPoint = GridPoint(x: 0, y: 0)
}

struct ShippingPort: Codable, Equatable {
    var origin: GridPoint = GridPoint(x: 0, y: 0)
}

// MARK: - 装置のフットプリント・ロードポート（§2.2）

extension EquipmentModel {
    /// ロードポート数：露光・クラスタは3、EUV/High-NA は4、それ以外は2
    var simLoadPortCount: Int {
        switch id {
        case "L1", "L2", "D2", "P3": return 3
        case "L3", "L4": return 4
        default: return 2
        }
    }

    /// フットプリント（幅×奥行、セル）
    var simFootprint: (width: Int, depth: Int) {
        switch id {
        case "L1", "L2": return (4, 3)
        case "L3": return (5, 4)
        case "L4": return (6, 4)
        case "D2", "P3": return (3, 3)
        case "D3", "E2", "E3", "C2", "P2": return (3, 2)
        case "I1", "I2": return (4, 2)
        default: return (2, 2)   // D1, E1, C1, Q1, Q2, Q3, P1
        }
    }
}

// MARK: - ルート生成（§1.4）

enum RouteBuilder {
    /// 露光パス数（= 層数 L）。露光クラスのオーバーライドがあればそれ
    static func lithoPasses(node: NodeSpec, lithoClass: LithoClass?) -> Int {
        Engine.passCount(for: .lithography, node: node, topLitho: lithoClass)
    }

    static func effectivePasses(node: NodeSpec, lithoClass: LithoClass?) -> [ProcessType: Int] {
        Dictionary(uniqueKeysWithValues: ProcessType.allCases.map {
            ($0, Engine.passCount(for: $0, node: node, topLitho: lithoClass))
        })
    }

    /// 工程ステップの列。工程ごとの出現回数は effectivePasses と一致する
    static func routeSteps(node: NodeSpec, lithoClass: LithoClass?) -> [ProcessType] {
        let passes = effectivePasses(node: node, lithoClass: lithoClass)
        let layers = lithoPasses(node: node, lithoClass: lithoClass)
        func count(_ p: ProcessType) -> Int { passes[p] ?? 1 }
        // 後ろの層から循環して数える（1始まりの j 番目 → 層 L − ((j−1) mod L)）
        func countsFromBack(_ n: Int) -> [Int] {
            var result = Array(repeating: 0, count: layers + 1)
            for j in stride(from: 1, through: n, by: 1) {
                result[layers - (j - 1) % layers] += 1
            }
            return result
        }
        // 前の層から循環して数える（j 番目 → 層 ((j−1) mod L) + 1）
        func countsFromFront(_ n: Int) -> [Int] {
            var result = Array(repeating: 0, count: layers + 1)
            for j in stride(from: 1, through: n, by: 1) {
                result[(j - 1) % layers + 1] += 1
            }
            return result
        }

        let implants = countsFromFront(count(.implant))
        // 成膜・エッチの余剰は [成膜, エッチ] ペアとして後ろの層から
        let extraDep = max(0, count(.deposition) - layers)
        let extraEtch = max(0, count(.etching) - layers)
        let extraDeps = countsFromBack(extraDep)
        let extraEtches = countsFromBack(extraEtch)
        let cmps = countsFromBack(count(.cmp))
        let inspectionPasses = count(.inspection)
        var inspections = Array(repeating: 0, count: layers + 1)
        for k in stride(from: 1, through: inspectionPasses, by: 1) {
            let layer = Int((Double(k * layers) / Double(inspectionPasses)).rounded())
            inspections[min(max(layer, 1), layers)] += 1
        }

        var steps: [ProcessType] = []
        for i in 1...layers {
            steps += [.deposition, .lithography, .etching]
            steps += Array(repeating: .implant, count: implants[i])
            for pair in 0..<max(extraDeps[i], extraEtches[i]) {
                if pair < extraDeps[i] { steps.append(.deposition) }
                if pair < extraEtches[i] { steps.append(.etching) }
            }
            steps += Array(repeating: .cmp, count: cmps[i])
            steps += Array(repeating: .inspection, count: inspections[i])
        }
        steps += Array(repeating: .packaging, count: count(.packaging))
        return steps
    }
}

// MARK: - 精算結果・統計

struct LotSettlement: Codable, Equatable {
    var lotId: UUID
    var wafers: Int
    /// 学習・製品倍率適用後のロット歩留まり
    var lotYield: Double
    /// このロットの D_lot = 1 − undetectedFraction
    var detectionRate: Double
    var goodChips: Double
    var detectedDefectChips: Double
    var shippedDefectChips: Double
    var grossYen: Double
    var cogsYen: Double
    var penaltyYen: Double
    var netYen: Double
}

struct SimStats: Equatable {
    /// 学習 W への加算累計（現行 learningWafers に対応）
    var releasedWafers: Double = 0
    var releasedLots: Int = 0
    var completedLots: Int = 0
    var completedWafers: Double = 0
    var sumLotYield: Double = 0
    var sumDetectionRate: Double = 0
    var sumGoodChips: Double = 0
    var sumDetectedDefectChips: Double = 0
    var sumShippedDefectChips: Double = 0
    var sumNetYen: Double = 0
    /// 先頭16件だけ保持
    var firstCompletions: [LotSettlement] = []
}

// MARK: - SimCore

struct SimCore {
    /// P1 の仮想搬送遅延（§1.6 の平均ホップ 8セル×3分相当）
    static let virtualTransitGameMin: Double = 24
    static let lotWafers = 25
    static let firstCompletionsLimit = 16
    /// busyEMA の時定数（24ゲーム時間）
    static let busyEMATimeConstantGameMin: Double = 1_440

    var tools: [ToolInstance]
    var lots: [UUID: Lot] = [:]
    /// 投入順（反復はこの順で行い、辞書 lots は直接回さない）
    var lotReleaseOrder: [UUID] = []
    var stocker = Stocker()
    var currentGameMin: Double = 0
    var releaseNodeId: String
    var releaseProductId: String
    var releaseLithoClass: LithoClass
    var research: Engine.ResearchEffects
    var settlementPriceYen: Double
    var wipCap: Int = 200
    var stats = SimStats()
    private var nextLotSerial: Int = 0

    init(state: GameState) {
        tools = state.fab.equipment.map { ToolInstance(instance: $0) }
        releaseNodeId = state.fab.currentNodeId
        releaseProductId = state.currentProductId
        releaseLithoClass = Engine.topLithoClass(state: state) ?? .duvDry
        research = Engine.researchEffects(state: state)
        settlementPriceYen = Engine.derived(state: state).currentPriceYen
    }

    /// 1パスの処理時間（ゲーム分）。§1.3
    static func tPass(model: EquipmentModel, level: Int, throughputMultiplier: Double, uptimeAddition: Double) -> Double {
        let wph = model.nominalWPH * Engine.levelMultiplier(level) * throughputMultiplier
        return Double(lotWafers) / wph * 60 / min(Engine.uptime + uptimeAddition, 0.99)
    }

    /// 連番から決定的なロットIDを作る
    static func lotId(serial: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", serial))!
    }

    // MARK: ルート

    private struct RouteInfo {
        var steps: [ProcessType]
        var passes: [ProcessType: Int]
    }

    private static func node(id: String) -> NodeSpec {
        Catalog.node(id: id) ?? Catalog.defaultNode
    }

    private static func product(id: String) -> ProductSpec {
        Catalog.product(id: id) ?? Catalog.defaultProduct
    }

    private static func routeInfo(nodeId: String, lithoClass: LithoClass,
                                  cache: inout [String: RouteInfo]) -> RouteInfo {
        let key = nodeId + "/" + lithoClass.rawValue
        if let info = cache[key] { return info }
        let spec = Self.node(id: nodeId)
        let info = RouteInfo(steps: RouteBuilder.routeSteps(node: spec, lithoClass: lithoClass),
                             passes: RouteBuilder.effectivePasses(node: spec, lithoClass: lithoClass))
        cache[key] = info
        return info
    }

    // MARK: 行き先選択

    private func toolPass(_ index: Int, models: [EquipmentModel?]) -> Double {
        guard let model = models[index] else { return .infinity }
        return Self.tPass(model: model, level: tools[index].level,
                          throughputMultiplier: research.throughputMultiplier,
                          uptimeAddition: research.uptimeAddition)
    }

    /// 予想待ち：ポート上の残り時間＋搬送中で向かっているロット数 × T_pass
    private func score(_ index: Int, models: [EquipmentModel?], inbound: [UUID: Int]) -> Double {
        let pass = toolPass(index, models: models)
        var total = 0.0
        for port in tools[index].ports {
            switch port.state {
            case .processing: total += port.remainingGameMin
            case .waiting, .done: total += pass
            case .empty: break
            }
        }
        return total + Double(inbound[tools[index].id] ?? 0) * pass
    }

    /// 工程 process・ノード nodeId を処理できる装置のうちスコア最小のもの（同点は index 順）。
    /// requireEmptyPort が true なら .empty ポートを持つ装置だけを候補にする（ストッカー払い出し・投入）
    private func bestTool(process: ProcessType, nodeId: String, requireEmptyPort: Bool,
                          models: [EquipmentModel?], inbound: [UUID: Int]) -> Int? {
        var best: (index: Int, score: Double)?
        for index in tools.indices {
            guard let model = models[index], model.process == process, model.supports(nodeId: nodeId) else { continue }
            if requireEmptyPort && !tools[index].ports.contains(where: { $0.state == .empty }) { continue }
            let s = score(index, models: models, inbound: inbound)
            if best == nil || s < best!.score {
                best = (index, s)
            }
        }
        return best?.index
    }

    /// 搬送中ロットの行き先装置ごとの件数
    private func inboundCounts() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for id in lotReleaseOrder {
            if case .inTransit(_, let dest?)? = lots[id]?.location {
                counts[dest, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: Step

    /// ゲーム内1分進める（§1.2 を P1 仮想搬送に適応）
    mutating func step() {
        let models = tools.map { Catalog.model(id: $0.modelId) }
        var routes: [String: RouteInfo] = [:]

        // 0. このステップ開始時点の稼働フラグ
        let busy = tools.map { tool in tool.ports.contains { $0.state == .processing } }

        // 1. 処理進行と完了時の歩留まり・検査効果
        for t in tools.indices {
            for p in tools[t].ports.indices where tools[t].ports[p].state == .processing {
                tools[t].ports[p].remainingGameMin -= 1
                let remaining = tools[t].ports[p].remainingGameMin
                guard remaining <= 0 else { continue }
                if let lotId = tools[t].ports[p].lotId, var lot = lots[lotId], let model = models[t] {
                    let route = Self.routeInfo(nodeId: lot.nodeId, lithoClass: lot.lithoClass, cache: &routes)
                    let process = lot.stepIndex < route.steps.count ? route.steps[lot.stepIndex] : model.process
                    let f = 1 - (1 - Engine.effectiveYieldFactor(model, level: tools[t].level)) * research.yieldDefectMultiplier
                    lot.goodFraction *= pow(f, 1.0 / Double(max(route.passes[process] ?? 1, 1)))
                    if process == .inspection {
                        let dq = min(Engine.maxDetectionRate,
                                     model.detectionBase + Engine.detectionHeadroomBonus * (1 - tools[t].busyEMA))
                        lot.undetectedFraction *= pow(1 - dq, 1.0 / Double(max(route.passes[.inspection] ?? 1, 1)))
                    }
                    lot.stepIndex += 1
                    lots[lotId] = lot
                }
                tools[t].ports[p].state = .done
                tools[t].ports[p].remainingGameMin = 0
                tools[t].processingRemainderGameMin = remaining
            }
        }

        // 2. 処理開始（1台1ロット同時。最も若い待ちポートから）
        for t in tools.indices {
            guard models[t] != nil, !tools[t].ports.contains(where: { $0.state == .processing }),
                  let p = tools[t].ports.firstIndex(where: { $0.state == .waiting }) else { continue }
            tools[t].ports[p].state = .processing
            tools[t].ports[p].remainingGameMin = toolPass(t, models: models) + tools[t].processingRemainderGameMin
            tools[t].processingRemainderGameMin = 0
        }

        // 3. 出発（次工程の装置のうちスコア最小へ。出荷は常に出す）
        //    処理済みロットは行き先の空きを待たず即座に出発し、ポートを空ける（再入工程の循環待ちデッドロック回避）。
        //    収容は到着時に行う（手順4）。次工程を処理できる装置が無い場合のみ .done のまま留まる
        var inbound = inboundCounts()
        for t in tools.indices {
            for p in tools[t].ports.indices where tools[t].ports[p].state == .done {
                guard let lotId = tools[t].ports[p].lotId, var lot = lots[lotId] else { continue }
                let route = Self.routeInfo(nodeId: lot.nodeId, lithoClass: lot.lithoClass, cache: &routes)
                if lot.stepIndex >= route.steps.count {
                    lot.location = .inTransit(remainingGameMin: Self.virtualTransitGameMin, destinationToolId: nil)
                    lot.destinationToolId = nil
                } else if let dest = bestTool(process: route.steps[lot.stepIndex], nodeId: lot.nodeId,
                                              requireEmptyPort: false, models: models, inbound: inbound) {
                    let destId = tools[dest].id
                    lot.location = .inTransit(remainingGameMin: Self.virtualTransitGameMin, destinationToolId: destId)
                    lot.destinationToolId = destId
                    inbound[destId, default: 0] += 1
                } else {
                    continue   // 次工程を処理できる装置が無い：.done のままポートに留まる
                }
                lots[lotId] = lot
                tools[t].ports[p] = LoadPort(lotId: nil)
            }
        }

        // 4. 搬送・到着
        let transitIds = lotReleaseOrder.filter {
            if case .inTransit? = lots[$0]?.location { return true }
            return false
        }
        var shippedIds: Set<UUID> = []
        for lotId in transitIds {
            guard var lot = lots[lotId],
                  case .inTransit(let remainingBefore, let destId) = lot.location else { continue }
            let remaining = remainingBefore - 1
            lot.location = .inTransit(remainingGameMin: remaining, destinationToolId: destId)
            if remaining <= 0 {
                if let destId {
                    if let t = tools.firstIndex(where: { $0.id == destId }),
                       let p = tools[t].ports.firstIndex(where: { $0.state == .empty }) {
                        tools[t].ports[p] = LoadPort(lotId: lotId, state: .waiting, remainingGameMin: 0)
                        lot.location = .port(toolId: destId, portIndex: p)
                        lot.destinationToolId = nil
                    } else if stocker.lotIds.count < stocker.capacity {
                        stocker.lotIds.append(lotId)
                        lot.location = .stocker
                        lot.destinationToolId = nil
                    } else {
                        // 置き場が無い：次ステップで再試行
                        lot.location = .inTransit(remainingGameMin: 0, destinationToolId: destId)
                    }
                } else {
                    settle(lot)
                    shippedIds.insert(lotId)
                    lots[lotId] = nil
                    continue
                }
            }
            lots[lotId] = lot
        }
        if !shippedIds.isEmpty {
            lotReleaseOrder.removeAll { shippedIds.contains($0) }
        }

        // 5. ストッカー払い出し（空きポートのある候補へ）
        inbound = inboundCounts()
        let stockedIds = stocker.lotIds
        for lotId in stockedIds {
            guard var lot = lots[lotId] else { continue }
            let route = Self.routeInfo(nodeId: lot.nodeId, lithoClass: lot.lithoClass, cache: &routes)
            guard lot.stepIndex < route.steps.count,
                  let dest = bestTool(process: route.steps[lot.stepIndex], nodeId: lot.nodeId,
                                      requireEmptyPort: true, models: models, inbound: inbound)
            else { continue }
            let destId = tools[dest].id
            lot.location = .inTransit(remainingGameMin: Self.virtualTransitGameMin, destinationToolId: destId)
            lot.destinationToolId = destId
            lots[lotId] = lot
            inbound[destId, default: 0] += 1
            stocker.lotIds.removeAll { $0 == lotId }
        }

        // 6. 投入（プル方式。先頭工程の装置に空きポートがあるときだけ、WIP 上限未満で1ロット）
        if lots.count < wipCap {
            let route = Self.routeInfo(nodeId: releaseNodeId, lithoClass: releaseLithoClass, cache: &routes)
            if let first = route.steps.first {
                if let dest = bestTool(process: first, nodeId: releaseNodeId, requireEmptyPort: true,
                                       models: models, inbound: inbound) {
                    nextLotSerial += 1
                    let destId = tools[dest].id
                    let lot = Lot(
                        id: Self.lotId(serial: nextLotSerial),
                        nodeId: releaseNodeId,
                        productId: releaseProductId,
                        lithoClass: releaseLithoClass,
                        wafers: Self.lotWafers,
                        location: .inTransit(remainingGameMin: Self.virtualTransitGameMin, destinationToolId: destId),
                        destinationToolId: destId,
                        releasedAtGameMin: currentGameMin,
                        learningWafersAtRelease: stats.releasedWafers
                    )
                    lots[lot.id] = lot
                    lotReleaseOrder.append(lot.id)
                    stats.releasedWafers += Double(Self.lotWafers)
                    stats.releasedLots += 1
                }
            }
        }

        // 7. 統計（稼働率 EMA・待ち時間）
        currentGameMin += 1
        let alpha = 1 - exp(-1 / Self.busyEMATimeConstantGameMin)
        for t in tools.indices {
            tools[t].busyEMA += ((busy[t] ? 1 : 0) - tools[t].busyEMA) * alpha
            for port in tools[t].ports where port.state == .waiting {
                if let lotId = port.lotId {
                    lots[lotId]?.waitedGameMin += 1
                }
            }
        }
    }

    // MARK: 精算（§4。現行 Engine.tick と同じ式）

    static func settle(lotYield: Double, detectionRate: Double, node: NodeSpec, product: ProductSpec, priceYen: Double)
        -> (goodChips: Double, detectedDefectChips: Double, shippedDefectChips: Double,
            grossYen: Double, cogsYen: Double, penaltyYen: Double, netYen: Double) {
        let grossDies = Double(lotWafers) * Double(product.diesPerWafer)
        let goodDies = grossDies * lotYield
        let defectDies = grossDies - goodDies
        let detectedDies = defectDies * detectionRate
        let shippedDefectDies = defectDies - detectedDies
        let outputChips = goodDies + shippedDefectDies
        let defectMix = outputChips > 0 ? shippedDefectDies / outputChips : 0
        let sale = Engine.netSale(chips: outputChips, defectRate: defectMix, priceYen: priceYen,
                                  penaltyMultiplier: product.marketPenaltyMultiplier)
        let grossYen = outputChips * priceYen
        let cogsYen = grossYen * min(max(product.cogsRate + node.cogsAddition, 0), 0.95)
        return (goodDies, detectedDies, shippedDefectDies, grossYen, cogsYen, sale.penaltyYen,
                sale.revenueYen - cogsYen)
    }

    /// 出荷口に着いたロットを精算して統計に積む
    private mutating func settle(_ lot: Lot) {
        let node = Self.node(id: lot.nodeId)
        let product = Self.product(id: lot.productId)
        // 投入時点の学習曲線で、累積した装置欠陥を欠陥側にスケールする
        let learned = node.yieldMax - (node.yieldMax - node.yieldInit)
            * exp(-lot.learningWafersAtRelease / (node.learnWafers * research.learnWafersMultiplier))
        let scale = node.yieldInit < 1 ? (1 - learned) / (1 - node.yieldInit) : 0
        let rawYield = 1 - (1 - lot.goodFraction) * scale
        let lotYield = min(max(1 - (1 - rawYield) / product.yieldMultiplier, 0), 0.99)
        let detectionRate = 1 - lot.undetectedFraction

        let r = Self.settle(lotYield: lotYield, detectionRate: detectionRate, node: node, product: product,
                            priceYen: settlementPriceYen)
        let settlement = LotSettlement(
            lotId: lot.id, wafers: lot.wafers, lotYield: lotYield, detectionRate: detectionRate,
            goodChips: r.goodChips, detectedDefectChips: r.detectedDefectChips,
            shippedDefectChips: r.shippedDefectChips, grossYen: r.grossYen, cogsYen: r.cogsYen,
            penaltyYen: r.penaltyYen, netYen: r.netYen
        )
        stats.completedLots += 1
        stats.completedWafers += Double(Self.lotWafers)
        stats.sumLotYield += lotYield
        stats.sumDetectionRate += detectionRate
        stats.sumGoodChips += r.goodChips
        stats.sumDetectedDefectChips += r.detectedDefectChips
        stats.sumShippedDefectChips += r.shippedDefectChips
        stats.sumNetYen += r.netYen
        if stats.firstCompletions.count < Self.firstCompletionsLimit {
            stats.firstCompletions.append(settlement)
        }
    }
}
