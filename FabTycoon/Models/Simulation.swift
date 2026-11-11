import Foundation

// MARK: - 1.0 シミュレーションコア（ロット単位の離散シミュレーション）
// 設計書 design/redesign-1.0.md §1・§2.2・§4。P1 では搬送をレールではなく固定遅延（仮想搬送）で表す。
// 処理済みロットは行き先の空きを待たず即座に出発し、ポートを空ける（実ファブの AMHS と同様。再入工程の循環待ちデッドロック回避）。
// 収容は到着時に行う（空きポート → ストッカー → 搬送中のまま再試行）。
// 投入はプル方式：先頭工程の装置に空きポートがあり、WIP 上限未満のときだけ1ロット投入する。
// GameState は読むだけで、シミュレーション状態は SimCore 自身が保持する。乱数は使わない。
// P2: layout を与えるとレール搬送モード（Layout.swift の RailGraph による BFS 経路・1セル1ロットのブロッキング）になる。
// レール搬送は P1 の意味論にレール固有の調整を加えたもの：出発・投入は経路のある次工程（投入は先頭工程）の装置、
// 払い出しは経路があり inbound（自分より先に着くロットだけ）< 空きポート数を満たす装置を候補にする（投入は計量を免除）。
// その中からスコア選択し、出発ではストッカー経由を往路 ＋ 取り扱い ＋ 最良候補の待ちで比較して混雑時の圧力逃がしにする。
// 到着時の収容は ポート →（処理済みポートがある場合はドライブスルー）→ 待つ。
// layout が nil なら従来の仮想搬送のまま（P1 の検証値はこの分岐に依存する）。
// P3: SimSnapshot でセーブ（Fab.sim）と相互変換する。EMA 等の観測専用フィールドはシミュレーションの判断に使わない。

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
    /// レール上（P2）。cellIndex は lot.path のインデックス、progress はそのセル内の進み（1 で次セルへ）
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
    /// レール上の経路（出発時に確定。始点・終点のセルを含む）
    var path: [GridPoint] = []
    /// レール搬送の行き先
    var destination: LotDestination? = nil
    /// ストッカーの取り扱い完了時刻（これより前は払い出さない）
    var stockerHandlingUntilGameMin: Double = 0
}

/// レール搬送の行き先（P2）
enum LotDestination: Codable, Equatable {
    case tool(UUID)
    case stocker
    case shipping
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

struct SimStats: Codable, Equatable {
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
    /// 総売上・原価・市場不良ペナルティの累計（P3。オフライン精算で Stats へ反映する観測値）
    var sumGrossYen: Double = 0
    var sumCogsYen: Double = 0
    var sumPenaltyYen: Double = 0
}

/// SimCore のセーブ用スナップショット（P3、§7.1 の Fab.sim）。lots は投入順
struct SimSnapshot: Codable, Equatable {
    var tools: [ToolInstance]
    var lots: [Lot]
    var stocker: Stocker
    var currentGameMin: Double
    var lastProgressGameMin: Double
    var pendingMinutes: Double
    var wipCap: Int
    var nextLotSerial: Int
    var stats: SimStats
    var throughputEMA: Double
    var yieldEMA: Double
    var detectionEMA: Double
    var incomeEMA: Double
    var cycleTimeEMA: Double
    /// 学習枚数 W の起点（P4）。ロットの learningWafersAtRelease = これ ＋ stats.releasedWafers
    var learningWafersBase: Double = 0
}

extension SimSnapshot {
    /// P4 より前のセーブには learningWafersBase のキーが無いので 0 とみなす
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decode([ToolInstance].self, forKey: .tools)
        lots = try container.decode([Lot].self, forKey: .lots)
        stocker = try container.decode(Stocker.self, forKey: .stocker)
        currentGameMin = try container.decode(Double.self, forKey: .currentGameMin)
        lastProgressGameMin = try container.decode(Double.self, forKey: .lastProgressGameMin)
        pendingMinutes = try container.decode(Double.self, forKey: .pendingMinutes)
        wipCap = try container.decode(Int.self, forKey: .wipCap)
        nextLotSerial = try container.decode(Int.self, forKey: .nextLotSerial)
        stats = try container.decode(SimStats.self, forKey: .stats)
        throughputEMA = try container.decode(Double.self, forKey: .throughputEMA)
        yieldEMA = try container.decode(Double.self, forKey: .yieldEMA)
        detectionEMA = try container.decode(Double.self, forKey: .detectionEMA)
        incomeEMA = try container.decode(Double.self, forKey: .incomeEMA)
        cycleTimeEMA = try container.decode(Double.self, forKey: .cycleTimeEMA)
        learningWafersBase = try container.decodeIfPresent(Double.self, forKey: .learningWafersBase) ?? 0
    }
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
    var nextLotSerial: Int = 0
    /// 学習枚数 W の起点（P4）。sim 作成時点の state.learningWafers[ノード]
    var learningWafersBase: Double = 0

    // MARK: Engine が tick ごとに設定する（P4。スナップショットには含めない）

    /// 歩留まり異常の原因装置（§4・§9-7）。nil なら異常なし
    var excursionToolId: UUID? = nil
    /// 異常の欠陥倍率（工程全体に対する値。原因装置の台数シェアで割り戻して適用する）
    var excursionDefectMultiplier: Double = 1
    /// 市場イベント（汚染事故）によるロット歩留まり倍率。Engine.tick / OfflineProgress が毎回設定する（スナップショットには保存しない）
    var eventYieldMultiplier: Double = 1
    /// false なら投入しない（ノード切替の排出モード）。搬送・処理・払い出しは通常どおり
    var releasesEnabled: Bool = true

    // MARK: 観測専用（P3。シミュレーションの判断には使わない）

    /// 実時間から換算したゲーム分の端数繰越（1 ステップ未満の残り）
    var pendingMinutes: Double = 0
    /// 完了ウェハ/時（時定数 24 ゲーム時間）
    var throughputEMA: Double = 0
    /// 完了ロットの歩留まり（ロット単位、alpha 0.1）
    var yieldEMA: Double = 0
    /// 完了ロットの検出率（ロット単位、alpha 0.1）
    var detectionEMA: Double = 0
    /// 純収入/時（時定数 24 ゲーム時間）
    var incomeEMA: Double = 0
    /// 投入から出荷までのゲーム分（ロット単位、alpha 0.1）
    var cycleTimeEMA: Double = 0
    /// ロット単位の EMA の重み
    static let lotEMAAlpha: Double = 0.1
    /// 時間 EMA（throughputEMA・incomeEMA）の時定数（ゲーム分）
    static let rateEMATimeConstantGameMin: Double = 1_440

    // MARK: レール搬送（P2）

    /// 1セルの通過時間（ゲーム分、§1.6）
    static let railCellGameMin: Double = 3
    /// デッドロック判定：WIP>0 かつこの時間「処理完了・出発・到着」が無い（§1.7）
    static let deadlockGameMin: Double = 60

    /// nil なら仮想搬送（P1）
    var layout: FloorLayout? = nil
    /// 直近の進行イベント（処理完了・出発・到着・精算）の時刻
    var lastProgressGameMin: Double = 0

    var isDeadlocked: Bool {
        !lots.isEmpty && currentGameMin - lastProgressGameMin >= Self.deadlockGameMin
    }

    /// レール上で停止しているロットのセル（詰まりのハイライト用）
    var deadlockCells: [GridPoint] {
        var result: [GridPoint] = []
        for id in lotReleaseOrder {
            guard let lot = lots[id], case .rail(let index, let progress) = lot.location,
                  progress >= 0.999, index < lot.path.count else { continue }
            result.append(lot.path[index])
        }
        return result
    }

    private var railGraph: RailGraph?
    private var toolPortCells: [UUID: [GridPoint]] = [:]
    private var entryPortCells: [GridPoint] = []
    private var stockerPortCells: [GridPoint] = []
    private var shippingPortCells: [GridPoint] = []
    /// 経路キャッシュ（レイアウトは SimCore の中では変わらない）。空配列 = 経路なし
    private var railPathCache: [RailPathKey: [GridPoint]] = [:]

    init(state: GameState) {
        self.init(state: state, tools: state.fab.equipment.map { ToolInstance(instance: $0) }, layout: nil)
    }

    /// tools は配置済みの装置。layout が nil なら仮想搬送、あればレール搬送。
    /// knownPriceYen は呼び出し側が同じ state から計算済みの精算価格（nil なら derived から計算する）
    init(state: GameState, tools: [ToolInstance], layout: FloorLayout?, knownPriceYen: Double? = nil) {
        self.tools = tools
        releaseNodeId = state.fab.currentNodeId
        releaseProductId = state.currentProductId
        releaseLithoClass = Engine.topLithoClass(state: state) ?? .duvDry
        research = Engine.researchEffects(state: state)
        settlementPriceYen = knownPriceYen ?? Engine.derived(state: state).currentPriceYen
        self.layout = layout
        if let layout = layout {
            stocker.origin = layout.stocker.origin
            stocker.capacity = layout.stocker.capacity
            let graph = RailGraph(layout: layout)
            railGraph = graph
            for tool in tools {
                toolPortCells[tool.id] = graph.portCells(footprint: layout.cells(of: tool))
            }
            entryPortCells = graph.portCells(footprint: layout.entryCells())
            stockerPortCells = graph.portCells(footprint: layout.stockerCells())
            shippingPortCells = graph.portCells(footprint: layout.shippingCells())
        }
    }

    // MARK: スナップショット（P3、§7.1）

    /// セーブから復元する。レイアウトは state.fab.layout、装置はスナップショットのもの。
    /// 経路キャッシュ等の派生値は init で作り直す（レイアウトから決定的に決まるので結果は変わらない）
    init(state: GameState, snapshot: SimSnapshot, knownPriceYen: Double? = nil) {
        self.init(state: state, tools: snapshot.tools, layout: state.fab.layout, knownPriceYen: knownPriceYen)
        lots = Dictionary(snapshot.lots.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        lotReleaseOrder = snapshot.lots.map { $0.id }
        stocker = snapshot.stocker
        currentGameMin = snapshot.currentGameMin
        lastProgressGameMin = snapshot.lastProgressGameMin
        pendingMinutes = snapshot.pendingMinutes
        wipCap = snapshot.wipCap
        nextLotSerial = snapshot.nextLotSerial
        stats = snapshot.stats
        throughputEMA = snapshot.throughputEMA
        yieldEMA = snapshot.yieldEMA
        detectionEMA = snapshot.detectionEMA
        incomeEMA = snapshot.incomeEMA
        cycleTimeEMA = snapshot.cycleTimeEMA
        learningWafersBase = snapshot.learningWafersBase
    }

    /// 現在の状態のスナップショット（lots は投入順）
    func snapshot() -> SimSnapshot {
        SimSnapshot(
            tools: tools,
            lots: lotReleaseOrder.compactMap { lots[$0] },
            stocker: stocker,
            currentGameMin: currentGameMin,
            lastProgressGameMin: lastProgressGameMin,
            pendingMinutes: pendingMinutes,
            wipCap: wipCap,
            nextLotSerial: nextLotSerial,
            stats: stats,
            throughputEMA: throughputEMA,
            yieldEMA: yieldEMA,
            detectionEMA: detectionEMA,
            incomeEMA: incomeEMA,
            cycleTimeEMA: cycleTimeEMA,
            learningWafersBase: learningWafersBase
        )
    }

    /// ロットの流れていない初期スナップショット（新規ゲーム・v3 → v4 移行用）。
    /// WIP 上限は運転点、学習 W の起点は現在ノードの state.learningWafers
    static func freshSnapshot(state: GameState, tools: [ToolInstance], layout: FloorLayout?) -> SimSnapshot {
        var core = SimCore(state: state, tools: tools, layout: layout)
        core.wipCap = operatingWipCap(layout: layout)
        core.learningWafersBase = state.learningWafers[state.fab.currentNodeId] ?? 0
        return core.snapshot()
    }

    /// WIP 上限の運転点（付録 C.5）。仮想搬送は 200、レール搬送はレールセル数 ＋ 5 を [30, 200] に収める
    /// （16×16 テンプレートはレール 40 セル → 45）
    static func operatingWipCap(layout: FloorLayout?) -> Int {
        guard let layout = layout else { return 200 }
        return min(200, max(30, layout.rails.count + 5))
    }

    /// 新規ゲーム開始時のプリシードにかけるウォームアップ（ゲーム分、P6先行分）。
    /// 空のラインでは初回ロット完了まで実測 9,457 ゲーム分（一直線テンプレート・本線 y=6・レール 48 セル、
    /// トラックLINE で実測。旧リング型では 6,785 ゲーム分だった）かかり、最初の売上体験が遠すぎる。
    /// 創業時点で「既に流れていた仕掛かり」として進めた状態から始める。8,717 分では初回ロット完了が
    /// 開始後 532 tick で最終チェック（400 tick 以内の売上発生）に間に合わなかったため 9,207 分に延長した。
    /// 9,207 分では初回完了が開始後 336 tick、400 tick 時点で売上が立つ（実測）。
    /// 空ライン初回完了（9,457 分）未満なので、ウォームアップ中にロットは完了しない。
    /// この値はテンプレートの実測に合わせて調整する（リング時代は 6,000 分）
    static let initialWarmUpGameMinutes = 9_207

    /// 新規ゲーム専用の初期スナップショット（GameState.initial だけが使う。移行用の freshSnapshot は空のまま）。
    /// ウォームアップで投入されたロットは実在の仕掛かりとして残すが、統計と学習 W には数えない：
    /// SimStats をゼロに戻し、学習 W の起点も state の値（新規ゲームでは 0）のままにするため、
    /// プレイヤーの実績（総投入・学習曲線）はゲーム開始時点から数え始める。
    /// 仕掛かりロットの learningWafersAtRelease は投入時点の刻印（最大で WIP 上限 × 25 枚分）として残り、
    /// 初回ロット（最初に投入されたロット）の刻印はほぼ 0 なので初回歩留まりは従来どおり 0.6983 になる
    static func warmedInitialSnapshot(state: GameState, tools: [ToolInstance], layout: FloorLayout?) -> SimSnapshot {
        var core = SimCore(state: state, snapshot: freshSnapshot(state: state, tools: tools, layout: layout))
        for _ in 0..<initialWarmUpGameMinutes {
            core.step()
        }
        core.stats = SimStats()
        core.learningWafersBase = state.learningWafers[state.fab.currentNodeId] ?? 0
        return core.snapshot()
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

    /// 次に処理を開始したときの remainingGameMin（1 パス ＋ 端数繰越。手順 2 と共通）
    private func nextPassGameMin(_ index: Int, models: [EquipmentModel?]) -> Double {
        toolPass(index, models: models) + tools[index].processingRemainderGameMin
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

    /// 装置の台数シェア：容量（公称 WPH × Lv 倍率）÷ 同じ工程でノード nodeId を処理できる装置の容量合計
    /// （§4・§9-7 の異常の割り戻し用。そのロットを処理できる装置群の中でのシェア）
    private func capacityShare(_ index: Int, nodeId: String, models: [EquipmentModel?]) -> Double {
        guard let model = models[index] else { return 1 }
        var own = 0.0
        var total = 0.0
        for i in tools.indices {
            guard let other = models[i], other.process == model.process, other.supports(nodeId: nodeId) else { continue }
            let capacity = other.nominalWPH * Engine.levelMultiplier(tools[i].level)
            total += capacity
            if i == index { own = capacity }
        }
        return own > 0 && total > 0 ? own / total : 1
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
        // 観測 EMA 用（ステップ内の増分を測る）
        let completedWafersBefore = stats.completedWafers
        let netYenBefore = stats.sumNetYen

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
                    var f = 1 - (1 - Engine.effectiveYieldFactor(model, level: tools[t].level)) * research.yieldDefectMultiplier
                    if let excursionToolId, tools[t].id == excursionToolId, excursionDefectMultiplier > 1 {
                        // 歩留まり異常（§4・§9-7）：工程全体の倍率を原因装置の台数シェアで割り戻し、欠陥側を拡大する
                        let corrected = 1 + (excursionDefectMultiplier - 1) / capacityShare(t, nodeId: lot.nodeId, models: models)
                        f = max(0.5, 1 - (1 - f) * corrected)
                        lot.excursionHits += 1
                    }
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
                lastProgressGameMin = currentGameMin
            }
        }

        // 2. 処理開始（1台1ロット同時。最も若い待ちポートから）
        for t in tools.indices {
            guard models[t] != nil, !tools[t].ports.contains(where: { $0.state == .processing }),
                  let p = tools[t].ports.firstIndex(where: { $0.state == .waiting }) else { continue }
            tools[t].ports[p].state = .processing
            tools[t].ports[p].remainingGameMin = nextPassGameMin(t, models: models)
            tools[t].processingRemainderGameMin = 0
        }

        // 3〜6. 出発・搬送・ストッカー払い出し・投入（layout が nil なら仮想搬送、あればレール搬送）
        if layout == nil {
            stepVirtualTransport(models: models, routes: &routes)
        } else {
            stepRailTransport(models: models, routes: &routes)
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

        // 8. 観測 EMA（スループット・純収入。1ステップの増分 × 60 を時/単位に直す）
        let rateAlpha = 1 - exp(-1 / Self.rateEMATimeConstantGameMin)
        throughputEMA += ((stats.completedWafers - completedWafersBefore) * 60 - throughputEMA) * rateAlpha
        incomeEMA += ((stats.sumNetYen - netYenBefore) * 60 - incomeEMA) * rateAlpha
    }

    // MARK: 仮想搬送（P1）

    /// 手順 3〜6 の仮想搬送（固定遅延）
    private mutating func stepVirtualTransport(models: [EquipmentModel?], routes: inout [String: RouteInfo]) {
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
                lastProgressGameMin = currentGameMin
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
                        lastProgressGameMin = currentGameMin
                    } else if stocker.lotIds.count < stocker.capacity {
                        stocker.lotIds.append(lotId)
                        lot.location = .stocker
                        lot.destinationToolId = nil
                        lastProgressGameMin = currentGameMin
                    } else {
                        // 置き場が無い：次ステップで再試行
                        lot.location = .inTransit(remainingGameMin: 0, destinationToolId: destId)
                    }
                } else {
                    lastProgressGameMin = currentGameMin
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

        // 6. 投入（プル方式。先頭工程の装置に空きポートがあるときだけ、WIP 上限未満で1ロット。排出モードでは止める）
        if releasesEnabled && lots.count < wipCap {
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
                        learningWafersAtRelease: learningWafersBase + stats.releasedWafers
                    )
                    lots[lot.id] = lot
                    lotReleaseOrder.append(lot.id)
                    stats.releasedWafers += Double(Self.lotWafers)
                    stats.releasedLots += 1
                }
            }
        }
    }

    // MARK: レール搬送（P2）

    /// 経路の端点（ポートセル群）
    private enum RailEndpoint: Hashable {
        case entry, stocker, shipping
        case tool(Int)
        case cell(GridPoint)
    }

    private struct RailPathKey: Hashable {
        var from: RailEndpoint
        var to: RailEndpoint
    }

    /// セル → そこにいるロットと、そのセルから出る方向（最終セルなら nil）
    private typealias RailOccupancy = [GridPoint: [(lotId: UUID, exitDirection: RailDirection?)]]

    private struct RailCandidate {
        var index: Int
        var path: [GridPoint]
        /// P1 の score() と同じ予想待ち
        var wait: Double
        /// 経路セル数 × 3分 ＋ 予想待ち（候補同士の順位付けとストッカー迂回との比較に使う）
        var score: Double
    }

    private static func toolId(of destination: LotDestination) -> UUID? {
        if case .tool(let id) = destination { return id }
        return nil
    }

    private func railPorts(_ endpoint: RailEndpoint) -> [GridPoint] {
        switch endpoint {
        case .entry: return entryPortCells
        case .stocker: return stockerPortCells
        case .shipping: return shippingPortCells
        case .tool(let index): return toolPortCells[tools[index].id] ?? []
        case .cell(let point): return [point]
        }
    }

    /// BFS 最短経路（キャッシュつき）。経路が無ければ nil
    private mutating func railPath(from: RailEndpoint, to: RailEndpoint) -> [GridPoint]? {
        let key = RailPathKey(from: from, to: to)
        if let cached = railPathCache[key] {
            return cached.isEmpty ? nil : cached
        }
        let path = railGraph?.shortestPath(from: railPorts(from), to: Set(railPorts(to))) ?? []
        railPathCache[key] = path
        return path.isEmpty ? nil : path
    }

    /// レール上で装置へ向かうロット数（装置ごと）と、ストッカーへ向かうロット数、
    /// 装置へ向かう各ロットの残り経路セル数（path.count − cellIndex。払い出しの距離考慮型計量用）
    private func railInbound() -> (tools: [UUID: Int], stocker: Int, remainingCells: [UUID: [Int]]) {
        var counts: [UUID: Int] = [:]
        var stockerCount = 0
        var remaining: [UUID: [Int]] = [:]
        for id in lotReleaseOrder {
            guard let lot = lots[id], case .rail(let index, _) = lot.location else { continue }
            switch lot.destination {
            case .tool(let toolId)?:
                counts[toolId, default: 0] += 1
                remaining[toolId, default: []].append(lot.path.count - index)
            case .stocker?: stockerCount += 1
            case .shipping?, nil: break
            }
        }
        return (counts, stockerCount, remaining)
    }

    private func railOccupancy() -> RailOccupancy {
        var occupancy: RailOccupancy = [:]
        for id in lotReleaseOrder {
            guard let lot = lots[id], case .rail(let index, _) = lot.location, index < lot.path.count else { continue }
            Self.occupy(&occupancy, lotId: id, path: lot.path, index: index)
        }
        return occupancy
    }

    private static func occupy(_ occupancy: inout RailOccupancy, lotId: UUID, path: [GridPoint], index: Int) {
        let exit = index + 1 < path.count ? RailDirection.between(path[index], path[index + 1]) : nil
        occupancy[path[index], default: []].append((lotId: lotId, exitDirection: exit))
    }

    private static func vacate(_ occupancy: inout RailOccupancy, lotId: UUID, cell: GridPoint) {
        occupancy[cell]?.removeAll { $0.lotId == lotId }
        if occupancy[cell]?.isEmpty ?? false {
            occupancy[cell] = nil
        }
    }

    /// セルへ入れるか。travelDirection はそのセルへ入る移動方向。
    /// 空きなら可。交差セルは占有1でその出る方向の軸が直交していれば可（第2枠）
    private func canEnter(_ cell: GridPoint, travelDirection: RailDirection, occupancy: RailOccupancy) -> Bool {
        guard let rail = railGraph?.cells[cell] else { return false }
        let occupants = occupancy[cell] ?? []
        if occupants.isEmpty { return true }
        if rail.kind == .cross, occupants.count == 1, let exit = occupants[0].exitDirection,
           exit.isVertical != travelDirection.isVertical {
            return true
        }
        return false
    }

    /// 経路の先頭セルへ入線できるか（移動方向は先頭セルのレールの向きとみなす）
    private func canDepart(onto path: [GridPoint], occupancy: RailOccupancy) -> Bool {
        guard let first = path.first, let rail = railGraph?.cells[first] else { return false }
        return canEnter(first, travelDirection: rail.direction, occupancy: occupancy)
    }

    private func hasTools(process: ProcessType, nodeId: String, models: [EquipmentModel?]) -> Bool {
        models.contains { model in
            guard let model = model else { return false }
            return model.process == process && model.supports(nodeId: nodeId)
        }
    }

    /// 工程 process・ノード nodeId を処理でき、from から経路がある装置（tool index 順）。
    /// metered が true なら、.empty ポートを 1 つ以上持ち、「レール上でその装置へ向かうロットのうち残り経路セル数が
    /// この候補の経路セル数より小さいもの（自分より先に着くロット）」の数 < 空きポート数のものに限る（払い出し）。
    /// 計量の残りセル数は remainingCells（railInbound().remainingCells）を使う（スコアの予想待ちは常に inbound）
    private mutating func railCandidates(process: ProcessType, nodeId: String, from: RailEndpoint, metered: Bool,
                                         remainingCells: [UUID: [Int]] = [:],
                                         models: [EquipmentModel?], inbound: [UUID: Int]) -> [RailCandidate] {
        var result: [RailCandidate] = []
        for index in tools.indices {
            guard let model = models[index], model.process == process, model.supports(nodeId: nodeId) else { continue }
            guard let path = railPath(from: from, to: .tool(index)) else { continue }
            if metered {
                let emptyPorts = tools[index].ports.filter { $0.state == .empty }.count
                let ahead = (remainingCells[tools[index].id] ?? []).filter { $0 < path.count }.count
                guard emptyPorts > 0, ahead < emptyPorts else { continue }
            }
            let wait = score(index, models: models, inbound: inbound)
            result.append(RailCandidate(index: index, path: path, wait: wait,
                                        score: Double(path.count) * Self.railCellGameMin + wait))
        }
        return result
    }

    /// スコア（経路セル数 × 3分 ＋ 予想待ち）最小の候補（同点は tool index 順）。
    /// 予想待ちのみの順位付けも試したが定常スループットは同等（7.90 WPH）だったため、近い装置が選ばれる合計に戻した
    /// （成膜の台間偏り 88.8% / 98.2% は残課題）
    private static func bestCandidate(_ candidates: [RailCandidate]) -> RailCandidate? {
        var best: RailCandidate?
        for candidate in candidates {
            if let current = best, candidate.score >= current.score { continue }
            best = candidate
        }
        return best
    }

    /// 手順 3〜6 のレール搬送（P1 の意味論 ＋ レール固有の調整）。
    /// 出発：経路のある次工程の装置のうちスコア（経路セル数 × 3分 ＋ 予想待ち）最小へ向かう。ストッカー経由は
    /// 完全な迂回コスト「往路 ＋ 取り扱い ＋ 復路（ストッカー → 最良の直接候補、BFS セル数 × 3分）＋ その候補の待ち」で
    /// 直接の最良スコアと比べ、
    /// 行き先が混んでいるときに圧力逃がしとして選ばれる
    /// （復路を含めない形は西側の装置からストッカーが常に安く見え、迂回と往復が多発してストッカー滞留が WIP の 58% を占めたため戻した）。
    /// 候補が無ければストッカーへ退避し、それも無理なら .done のままポートに留まる。
    /// 加えて出発には「経路の先頭セルが空いていること」が要る。
    /// inbound は各フェーズ開始時にレール上のロットから数え直し、割り当てのたびに加算する。
    /// 払い出し：距離考慮型の計量（自分より先に着くロット数 < 空きポート数）を通った装置のうちスコア最小へ。
    /// 投入：計量なしで、経路のある先頭工程の装置のうちスコア最小へ。
    /// （一律の inbound 計量は遠方のロットまで予約として数え、成膜行きをストッカーに滞留させた。無計量は長距離の
    /// 払い出しが環を溢れさせて凍結した。このため自分より先に着けるロットだけを競合として数える）
    /// （到着時刻とポート空き時刻のマッチングは、処理済みポートを即空くとみなす見積もりが幽霊の容量を作り、
    /// 処理済みロットの出発自体がその容量に依存する循環待ちで凍結したため撤去した）
    /// 到着時の収容順：空きポートがあれば入線 → 行き先装置に処理済みポートがある（待つとその出口を塞ぐ）場合だけ
    /// ドライブスルー（ストッカーのポートなら直接収容 → ストッカーへ付け替え → 同じ行き先へ循環経路でループ）→
    /// それ以外はその場で待つ。満杯のストッカーへの到着は循環経路でループする。
    /// （特定ポート予約は、補充搬送の長いボトルネック装置でパイプラインが作れず枯渇させたため撤去した）
    /// ストッカーの空きは「在庫 ＋ レール上でストッカーへ向かうロット」で数える（到着時に満杯で詰まらないよう予約扱い）
    private mutating func stepRailTransport(models: [EquipmentModel?], routes: inout [String: RouteInfo]) {
        var occupancy = railOccupancy()
        let inboundState = railInbound()
        var inbound = inboundState.tools
        var stockerInbound = inboundState.stocker

        // 3. 出発（経路のある次工程の候補のうちスコア最小へ。ストッカー経由のスコア
        //    （往路 ＋ 取り扱い ＋ 復路（ストッカー → 最良候補）＋ 最良候補の待ち）の方が小さければストッカーへ：
        //    §1.7 の予防策・混雑時の圧力逃がし。
        //    候補が無ければストッカーへ退避、それも無理なら .done のまま留まる。出荷口行きは無条件）
        for t in tools.indices {
            for p in tools[t].ports.indices where tools[t].ports[p].state == .done {
                guard let lotId = tools[t].ports[p].lotId, var lot = lots[lotId] else { continue }
                let route = Self.routeInfo(nodeId: lot.nodeId, lithoClass: lot.lithoClass, cache: &routes)
                let stockerHasRoom = stocker.lotIds.count + stockerInbound < stocker.capacity
                var choice: (path: [GridPoint], destination: LotDestination)?
                if lot.stepIndex >= route.steps.count {
                    if let path = railPath(from: .tool(t), to: .shipping) {
                        choice = (path: path, destination: .shipping)
                    } else if stockerHasRoom, let path = railPath(from: .tool(t), to: .stocker) {
                        choice = (path: path, destination: .stocker)
                    }
                } else {
                    let process = route.steps[lot.stepIndex]
                    let candidates = railCandidates(process: process, nodeId: lot.nodeId, from: .tool(t), metered: false,
                                                    models: models, inbound: inbound)
                    let stockerPath = stockerHasRoom ? railPath(from: .tool(t), to: .stocker) : nil
                    if let best = Self.bestCandidate(candidates) {
                        choice = (path: best.path, destination: .tool(tools[best.index].id))
                        if let detour = stockerPath, let onward = railPath(from: .stocker, to: .tool(best.index)) {
                            let stockerScore = Double(detour.count) * Self.railCellGameMin + stocker.handlingGameMin
                                + Double(onward.count) * Self.railCellGameMin + best.wait
                            if stockerScore < best.score {
                                choice = (path: detour, destination: .stocker)
                            }
                        }
                    } else if hasTools(process: process, nodeId: lot.nodeId, models: models), let detour = stockerPath {
                        // 経路のある装置は無いが装置自体はある：ストッカーへ退避
                        choice = (path: detour, destination: .stocker)
                    }
                }
                // 行き先なし、または経路の先頭セルが塞がっている：.done のままポートに留まる
                guard let chosen = choice, canDepart(onto: chosen.path, occupancy: occupancy) else { continue }
                lot.location = .rail(cellIndex: 0, progress: 0)
                lot.path = chosen.path
                lot.destination = chosen.destination
                lot.destinationToolId = Self.toolId(of: chosen.destination)
                lots[lotId] = lot
                tools[t].ports[p] = LoadPort(lotId: nil)
                Self.occupy(&occupancy, lotId: lotId, path: chosen.path, index: 0)
                switch chosen.destination {
                case .tool(let id): inbound[id, default: 0] += 1
                case .stocker: stockerInbound += 1
                case .shipping: break
                }
                lastProgressGameMin = currentGameMin
            }
        }

        // 4. 搬送・到着（投入順に1セル/3分。次セルが塞がっていればその場で待つ）
        let railIds = lotReleaseOrder.filter {
            if case .rail? = lots[$0]?.location { return true }
            return false
        }
        var shippedIds: Set<UUID> = []
        for lotId in railIds {
            guard var lot = lots[lotId], case .rail(let index, let progressBefore) = lot.location,
                  index < lot.path.count else { continue }
            let progress = progressBefore + 1 / Self.railCellGameMin
            if progress < 1 - 1e-9 {
                lot.location = .rail(cellIndex: index, progress: progress)
                lots[lotId] = lot
                continue
            }
            let cell = lot.path[index]
            if index == lot.path.count - 1 {
                // 空きポートがあれば入線（最小インデックス）→ 無ければ、行き先装置に処理済みポートがある
                // （待つとその出口を塞ぐ）場合はドライブスルー（下）→ それ以外はその場で待つ
                // （満杯時の既定のストッカー迂回は、迂回交通そのものが環を塞ぎ WIP60 で完了 0 の凍結になったため戻した）
                var driveThrough = false
                switch lot.destination {
                case .tool(let destId)?:
                    let t = tools.firstIndex(where: { $0.id == destId })
                    if let t = t, let p = tools[t].ports.firstIndex(where: { $0.state == .empty }) {
                        tools[t].ports[p] = LoadPort(lotId: lotId, state: .waiting, remainingGameMin: 0)
                        lot.location = .port(toolId: destId, portIndex: p)
                        lot.path = []
                        lot.destination = nil
                        lot.destinationToolId = nil
                        Self.vacate(&occupancy, lotId: lotId, cell: cell)
                        lastProgressGameMin = currentGameMin
                    } else if let t = t, tools[t].ports.contains(where: { $0.state == .done }) {
                        driveThrough = true
                    } else {
                        // 全ポートが処理中または待機中：その場で待つ
                        lot.location = .rail(cellIndex: index, progress: 1)
                        lot.waitedGameMin += 1
                    }
                case .stocker?:
                    if stocker.lotIds.count < stocker.capacity {
                        stocker.lotIds.append(lotId)
                        lot.location = .stocker
                        lot.stockerHandlingUntilGameMin = currentGameMin + stocker.handlingGameMin
                        lot.path = []
                        lot.destination = nil
                        lot.destinationToolId = nil
                        Self.vacate(&occupancy, lotId: lotId, cell: cell)
                        stockerInbound -= 1
                        lastProgressGameMin = currentGameMin
                    } else if let loop = railGraph?.loopPath(from: cell, to: Set(stockerPortCells)), loop.count >= 2 {
                        // ストッカーが満杯：循環して再試行する（行き先・stockerInbound は変えない）
                        lot.path = loop
                        lot.location = .rail(cellIndex: 0, progress: 0)
                        Self.vacate(&occupancy, lotId: lotId, cell: cell)
                        Self.occupy(&occupancy, lotId: lotId, path: loop, index: 0)
                    } else {
                        lot.location = .rail(cellIndex: index, progress: 1)
                        lot.waitedGameMin += 1
                    }
                case .shipping?:
                    Self.vacate(&occupancy, lotId: lotId, cell: cell)
                    lastProgressGameMin = currentGameMin
                    settle(lot)
                    shippedIds.insert(lotId)
                    lots[lotId] = nil
                    continue
                case nil:
                    // 行き先なし（通常は起きない）：その場で待つ
                    lot.location = .rail(cellIndex: index, progress: 1)
                    lot.waitedGameMin += 1
                }
                if driveThrough {
                    // ドライブスルー：処理済みロットの出口になるポートセルに駐車させない。
                    // ストッカーのポートなら直接収容 → ストッカーへ付け替え → 同じ行き先へ循環 → その場で待つ
                    var headingToStocker = false
                    if case .stocker? = lot.destination { headingToStocker = true }
                    let stockerHasRoom = stocker.lotIds.count + stockerInbound < stocker.capacity
                    let loopGoals: Set<GridPoint>
                    switch lot.destination {
                    case .tool(let destId)?: loopGoals = Set(toolPortCells[destId] ?? [])
                    case .stocker?: loopGoals = Set(stockerPortCells)
                    default: loopGoals = []
                    }
                    if stockerHasRoom, stockerPortCells.contains(cell) {
                        // 現在セルがストッカーのポート：そのまま収容する
                        stocker.lotIds.append(lotId)
                        lot.location = .stocker
                        lot.stockerHandlingUntilGameMin = currentGameMin + stocker.handlingGameMin
                        lot.path = []
                        lot.destination = nil
                        lot.destinationToolId = nil
                        Self.vacate(&occupancy, lotId: lotId, cell: cell)
                        if headingToStocker { stockerInbound -= 1 }
                        lastProgressGameMin = currentGameMin
                    } else if stockerHasRoom,
                              let detour = railPath(from: .cell(cell), to: .stocker), detour.first == cell {
                        // 現在セルからストッカーへ付け替える
                        lot.path = detour
                        lot.location = .rail(cellIndex: 0, progress: 0)
                        lot.destination = .stocker
                        lot.destinationToolId = nil
                        Self.vacate(&occupancy, lotId: lotId, cell: cell)
                        Self.occupy(&occupancy, lotId: lotId, path: detour, index: 0)
                        if !headingToStocker { stockerInbound += 1 }
                    } else if !loopGoals.isEmpty,
                              let loop = railGraph?.loopPath(from: cell, to: loopGoals), loop.count >= 2 {
                        // 同じ行き先へ循環して再試行する（行き先・inbound は変えない）
                        lot.path = loop
                        lot.location = .rail(cellIndex: 0, progress: 0)
                        Self.vacate(&occupancy, lotId: lotId, cell: cell)
                        Self.occupy(&occupancy, lotId: lotId, path: loop, index: 0)
                    } else {
                        lot.location = .rail(cellIndex: index, progress: 1)
                        lot.waitedGameMin += 1
                    }
                }
            } else {
                let next = lot.path[index + 1]
                if let travel = RailDirection.between(cell, next),
                   canEnter(next, travelDirection: travel, occupancy: occupancy) {
                    Self.vacate(&occupancy, lotId: lotId, cell: cell)
                    lot.location = .rail(cellIndex: index + 1, progress: progress - 1)
                    Self.occupy(&occupancy, lotId: lotId, path: lot.path, index: index + 1)
                } else {
                    lot.location = .rail(cellIndex: index, progress: 1)
                    lot.waitedGameMin += 1
                }
            }
            lots[lotId] = lot
        }
        if !shippedIds.isEmpty {
            lotReleaseOrder.removeAll { shippedIds.contains($0) }
        }

        // 5. ストッカー払い出し（取り扱い時間の経過後、経路のある候補のうちスコア最小へ、経路の先頭セルへ
        //    出発できるときだけ。inbound はスコアの予想待ち用にフェーズ開始時に数え直し、払い出すたびに加算する）
        //    計量は距離考慮型：候補 T への inbound として数えるのは、レール上で T へ向かうロットのうち残り経路セル数が
        //    この払い出しの経路セル数より小さいもの（自分より先に着くロット）だけで、それが T の空きポート数未満なら通す。
        //    一律の計量は遠方のロットまで予約扱いし、最頻工程の成膜で 600 分中 0 回しか通らなかった。一方、無計量だと
        //    長距離の払い出しが環を溢れさせて凍結する。先に着けるロットだけを競合として数えれば、ストッカー隣接の
        //    成膜への補充は即座に通り、長距離の払い出しには流量調整が効く。
        let dispatchInbound = railInbound()
        inbound = dispatchInbound.tools
        var remainingCells = dispatchInbound.remainingCells
        let stockedIds = stocker.lotIds
        for lotId in stockedIds {
            guard var lot = lots[lotId], currentGameMin >= lot.stockerHandlingUntilGameMin else { continue }
            let route = Self.routeInfo(nodeId: lot.nodeId, lithoClass: lot.lithoClass, cache: &routes)
            var choice: (path: [GridPoint], destination: LotDestination)?
            if lot.stepIndex >= route.steps.count {
                if let path = railPath(from: .stocker, to: .shipping) {
                    choice = (path: path, destination: .shipping)
                }
            } else {
                let candidates = railCandidates(process: route.steps[lot.stepIndex], nodeId: lot.nodeId, from: .stocker,
                                                metered: true, remainingCells: remainingCells,
                                                models: models, inbound: inbound)
                if let best = Self.bestCandidate(candidates) {
                    choice = (path: best.path, destination: .tool(tools[best.index].id))
                }
            }
            guard let chosen = choice, canDepart(onto: chosen.path, occupancy: occupancy) else { continue }
            lot.location = .rail(cellIndex: 0, progress: 0)
            lot.path = chosen.path
            lot.destination = chosen.destination
            lot.destinationToolId = Self.toolId(of: chosen.destination)
            lots[lotId] = lot
            Self.occupy(&occupancy, lotId: lotId, path: chosen.path, index: 0)
            if let id = Self.toolId(of: chosen.destination) {
                inbound[id, default: 0] += 1
                remainingCells[id, default: []].append(chosen.path.count)
            }
            stocker.lotIds.removeAll { $0 == lotId }
        }

        // 6. 投入（プル方式。WIP 上限未満で、先頭工程の装置のうち投入口から経路がある候補のスコア最小へ、
        //    経路の先頭セルへ出発できるときだけ1ロット。inbound 計量はしない：遠方を走行中の戻りロットまで数えると
        //    投入が定常的に塞がれるため。戻りロットとのポート競合は到着時収容で処理する。排出モードでは止める）
        if releasesEnabled && lots.count < wipCap {
            inbound = railInbound().tools
            let route = Self.routeInfo(nodeId: releaseNodeId, lithoClass: releaseLithoClass, cache: &routes)
            if let first = route.steps.first {
                let candidates = railCandidates(process: first, nodeId: releaseNodeId, from: .entry, metered: false,
                                                models: models, inbound: inbound)
                if let best = Self.bestCandidate(candidates), canDepart(onto: best.path, occupancy: occupancy) {
                    nextLotSerial += 1
                    let destId = tools[best.index].id
                    let lot = Lot(
                        id: Self.lotId(serial: nextLotSerial),
                        nodeId: releaseNodeId,
                        productId: releaseProductId,
                        lithoClass: releaseLithoClass,
                        wafers: Self.lotWafers,
                        location: .rail(cellIndex: 0, progress: 0),
                        destinationToolId: destId,
                        releasedAtGameMin: currentGameMin,
                        learningWafersAtRelease: learningWafersBase + stats.releasedWafers,
                        path: best.path,
                        destination: .tool(destId)
                    )
                    lots[lot.id] = lot
                    lotReleaseOrder.append(lot.id)
                    stats.releasedWafers += Double(Self.lotWafers)
                    stats.releasedLots += 1
                }
            }
        }
    }

    // MARK: 詰まり解消（§1.7）

    /// 「詰まりを解消」：レール上・搬送中のロットと処理済みポートのロットを、投入順に手運びでストッカーへ移す。
    /// ストッカーが満杯になったら残りは投入順に廃棄する。戻り値は (ストッカーへ移した数, 廃棄した数)
    mutating func resolveDeadlockByHandCarry() -> (moved: Int, scrapped: Int) {
        var moved = 0
        var scrappedIds: Set<UUID> = []
        for lotId in lotReleaseOrder {
            guard var lot = lots[lotId] else { continue }
            var port: (toolIndex: Int, portIndex: Int)?
            switch lot.location {
            case .rail, .inTransit:
                break
            case .port(let toolId, let portIndex):
                guard let t = tools.firstIndex(where: { $0.id == toolId }), portIndex < tools[t].ports.count,
                      tools[t].ports[portIndex].state == .done else { continue }
                port = (t, portIndex)
            case .entry, .stocker:
                continue
            }
            if let port = port {
                tools[port.toolIndex].ports[port.portIndex] = LoadPort(lotId: nil)
            }
            if stocker.lotIds.count < stocker.capacity {
                stocker.lotIds.append(lotId)
                lot.location = .stocker
                lot.stockerHandlingUntilGameMin = currentGameMin + stocker.handlingGameMin
                lot.path = []
                lot.destination = nil
                lot.destinationToolId = nil
                lots[lotId] = lot
                moved += 1
            } else {
                lots[lotId] = nil
                scrappedIds.insert(lotId)
            }
        }
        if !scrappedIds.isEmpty {
            lotReleaseOrder.removeAll { scrappedIds.contains($0) }
        }
        lastProgressGameMin = currentGameMin
        return (moved, scrappedIds.count)
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
        // 市場イベント（汚染事故）の倍率は上限 0.99 で丸めた後に掛ける（倍率 0.9 なら最大でも 0.891）
        let lotYield = min(max(1 - (1 - rawYield) / product.yieldMultiplier, 0), 0.99) * eventYieldMultiplier
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
        stats.sumGrossYen += r.grossYen
        stats.sumCogsYen += r.cogsYen
        stats.sumPenaltyYen += r.penaltyYen
        if stats.firstCompletions.count < Self.firstCompletionsLimit {
            stats.firstCompletions.append(settlement)
        }

        // 観測 EMA（ロット単位）。最初の完了ロットでは 0 からのバイアスを避けてその値で初期化する
        let cycleTime = currentGameMin - lot.releasedAtGameMin
        if stats.completedLots == 1 {
            yieldEMA = lotYield
            detectionEMA = detectionRate
            cycleTimeEMA = cycleTime
        } else {
            yieldEMA += (lotYield - yieldEMA) * Self.lotEMAAlpha
            detectionEMA += (detectionRate - detectionEMA) * Self.lotEMAAlpha
            cycleTimeEMA += (cycleTime - cycleTimeEMA) * Self.lotEMAAlpha
        }
    }
}
