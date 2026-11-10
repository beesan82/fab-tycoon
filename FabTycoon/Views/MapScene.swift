import SwiftUI
import UIKit  // P5 スプライトの存在確認（UIImage）とメタデータ（NSDataAsset）、触覚、2本指パンの認識器

// MARK: - R1 マップ（全画面フロア＋モードレス直接操作）
// 設計書 design/simcity-rebuild.md §1・§2・§5.1・付録A・付録B。描画コアは旧 FloorGridView から移植。
// 描画は Canvas 1枚に集約し、データは state.fab.layout / placed / sim から FloorDrawData に詰めて渡す。
// 操作はモードレス（タップ選択・長押し持ち上げ・ゴースト配置）。モードはレール敷設（store.railMode）だけ。
// ゴースト表示中・レールモード中もシミュレーションは止めない。

/// フロア北側の施設帯の建物（§1.3）
enum FacilityKind: Hashable { case office, research, library }

/// ゴースト配置の依頼（建設ドロワーから。購入は確定時に課金、倉庫は無料で設置）
enum PlacementRequest: Equatable {
    case purchase(modelId: String)
    case stored(toolId: UUID)
}

/// カメラ移動の依頼（問題リスト・施設ショートカットから）。nonce を変えれば同じ対象でも再度動く
struct MapFocusRequest: Equatable {
    var toolId: UUID? = nil
    var point: GridPoint? = nil
    var nonce: Int
}

/// セル座標 ⇄ 画面座標の変換
struct FloorGridGeometry {
    static let baseCellSize: CGFloat = 24
    static let margin: CGFloat = 8

    let cellSize: CGFloat
    let offset: CGSize

    init(zoom: CGFloat, pan: CGSize) {
        cellSize = Self.baseCellSize * zoom
        offset = CGSize(width: pan.width + Self.margin, height: pan.height + Self.margin)
    }

    /// セルの左上（画面座標）
    func point(_ cell: GridPoint) -> CGPoint {
        CGPoint(x: CGFloat(cell.x) * cellSize + offset.width, y: CGFloat(cell.y) * cellSize + offset.height)
    }

    /// セルの中心（画面座標）
    func center(_ cell: GridPoint) -> CGPoint {
        let p = point(cell)
        return CGPoint(x: p.x + cellSize / 2, y: p.y + cellSize / 2)
    }

    /// origin を左上とする矩形（画面座標）
    func rect(origin: GridPoint, width: Int, depth: Int) -> CGRect {
        let p = point(origin)
        return CGRect(x: p.x, y: p.y, width: CGFloat(width) * cellSize, height: CGFloat(depth) * cellSize)
    }

    /// 画面座標を含むセル
    func cell(at location: CGPoint) -> GridPoint {
        let x = (location.x - offset.width) / cellSize
        let y = (location.y - offset.height) / cellSize
        return GridPoint(x: Int(x.rounded(.down)), y: Int(y.rounded(.down)))
    }
}

/// レール上ロットの表示補間用。sim の currentGameMin が最後に変化した時刻を覚える
final class FloorSimClock {
    private var lastGameMin: Double = -1
    private var changedAt: Double = 0

    /// 最後に sim が進んでからの実秒（進んだらリセット）
    func elapsed(gameMin: Double, now: Double) -> Double {
        if gameMin != lastGameMin {
            lastGameMin = gameMin
            changedAt = now
        }
        return max(0, now - changedAt)
    }
}

/// P5 スプライトのメタデータ（design/redesign-1.0.md §5.1、`sprites/<modelId>.json` 相当）。
/// 実体は Assets.xcassets の `eq_<id>_meta` データセットに同梱した JSON。
/// 登録のある機種だけスプライト描画し、無い機種は従来のベクタ描画にフォールバックする。
struct EquipmentSpriteMeta: Decodable {
    struct Footprint: Decodable { let width: Int; let depth: Int }
    struct PixelSize: Decodable { let width: Int; let height: Int }
    struct Body: Decodable {
        let image: String
        let drawScale: Double
        let anchor: String
        let pixelSize: PixelSize
    }
    struct Layer: Decodable {
        struct RectInBody: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
        struct Animation: Decodable { let type: String; let periodSec: Double; let squashY: Double; let activeWhen: String }
        let name: String
        let image: String
        let rectInBody: RectInBody
        let animation: Animation
    }
    struct Front: Decodable { let body: Body; let layers: [Layer] }
    struct Orientations: Decodable { let front: Front }
    let modelId: String
    let footprint: Footprint
    let orientations: Orientations
}

enum EquipmentSprites {
    private static var cache: [String: EquipmentSpriteMeta?] = [:]

    /// メタデータが同梱され、かつ本体画像が実在する機種だけを返す（第2ゲートで初期7機種に拡大）
    static func meta(modelId: String) -> EquipmentSpriteMeta? {
        if let hit = cache[modelId] { return hit }
        var result: EquipmentSpriteMeta?
        if let asset = NSDataAsset(name: "eq_\(modelId.lowercased())_meta"),
           let decoded = try? JSONDecoder().decode(EquipmentSpriteMeta.self, from: asset.data),
           UIImage(named: decoded.orientations.front.body.image) != nil {
            result = decoded
        }
        cache[modelId] = result
        return result
    }
}

/// 描画1回分のデータ（state の更新ごとに作り直す。フレームごとには作らない）
struct FloorDrawData {
    struct RailItem {
        let point: GridPoint
        let direction: RailDirection
        /// セル中心から伸ばす腕（出口＋このセルへ入ってくる隣接レールの側）
        let arms: [RailDirection]
    }

    struct ToolItem {
        let tool: ToolInstance
        let process: ProcessType?
        let isStandby: Bool
        let lamp: Color
        /// ポートにいるロット数
        let portLots: Int
        /// ルートで工程が最初に現れる順位（①〜）。工程順バッジ用（β1 実機FB対応）
        let stepRank: Int?
        /// 入力・出力ポートのどちらかがレールにつながっていない
        let isUnconnected: Bool
        /// 稼働率（busyEMA × 100）。123 オーバーレイ用
        let busyPercent: Int
        /// この装置を行き先にしているロット数。123 オーバーレイ用
        let waitingLots: Int
    }

    let layout: FloorLayout
    let rails: [RailItem]
    let tools: [ToolItem]
    let railLots: [Lot]
    let stockerLots: Int
    let entryLots: Int
    let gameMin: Double
    let bottleneckToolId: UUID?
    /// レールセルごとの混雑度（熱色レール用）
    let congestion: [GridPoint: Int]
    /// レール上ロットの品質帯（FOUP の赤帯／緑帯用）
    let lotBands: [UUID: LotQualityBand]
    let stockerCapacity: Int
    /// 仕掛かり数と上限（123 オーバーレイ用）
    let wipCount: Int
    let wipCap: Int
    /// ノード切替の排出中プレート用（切替先の名前と、旧ノードのロットの残数）
    let nodeSwitchTargetName: String?
    let nodeSwitchRemainingWIP: Int
    /// 歩留まり異常中（検査装置の「！」用。ヒント段階に関わらず出す）
    let excursionActive: Bool
    /// ライン寸断の矢印（前工程の出口 → 次工程の入口）
    let lineBreaks: [(from: GridPoint, to: GridPoint)]
    /// シミュレーションが詰まっている（ビネット用）
    let isDeadlocked: Bool
    /// 追跡中の FOUP（黄輪郭用）
    let trackedLotId: UUID?

    static let idleLamp = Color.white

    init(state: GameState, layout: FloorLayout, problems: [LayoutProblem], trackedLotId: UUID? = nil) {
        self.layout = layout
        let sim = state.fab.sim
        let nodeId = state.fab.currentNodeId

        // レール：出口と、隣から入ってくる側に腕を描く
        let graph = RailGraph(layout: layout)
        var rails: [RailItem] = []
        for cell in layout.rails {
            var arms = graph.exits(of: cell.point).map { $0.direction }
            if !arms.contains(cell.direction) { arms.append(cell.direction) }
            for d in RailDirection.ordered where !arms.contains(d) {
                let neighbor = cell.point.moved(d)
                if graph.exits(of: neighbor).contains(where: { $0.to == cell.point }) {
                    arms.append(d)
                }
            }
            rails.append(RailItem(point: cell.point, direction: cell.direction, arms: arms))
        }
        self.rails = rails

        var unconnected = Set<UUID>()
        for problem in problems {
            switch problem {
            case .unconnectedInput(let toolId, _), .unconnectedOutput(let toolId, _):
                unconnected.insert(toolId)
            case .lineBreak:
                break
            }
        }

        // 配置は placed、ポート・稼働率は sim の装置を正とする
        let node = Catalog.node(id: nodeId) ?? Catalog.defaultNode
        let stepRanks = RouteStepOrder.ranks(node: node, lithoClass: Engine.topLithoClass(state: state))
        let simTools = Dictionary((sim?.tools ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lotsById = Dictionary((sim?.lots ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 原因装置の赤ランプはヒント段階連動（設計書 §3.1・§7-13、案 A）：
        // ヒント 3 段階目まで進み、かつ現ノードで稼働する Q3 があるときだけ赤にする。
        // Q1/Q2 だけでは原因を特定できない＝検査グレードの価値を出すため。満たさなければ通常のランプ決定に任せる
        let hasActiveQ3 = Engine.installedTools(state: state).contains { placed in
            guard placed.modelId == "Q3", let model = Catalog.model(id: placed.modelId) else { return false }
            return Engine.isActive(model, nodeId: nodeId)
        }
        let causeToolId = (state.activeExcursion?.hintsRevealed ?? 0) >= 3 && hasActiveQ3
            ? state.activeExcursion?.causeToolId
            : nil
        var waitingByTool: [UUID: Int] = [:]
        for lot in sim?.lots ?? [] {
            if let dest = lot.destinationToolId { waitingByTool[dest, default: 0] += 1 }
        }
        var tools: [ToolItem] = []
        var bottleneck: (id: UUID, busy: Double)?
        for placedTool in Engine.installedTools(state: state) {
            var tool = placedTool
            if let simTool = simTools[placedTool.id] {
                tool.ports = simTool.ports
                tool.busyEMA = simTool.busyEMA
            }
            let model = Catalog.model(id: tool.modelId)
            let isStandby = model.map { !Engine.isActive($0, nodeId: nodeId) } ?? true
            let states = tool.ports.map { $0.state }
            let stuckDone = tool.ports.contains { port in
                guard port.state == .done, let lotId = port.lotId else { return false }
                return lotsById[lotId]?.destination == nil
            }
            let lamp: Color
            if let causeToolId, causeToolId == tool.id {
                lamp = .red
            } else if unconnected.contains(tool.id) || isStandby {
                lamp = .gray
            } else if stuckDone {
                lamp = .blue
            } else if states.contains(.processing) {
                lamp = .green
            } else if states.contains(.waiting) || states.contains(.done) {
                lamp = .yellow
            } else {
                lamp = Self.idleLamp
            }
            if !isStandby, states.contains(.waiting), tool.busyEMA > 0,
               tool.busyEMA > (bottleneck?.busy ?? 0) {
                bottleneck = (tool.id, tool.busyEMA)
            }
            tools.append(ToolItem(tool: tool, process: model?.process, isStandby: isStandby, lamp: lamp,
                                  portLots: tool.ports.filter { $0.lotId != nil }.count,
                                  stepRank: model.flatMap { stepRanks[$0.process] },
                                  isUnconnected: unconnected.contains(tool.id),
                                  busyPercent: Int(tool.busyEMA * 100),
                                  waitingLots: waitingByTool[tool.id] ?? 0))
        }
        self.tools = tools
        bottleneckToolId = bottleneck?.id

        var railLots: [Lot] = []
        var entryLots = 0
        for lot in sim?.lots ?? [] {
            switch lot.location {
            case .rail:
                railLots.append(lot)
            case .entry:
                entryLots += 1
            case .stocker, .inTransit, .port:
                break
            }
        }
        self.railLots = railLots
        self.entryLots = entryLots
        stockerLots = sim?.stocker.lotIds.count ?? 0
        gameMin = sim?.currentGameMin ?? 0

        congestion = Engine.railCongestion(state: state)
        var lotBands: [UUID: LotQualityBand] = [:]
        for lot in railLots {
            lotBands[lot.id] = Engine.lotQualityBand(state: state, lot: lot)
        }
        self.lotBands = lotBands
        stockerCapacity = sim?.stocker.capacity ?? 40
        wipCount = sim?.lots.count ?? 0
        wipCap = sim?.wipCap ?? 0
        if let pendingNodeId = state.fab.nodeSwitch.pendingNodeId {
            nodeSwitchTargetName = Catalog.node(id: pendingNodeId)?.displayName
            nodeSwitchRemainingWIP = (sim?.lots ?? []).filter { $0.nodeId != pendingNodeId }.count
        } else {
            nodeSwitchTargetName = nil
            nodeSwitchRemainingWIP = 0
        }
        excursionActive = state.activeExcursion != nil
        lineBreaks = problems.compactMap { problem in
            guard case .lineBreak = problem else { return nil }
            return Engine.lineBreakAnchors(state: state, problem: problem)
        }
        isDeadlocked = Engine.isSimDeadlocked(state: state)
        self.trackedLotId = trackedLotId
    }
}

/// 編集中のプレビュー（ゴースト・なぞったレール・売地看板・ポート候補・持ち上げ元）
struct FloorEditOverlay {
    var ghostOrigin: GridPoint?
    var ghostSize: (width: Int, depth: Int) = (0, 0)
    var ghostValid = false
    var strokeCells: [GridPoint] = []
    var blockedCells: [GridPoint] = []
    var eraseCells: [GridPoint] = []
    /// 売地看板を出す区画（購入済み区画に辺で接する未購入区画。常時表示）
    var addableParcels: [ParcelCoord] = []
    /// レールモード中だけ：装置外周のポート候補セル
    var portCells: [GridPoint] = []
    /// 持ち上げ中の装置（元位置を点線で残す）
    var liftedToolId: UUID?
    /// 配置直後フラッシュの対象（配置から 1 秒以内だけ。§3.2）
    var placementFlashToolId: UUID?
    /// 配置からの経過秒（描画時に毎フレーム補正する）
    var placementFlashPhase: Double = 0
}

/// フロア外の飾りに使う値（施設帯のライブ表示・売地看板の値段）。state の更新ごとに作る
struct MapDecor {
    var subsidyAvailable = false
    var researchActive = false
    var researchUnseen = false
    var unreadGlossary = 0
    var parcelCostYen: Double = 0
    var cashYen: Double = 0
}

struct MapScene: View {
    @EnvironmentObject private var store: GameStore
    /// 選択中の装置（ToolCard・問題リストと共通の真実）
    @Binding var selectedToolId: UUID?
    /// 建設ドロワーからのゴースト配置依頼（確定・キャンセルで nil に戻す）
    @Binding var placement: PlacementRequest?
    /// カメラ移動の依頼（処理したら nil に戻す）
    @Binding var focusRequest: MapFocusRequest?
    /// 装置の持ち上げ依頼（ToolCard の「移動」から。処理したら nil に戻す）
    @Binding var moveRequest: UUID?
    /// 123 オーバーレイ（数値ラベル）の表示（§3.5）
    let showNumbers: Bool
    var onOpenFacility: (FacilityKind) -> Void
    var onOpenEntry: () -> Void
    var onOpenShipping: () -> Void
    /// レール上の FOUP をタップ → 追跡開始（LotCard、§4.5）
    var onTrackLot: (UUID) -> Void
    /// 混雑したレールセルをタップ → RailCard
    var onOpenRailCard: (GridPoint) -> Void
    /// ストッカーをタップ → StockerCard
    var onOpenStockerCard: () -> Void
    /// 追跡中の FOUP が画面外にある間はその方向の矢印（↑↗→↘↓↙←↖）、画面内・追跡なしは nil（§4.5）。値が変わったときだけ呼ぶ
    var onTrackedLotDirection: (String?) -> Void

    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var panAtDragStart: CGSize?
    @State private var panAtTwoFingerStart: CGSize?
    @State private var canvasSize: CGSize = .zero
    @State private var didFit = false
    @State private var simClock = FloorSimClock()
    /// 初回の fitIfNeeded による zoom 変更はミッション段1（眺める）に数えない
    @State private var ignoreNextZoomChange = false

    @State private var message: String?
    // 1本指のタッチ（パン／持ち上げ／ゴースト移動／なぞりのどれになるかを最初に決める）
    @State private var touch: TouchTrack?
    @State private var touchSeq = 0
    /// 長押しで持ち上げた指を離したときのタップを無視する
    @State private var suppressNextTap = false
    // 装置ゴースト（購入・倉庫は placement、持ち上げ移動は movingToolId）
    @State private var movingToolId: UUID?
    @State private var ghostOrigin: GridPoint?
    @State private var ghostRotation = 0
    // レール
    @State private var railTool: RailTool = .draw
    @State private var railStroke: [GridPoint] = []
    /// 2本指操作が入ったら、そのタッチのなぞりは捨てる
    @State private var strokeCancelled = false
    /// 「元に戻す」用：直前の敷設ストロークで新規に敷いたセル（1段のみ）
    @State private var lastStrokeNewCells: [GridPoint] = []
    // 区画
    @State private var pendingParcel: ParcelCoord?

    static let zoomRange: ClosedRange<CGFloat> = 0.3...2.0
    /// ダブルタップで循環するズーム段階（§2.1）
    static let doubleTapZoomSteps: [CGFloat] = [0.97, 1.5, 2.0]
    /// 同時に描く FOUP の上限
    static let maxDrawnLots = 80
    /// 長押しで持ち上げるまでの秒数（§2.1）
    static let liftDuration: Double = 0.35
    /// この距離（pt）を超えて動いたらパン／なぞりとみなす（長押しは不成立）
    static let touchSlop: CGFloat = 6
    /// 施設帯の行数（区画の北端から y = −3〜−1）
    static let facilityBandRows = 3
    static let facilityOrder: [FacilityKind] = [.office, .research, .library]
    /// 上端 HUD と下端ドックの高さ（§1.1）。初期表示の収め方とモードバー・ツールバーの位置に使う
    static let hudHeight: CGFloat = 56
    static let dockHeight: CGFloat = 64

    /// レールモードの道具（パンは2本指に寄せたので「移動」は無い）
    enum RailTool: Hashable {
        case draw
        case erase
    }

    private enum TouchMode: Equatable {
        case undecided
        case pan
        case pinch
        case stroke
        /// 表示中のゴーストを掴んで動かす（grab = 掴んだセルのゴースト原点からのずれ）
        case ghost(grab: GridPoint)
        /// 長押しで持ち上げた装置を動かす
        case lift(grab: GridPoint)
    }

    private struct TouchTrack: Equatable {
        let id: Int
        /// 始点。onEnded が来ないまま（取り消し）次のタッチが来ても、始点が変わるので作り直せる
        let start: CGPoint
        var mode: TouchMode
    }

    private typealias GhostStatus = (tool: ToolInstance, origin: GridPoint, error: String?)

    /// 購入ゴーストの仮 id（未購入の ToolInstance をゴースト中ずっと同じ id で扱う）
    private static let purchaseProbeId = UUID()

    /// 選択枠の対象。selectedToolId と常に同じ（旧 FloorGridView の選択枠描画をそのまま使う）
    private var highlightedToolId: UUID? { selectedToolId }

    private var ghostActive: Bool { placement != nil || movingToolId != nil }

    init(selectedToolId: Binding<UUID?>,
         placement: Binding<PlacementRequest?>,
         focusRequest: Binding<MapFocusRequest?>,
         moveRequest: Binding<UUID?>,
         showNumbers: Bool = false,
         onOpenFacility: @escaping (FacilityKind) -> Void,
         onOpenEntry: @escaping () -> Void,
         onOpenShipping: @escaping () -> Void,
         onTrackLot: @escaping (UUID) -> Void = { _ in },
         onOpenRailCard: @escaping (GridPoint) -> Void = { _ in },
         onOpenStockerCard: @escaping () -> Void = {},
         onTrackedLotDirection: @escaping (String?) -> Void = { _ in }) {
        _selectedToolId = selectedToolId
        _placement = placement
        _focusRequest = focusRequest
        _moveRequest = moveRequest
        self.showNumbers = showNumbers
        self.onOpenFacility = onOpenFacility
        self.onOpenEntry = onOpenEntry
        self.onOpenShipping = onOpenShipping
        self.onTrackLot = onTrackLot
        self.onOpenRailCard = onOpenRailCard
        self.onOpenStockerCard = onOpenStockerCard
        self.onTrackedLotDirection = onTrackedLotDirection
    }

    var body: some View {
        let state = store.state
        let trackedDirection = trackedLotDirection(state: state)
        Group {
            if let layout = state.fab.layout {
                let data = FloorDrawData(state: state, layout: layout, problems: store.layoutProblems,
                                         trackedLotId: store.trackedLotId)
                floorCanvas(layout: layout, data: data, decor: decor(state: state))
            } else {
                Text("フロアのデータがありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selectedToolId) { _, newId in
            // 持ち上げた装置ではカメラを動かさない（指の下からずれるため）
            if let newId, newId != movingToolId {
                focus(on: newId)
            }
        }
        .onChange(of: placement) { _, request in
            beginPlacement(request)
        }
        .onChange(of: focusRequest) { _, request in
            handleFocusRequest(request)
        }
        .onChange(of: moveRequest) { _, toolId in
            handleMoveRequest(toolId)
        }
        .onChange(of: store.railMode) { _, isOn in
            railModeChanged(isOn)
        }
        .onChange(of: trackedDirection, initial: true) { _, direction in
            // body は tick・パン・ズームごとに再評価されるが、通知は矢印が変わったときだけ
            onTrackedLotDirection(direction)
        }
        .onChange(of: zoom) { _, _ in
            // ミッション段1「フロアを眺めよう」はズーム変更で達成（§4.6）
            if ignoreNextZoomChange {
                ignoreNextZoomChange = false
                return
            }
            if store.state.stats.tutorialStep == 0 {
                store.advanceTutorial()
            }
        }
        .alert(
            "区画を購入しますか？",
            isPresented: Binding(
                get: { pendingParcel != nil },
                set: { if !$0 { pendingParcel = nil } }
            ),
            presenting: pendingParcel
        ) { coord in
            Button("購入する（\(MoneyFormat.yen(Engine.expansionCostYen(state: store.state)))）") {
                if !store.buyParcel(coord: coord) {
                    message = "区画を購入できませんでした（資金不足）"
                }
                pendingParcel = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingParcel = nil
            }
        } message: { _ in
            Text("\(FloorLayout.parcelSize)×\(FloorLayout.parcelSize)セルの区画を \(MoneyFormat.yen(Engine.expansionCostYen(state: store.state))) で購入します。")
        }
    }

    // MARK: キャンバス

    private func floorCanvas(layout: FloorLayout, data: FloorDrawData, decor: MapDecor) -> some View {
        let geometry = FloorGridGeometry(zoom: zoom, pan: panOffset)
        let overlay = editOverlay(layout: layout, data: data)
        let clock = simClock
        let inventoryChips = store.state.fab.inventoryChips
        let showNumbers = self.showNumbers
        let flashAt = store.placementFeedback?.at.timeIntervalSinceReferenceDate
        // R2 の点滅・脈動（未接続プラグ・ストッカー満杯・ビネット・配置フラッシュ）も止めない
        let animatingR2 = data.isDeadlocked || data.stockerLots >= data.stockerCapacity
            || data.tools.contains { $0.isUnconnected } || overlay.placementFlashToolId != nil
        let paused = data.railLots.isEmpty && data.bottleneckToolId == nil && !decor.researchActive && !animatingR2
        return GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let elapsed = clock.elapsed(gameMin: data.gameMin, now: now)
                    // 配置フラッシュの経過秒は state 更新間隔（0.25 秒）より細かく要るのでフレームごとに補正する
                    var frameOverlay = overlay
                    if frameOverlay.placementFlashToolId != nil, let flashAt {
                        frameOverlay.placementFlashPhase = now - flashAt
                        if frameOverlay.placementFlashPhase > 1 { frameOverlay.placementFlashToolId = nil }
                    }
                    drawFloor(context, size: size, data: data, overlay: frameOverlay, decor: decor, geometry: geometry,
                              now: now, simElapsed: elapsed, showNumbers: showNumbers, inventoryChips: inventoryChips)
                }
            }
            .contentShape(Rectangle())
            // ダブルタップを先に付ける（単発タップはダブルタップ不成立を待ってから届く）
            .onTapGesture(count: 2) { location in
                handleDoubleTap(at: location)
            }
            .onTapGesture { location in
                handleTap(geometry.cell(at: location), layout: layout)
            }
            .simultaneousGesture(touchGesture(geometry: geometry, layout: layout))
            .simultaneousGesture(magnifyGesture)
            .background(
                TwoFingerPanCatcher(isEnabled: store.railMode,
                                    onChanged: { twoFingerPanChanged($0) },
                                    onEnded: { twoFingerPanEnded() })
            )
            .overlay(alignment: .top) {
                if store.railMode {
                    railModeBar(layout: layout)
                        .padding(.top, Self.hudHeight + 8)
                        .padding(.horizontal, 10)
                }
            }
            .overlay {
                ghostToolbarLayer(layout: layout, geometry: geometry, size: geo.size)
            }
            .overlay(alignment: .bottom) {
                if let message, !store.railMode, !ghostActive {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, Self.dockHeight + 12)
                }
            }
            .onAppear {
                canvasSize = geo.size
                fitIfNeeded(layout: layout)
                if placement != nil && ghostOrigin == nil {
                    beginPlacement(placement)
                }
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
                fitIfNeeded(layout: layout)
            }
        }
    }

    private func decor(state: GameState) -> MapDecor {
        var decor = MapDecor()
        decor.subsidyAvailable = Engine.canApplySubsidy(state: state)
        decor.researchActive = state.research.inProgressId != nil
        decor.researchUnseen = state.research.hasUnseenCompletion
        // 図鑑の NEW（GlossaryView と同じ：解放済みかつ未読）
        decor.unreadGlossary = Engine.glossaryEntries(state: state).filter { $0.unlocked && !$0.isRead }.count
        decor.parcelCostYen = Engine.expansionCostYen(state: state)
        decor.cashYen = state.cashYen
        return decor
    }

    // MARK: ジェスチャ

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // 2本指が入ったら：なぞりは捨て、長押しの持ち上げも成立させない
                if store.railMode && !strokeCancelled {
                    strokeCancelled = true
                    railStroke = []
                }
                if touch?.mode == .undecided {
                    touch?.mode = .pinch
                }
                let base = zoomAtGestureStart ?? zoom
                if zoomAtGestureStart == nil {
                    zoomAtGestureStart = zoom
                }
                zoom = min(max(base * value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
            }
            .onEnded { _ in
                zoomAtGestureStart = nil
            }
    }

    /// 1本指のタッチ。始点で役割を決める：レールモードならなぞり、ゴーストの上ならゴースト移動、
    /// それ以外は「未定」→ 動けばパン／0.35 秒動かず装置の上なら持ち上げ（§2.1）。
    /// ゴーストの確定はしない（確定は浮動ツールバーのボタンだけ。β1 実機FB対応）
    private func touchGesture(geometry: FloorGridGeometry, layout: FloorLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if touch?.start != value.startLocation {
                    beginTouch(at: value.startLocation, geometry: geometry, layout: layout)
                }
                guard let current = touch else { return }
                let moved = hypot(value.translation.width, value.translation.height)
                switch current.mode {
                case .undecided, .pan:
                    guard current.mode == .pan || moved > Self.touchSlop else { return }
                    if current.mode == .undecided {
                        touch?.mode = .pan
                    }
                    let start = panAtDragStart ?? panOffset
                    if panAtDragStart == nil {
                        panAtDragStart = panOffset
                    }
                    panOffset = CGSize(width: start.width + value.translation.width,
                                       height: start.height + value.translation.height)
                case .pinch:
                    break
                case .stroke:
                    guard !strokeCancelled, !railStroke.isEmpty || moved > Self.touchSlop else { return }
                    if railStroke.isEmpty {
                        extendStroke(to: geometry.cell(at: value.startLocation))
                    }
                    extendStroke(to: geometry.cell(at: value.location))
                case .ghost(let grab):
                    guard moved > Self.touchSlop else { return }
                    let cell = geometry.cell(at: value.location)
                    updateGhost(to: GridPoint(x: cell.x - grab.x, y: cell.y - grab.y), layout: layout)
                case .lift(let grab):
                    let cell = geometry.cell(at: value.location)
                    updateGhost(to: GridPoint(x: cell.x - grab.x, y: cell.y - grab.y), layout: layout)
                }
            }
            .onEnded { _ in
                if touch?.mode == .stroke, !strokeCancelled, !railStroke.isEmpty {
                    commitStroke(layout: layout)
                }
                railStroke = []
                strokeCancelled = false
                touch = nil
                panAtDragStart = nil
            }
    }

    private func beginTouch(at location: CGPoint, geometry: FloorGridGeometry, layout: FloorLayout) {
        touchSeq += 1
        suppressNextTap = false
        // 前のタッチが取り消しで終わっていた場合の後始末
        panAtDragStart = nil
        railStroke = []
        let cell = geometry.cell(at: location)
        var mode = TouchMode.undecided
        if store.railMode {
            mode = .stroke
            strokeCancelled = false
        } else if let ghost = ghostStatus(layout: layout) {
            // ゴーストとその周囲 1 セルを掴めば動かせる（指のブレ吸収）。それ以外はパン
            let size = FloorLayout.footprintSize(modelId: ghost.tool.modelId, rotation: ghostRotation)
            let dx = cell.x - ghost.origin.x
            let dy = cell.y - ghost.origin.y
            if (-1...size.width).contains(dx) && (-1...size.depth).contains(dy) {
                mode = .ghost(grab: GridPoint(x: min(max(dx, 0), size.width - 1), y: min(max(dy, 0), size.depth - 1)))
            }
        }
        touch = TouchTrack(id: touchSeq, start: location, mode: mode)
        if mode == .undecided && !ghostActive {
            let id = touchSeq
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftDuration) {
                liftIfStill(touchId: id, at: location)
            }
        }
    }

    /// 長押し成立：同じタッチがまだ動いていなければ、指の下の装置を持ち上げてゴーストにする（§2.4）
    private func liftIfStill(touchId: Int, at location: CGPoint) {
        guard let current = touch, current.id == touchId, current.mode == .undecided,
              !store.railMode, !ghostActive, let layout = store.state.fab.layout else { return }
        let cell = FloorGridGeometry(zoom: zoom, pan: panOffset).cell(at: location)
        // 長押しは装置の上でだけ。空き床は何もしない（誤爆防止）
        guard let tool = store.state.fab.placed.first(where: { layout.cells(of: $0).contains(cell) }) else { return }
        touch?.mode = .lift(grab: GridPoint(x: cell.x - tool.origin.x, y: cell.y - tool.origin.y))
        beginLift(toolId: tool.id)
        suppressNextTap = true
    }

    /// 装置を持ち上げてゴーストにする（長押しと「移動」依頼で共通）。持ち上げられなければ false
    @discardableResult
    private func beginLift(toolId: UUID) -> Bool {
        guard !store.railMode, !ghostActive,
              let tool = store.state.fab.placed.first(where: { $0.id == toolId }) else { return false }
        movingToolId = tool.id
        // 現在位置・回転からゴーストを出す（指を離さずドラッグでそのまま動かせる）
        ghostRotation = tool.rotation
        ghostOrigin = tool.origin
        message = nil
        selectedToolId = tool.id
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return true
    }

    /// レールモードの2本指パン（UIKit の認識器から）
    private func twoFingerPanChanged(_ translation: CGSize) {
        if !strokeCancelled {
            strokeCancelled = true
            railStroke = []
        }
        let start = panAtTwoFingerStart ?? panOffset
        if panAtTwoFingerStart == nil {
            panAtTwoFingerStart = panOffset
        }
        panOffset = CGSize(width: start.width + translation.width, height: start.height + translation.height)
    }

    private func twoFingerPanEnded() {
        panAtTwoFingerStart = nil
    }

    /// なぞったセル列を伸ばす（離れたセルへは Manhattan で補完）
    private func extendStroke(to cell: GridPoint) {
        guard let last = railStroke.last else {
            railStroke = [cell]
            return
        }
        var cursor = last
        var added = 0
        while cursor != cell && added < 200 {
            if cursor.x != cell.x {
                cursor = GridPoint(x: cursor.x + (cell.x > cursor.x ? 1 : -1), y: cursor.y)
            } else {
                cursor = GridPoint(x: cursor.x, y: cursor.y + (cell.y > cursor.y ? 1 : -1))
            }
            railStroke.append(cursor)
            added += 1
        }
    }

    // MARK: タップ

    /// タップのヒットテスト（§2.1）：施設帯 → 投入口／出荷口 → 売地 → 装置 → それ以外は選択解除
    private func handleTap(_ cell: GridPoint, layout: FloorLayout) {
        if suppressNextTap {
            suppressNextTap = false
            return
        }
        message = nil
        if store.railMode {
            railTap(cell, layout: layout)
            return
        }
        if ghostActive {
            // ゴースト表示中：タップはゴーストの移動だけ（ゴースト自身のタップは無視）
            if let ghost = ghostStatus(layout: layout) {
                let size = FloorLayout.footprintSize(modelId: ghost.tool.modelId, rotation: ghostRotation)
                if FloorLayout.cells(origin: ghost.origin, size: size).contains(cell) { return }
            }
            updateGhost(to: cell, layout: layout)
            return
        }
        if let kind = Self.facility(at: cell, layout: layout) {
            onOpenFacility(kind)
            return
        }
        if layout.entryCells().contains(cell) {
            onOpenEntry()
            return
        }
        if layout.shippingCells().contains(cell) {
            onOpenShipping()
            return
        }
        let coord = layout.parcel(of: cell)
        if layout.canAddParcel(coord) {
            pendingParcel = coord
            return
        }
        if let hitTool = store.state.fab.placed.first(where: { layout.cells(of: $0).contains(cell) }) {
            selectedToolId = hitTool.id
            return
        }
        // FOUP：レール上ロットのいるセル → LotCard（追跡、§4.5）
        if let lot = store.state.fab.sim?.lots.first(where: { lot in
            guard case .rail(let cellIndex, _) = lot.location, lot.path.indices.contains(cellIndex) else { return false }
            return lot.path[cellIndex] == cell
        }) {
            selectedToolId = nil
            onTrackLot(lot.id)
            return
        }
        // ストッカー → StockerCard
        if layout.stockerCells().contains(cell) {
            selectedToolId = nil
            onOpenStockerCard()
            return
        }
        // 混雑しているレールセル（停止ロット 2 個以上）→ RailCard（§2.5・§3.1）
        if layout.railIndex[cell] != nil, (Engine.railCongestion(state: store.state)[cell] ?? 0) >= 2 {
            selectedToolId = nil
            onOpenRailCard(cell)
            return
        }
        // 空き床・それ以外のレール
        selectedToolId = nil
    }

    /// レールモードの1セルタップ（既存どおり）
    private func railTap(_ cell: GridPoint, layout: FloorLayout) {
        switch railTool {
        case .erase:
            if layout.railIndex[cell] != nil && !store.removeRail(at: cell) {
                message = "撤去できません（ストッカーが満杯です）"
            }
        case .draw:
            // 既存レールは向きを時計回りに回す（無償）、空きなら東向きで敷く
            if var existing = layout.railIndex[cell] {
                existing.direction = existing.direction.rotatedCW
                store.setRail(cell: existing)
            } else if layout.railPlacementError(at: cell, among: store.state.fab.placed) == nil {
                if store.setRail(cell: RailCell(point: cell, direction: .east, kind: .straight)) {
                    lastStrokeNewCells = [cell]
                } else {
                    message = "資金が不足しています"
                }
            }
        }
    }

    /// ダブルタップ：そのセルを画面中央にしてズームを 1 段進める（0.97 → 1.5 → 2.0 → 0.97）
    private func handleDoubleTap(at location: CGPoint) {
        guard canvasSize.width > 0 else { return }
        let cell = FloorGridGeometry(zoom: zoom, pan: panOffset).cell(at: location)
        let next = Self.doubleTapZoomSteps.first { $0 > zoom + 0.01 } ?? Self.doubleTapZoomSteps[0]
        zoom = min(max(next, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        center(on: cell)
    }

    // MARK: レール

    /// なぞったセル列から敷くセルを決める。向きは移動方向、方向が変わるセルは角。
    /// 既存レールを壊さないよう、始点が既存レールで直交方向へ出るなら分岐、終点が既存レールなら合流として触らない、
    /// 途中で既存レールを直交に横切るなら交差にする。同じセルを複数回なぞったら最後のものを使う
    static func plannedRailCells(stroke: [GridPoint], layout: FloorLayout) -> [RailCell] {
        guard stroke.count >= 2 else { return [] }
        let existing = layout.railIndex
        var result: [RailCell] = []
        var indexByPoint: [GridPoint: Int] = [:]
        let last = stroke.count - 1
        for i in stroke.indices {
            let point = stroke[i]
            let incoming: RailDirection? = i > 0 ? RailDirection.between(stroke[i - 1], point) : nil
            let outgoing: RailDirection? = i < last ? RailDirection.between(point, stroke[i + 1]) : incoming
            guard let direction = outgoing else { continue }
            var cell: RailCell
            if let old = existing[point] {
                cell = old
                let perpendicular = old.direction.isVertical != direction.isVertical
                if i == last {
                    continue
                } else if i == 0 {
                    if old.direction == direction { continue }
                    if perpendicular {
                        cell.kind = .branch
                    } else {
                        cell.direction = direction
                        cell.kind = .straight
                    }
                } else if perpendicular && incoming == outgoing {
                    cell.kind = .cross
                } else {
                    cell.direction = direction
                    cell.kind = (incoming != nil && incoming != direction) ? .corner : .straight
                }
            } else {
                let kind: RailCellKind = (incoming != nil && incoming != direction) ? .corner : .straight
                cell = RailCell(point: point, direction: direction, kind: kind)
            }
            if let index = indexByPoint[point] {
                result[index] = cell
            } else {
                indexByPoint[point] = result.count
                result.append(cell)
            }
        }
        return result
    }

    /// なぞり中のプレビュー：敷けるセル・敷けないセル・新規セル数
    private func railPreview(layout: FloorLayout) -> (cells: [RailCell], blocked: [GridPoint], newCount: Int) {
        let placed = store.state.fab.placed
        let existing = layout.railIndex
        var cells: [RailCell] = []
        var blocked: [GridPoint] = []
        var newCount = 0
        for cell in Self.plannedRailCells(stroke: railStroke, layout: layout) {
            if layout.railPlacementError(at: cell.point, among: placed) != nil {
                blocked.append(cell.point)
                continue
            }
            cells.append(cell)
            if existing[cell.point] == nil {
                newCount += 1
            }
        }
        return (cells, blocked, newCount)
    }

    /// なぞりの中で撤去対象になる既存レールのセル（重複なし）
    private func eraseTargets(layout: FloorLayout) -> [GridPoint] {
        let existing = layout.railIndex
        var seen = Set<GridPoint>()
        var result: [GridPoint] = []
        for point in railStroke where existing[point] != nil && !seen.contains(point) {
            seen.insert(point)
            result.append(point)
        }
        return result
    }

    private func commitStroke(layout: FloorLayout) {
        defer { railStroke = [] }
        guard !railStroke.isEmpty else { return }
        if railTool == .erase {
            // 消しゴムのストロークは「元に戻す」の対象にしない
            var failed = 0
            for point in eraseTargets(layout: layout) {
                if !store.removeRail(at: point) {
                    failed += 1
                }
            }
            if failed > 0 {
                message = "\(failed)セルは撤去できませんでした（ストッカーが満杯です）"
            }
            return
        }
        let existing = layout.railIndex
        let preview = railPreview(layout: layout)
        var failed = 0
        var added: [GridPoint] = []
        for cell in preview.cells {
            if store.setRail(cell: cell) {
                if existing[cell.point] == nil {
                    added.append(cell.point)
                }
            } else {
                failed += 1
            }
        }
        lastStrokeNewCells = added
        if failed > 0 {
            message = "資金不足で\(failed)セル敷けませんでした"
        } else if !preview.blocked.isEmpty {
            message = "装置・固定設備・未購入区画の\(preview.blocked.count)セルには敷けません"
        }
    }

    /// 直前の敷設ストロークで新規に敷いたセルを撤去する（全額返金。1段のみ）
    private func undoLastStroke() {
        let rails = store.state.fab.layout?.railIndex ?? [:]
        var failed = 0
        for point in lastStrokeNewCells where rails[point] != nil {
            if !store.removeRail(at: point) {
                failed += 1
            }
        }
        lastStrokeNewCells = []
        message = failed > 0 ? "\(failed)セルは戻せませんでした（ストッカーが満杯です）" : nil
    }

    private func railModeChanged(_ isOn: Bool) {
        railStroke = []
        strokeCancelled = false
        lastStrokeNewCells = []
        railTool = .draw
        message = nil
        if isOn && ghostActive {
            cancelGhost()
        }
    }

    /// レールモードのポート候補：装置外周（4近傍）のうち、既にレールがあるセル（RailGraph.portCells）と、
    /// レールを敷けるセル（購入済み・装置／固定設備と重ならない）
    private func portCandidates(layout: FloorLayout, data: FloorDrawData) -> [GridPoint] {
        let graph = RailGraph(layout: layout)
        let rails = layout.railIndex
        var occupied = layout.facilityCells()
        for item in data.tools {
            occupied.formUnion(layout.cells(of: item.tool))
        }
        var result = Set<GridPoint>()
        for item in data.tools {
            let footprint = layout.cells(of: item.tool)
            result.formUnion(graph.portCells(footprint: footprint))
            for cell in footprint {
                for d in RailDirection.ordered {
                    let next = cell.moved(d)
                    if rails[next] == nil, !occupied.contains(next), layout.isPurchased(cell: next) {
                        result.insert(next)
                    }
                }
            }
        }
        return Array(result)
    }

    // MARK: ゴースト（購入・倉庫・持ち上げ移動で共通）

    /// ゴーストの対象装置（購入なら未購入の仮インスタンス、倉庫なら倉庫の装置、持ち上げなら配置済みの装置）
    private func ghostTarget() -> ToolInstance? {
        let fab = store.state.fab
        switch placement {
        case .purchase(let modelId):
            return ToolInstance(instance: EquipmentInstance(id: Self.purchaseProbeId, modelId: modelId, level: 1))
        case .stored(let toolId):
            return fab.storedEquipment.first(where: { $0.id == toolId }).map { ToolInstance(instance: $0) }
        case nil:
            guard let movingToolId else { return nil }
            return fab.placed.first(where: { $0.id == movingToolId })
        }
    }

    /// ゴーストの対象装置と確定できない理由（ゴーストが無ければ nil）。
    /// 購入は資金・ロック・配置をまとめて Engine.buyBlockReason で、倉庫・移動は配置可否だけを見る
    private func ghostStatus(layout: FloorLayout) -> GhostStatus? {
        guard let origin = ghostOrigin, let tool = ghostTarget() else { return nil }
        let error: String?
        if case .purchase(let modelId) = placement {
            error = Engine.buyBlockReason(state: store.state, modelId: modelId, origin: origin, rotation: ghostRotation)
                .map(Self.buyBlockText)
        } else {
            error = layout.toolPlacementError(tool, origin: origin, rotation: ghostRotation, among: store.state.fab.placed)
        }
        return (tool, origin, error)
    }

    static func buyBlockText(_ reason: BuyBlockReason) -> String {
        switch reason {
        case .unknownModel:
            return "不明な装置です"
        case .locked(let reasons):
            return reasons.joined(separator: "／")
        case .noFreeSlot:
            return "フロアに空きがありません"
        case .insufficientCash(let shortfall):
            return "資金不足（あと\(MoneyFormat.yen(shortfall))）"
        case .cannotPlace(let message):
            return message
        }
    }

    /// タップ／ドラッグでゴーストを動かす。近傍に置けるセルがあればスナップし、
    /// 無ければ指の位置そのまま（赤ゴーストで「置けない」ことが分かる）
    private func updateGhost(to raw: GridPoint, layout: FloorLayout) {
        guard let tool = ghostTarget() else { return }
        message = nil
        ghostOrigin = layout.snappedOrigin(for: tool, near: raw, rotation: ghostRotation,
                                           among: store.state.fab.placed) ?? raw
    }

    /// 配置依頼が来たら画面中央のセルにゴーストを出す（§2.2）。nil になったら畳む（持ち上げ中は残す）
    private func beginPlacement(_ request: PlacementRequest?) {
        guard let request else {
            if movingToolId == nil {
                ghostOrigin = nil
                ghostRotation = 0
            }
            return
        }
        movingToolId = nil
        ghostOrigin = nil
        ghostRotation = 0
        message = nil
        if store.railMode {
            store.railMode = false
        }
        if case .stored(let toolId) = request,
           !store.state.fab.storedEquipment.contains(where: { $0.id == toolId }) {
            placement = nil
            return
        }
        guard let layout = store.state.fab.layout, canvasSize.width > 0, let tool = ghostTarget() else { return }
        let center = FloorGridGeometry(zoom: zoom, pan: panOffset)
            .cell(at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
        let size = FloorLayout.footprintSize(modelId: tool.modelId, rotation: ghostRotation)
        updateGhost(to: GridPoint(x: center.x - size.width / 2, y: center.y - size.depth / 2), layout: layout)
    }

    /// 確定ボタン（購入して置く／倉庫から置く／移動）
    private func confirmPlacement(layout: FloorLayout) {
        guard let ghost = ghostStatus(layout: layout), ghost.error == nil else {
            message = "ここには置けません"
            return
        }
        switch placement {
        case .purchase(let modelId):
            if store.buyAndPlace(modelId: modelId, origin: ghost.origin, rotation: ghostRotation) {
                let placedTool = store.state.fab.placed.last { $0.origin == ghost.origin && $0.modelId == modelId }
                finishGhost()
                placement = nil
                selectedToolId = placedTool?.id
            } else {
                message = "購入できませんでした（資金と置き場所を確認してください）"
            }
        case .stored(let toolId):
            if store.placeStoredTool(toolId: toolId, origin: ghost.origin, rotation: ghostRotation) {
                finishGhost()
                placement = nil
                selectedToolId = toolId
            } else {
                message = "ここには置けません"
            }
        case nil:
            guard let toolId = movingToolId else { return }
            if store.movePlacedTool(toolId: toolId, origin: ghost.origin, rotation: ghostRotation) {
                finishGhost()
            } else {
                message = "移動できません（置けない場所か、ストッカーが満杯です）"
            }
        }
    }

    private func finishGhost() {
        movingToolId = nil
        ghostOrigin = nil
        ghostRotation = 0
        message = nil
    }

    private func cancelGhost() {
        finishGhost()
        placement = nil
    }

    private func editOverlay(layout: FloorLayout, data: FloorDrawData) -> FloorEditOverlay {
        var overlay = FloorEditOverlay()
        overlay.addableParcels = Self.addableParcels(layout: layout)
        if let ghost = ghostStatus(layout: layout) {
            overlay.ghostOrigin = ghost.origin
            overlay.ghostSize = FloorLayout.footprintSize(modelId: ghost.tool.modelId, rotation: ghostRotation)
            overlay.ghostValid = ghost.error == nil
        }
        overlay.liftedToolId = placement == nil ? movingToolId : nil
        // 配置直後フラッシュ（§3.2）：配置から 1 秒以内だけ対象を渡す
        if let feedback = store.placementFeedback {
            let phase = Date().timeIntervalSince(feedback.at)
            if phase <= 1 {
                overlay.placementFlashToolId = feedback.toolId
                overlay.placementFlashPhase = max(phase, 0)
            }
        }
        if store.railMode {
            switch railTool {
            case .erase:
                overlay.eraseCells = eraseTargets(layout: layout)
            case .draw:
                let preview = railPreview(layout: layout)
                overlay.strokeCells = preview.cells.map { $0.point }
                overlay.blockedCells = preview.blocked
            }
            overlay.portCells = portCandidates(layout: layout, data: data)
        }
        return overlay
    }

    // MARK: 施設帯・売地（位置は layout.parcels から View 側で導出。FloorLayout には何も足さない）

    /// 購入済み区画に辺で接する未購入区画（売地看板の対象）
    static func addableParcels(layout: FloorLayout) -> [ParcelCoord] {
        var result: [ParcelCoord] = []
        for y in 0...FloorLayout.maxParcel {
            for x in 0...FloorLayout.maxParcel {
                let coord = ParcelCoord(x: x, y: y)
                if layout.canAddParcel(coord) {
                    result.append(coord)
                }
            }
        }
        return result
    }

    /// 施設帯の左上セルと幅（区画の外接矩形の北側 3 行。区画を北へ買い足すと帯も北へ逃げる）
    static func facilityBand(layout: FloorLayout) -> (origin: GridPoint, width: Int) {
        let size = FloorLayout.parcelSize
        let xs = layout.parcels.map { $0.x }
        let ys = layout.parcels.map { $0.y }
        let minX = (xs.min() ?? 0) * size
        let maxX = ((xs.max() ?? 0) + 1) * size
        let minY = (ys.min() ?? 0) * size
        return (GridPoint(x: minX, y: minY - facilityBandRows), maxX - minX)
    }

    /// 帯の幅を 3 等分したときの i 番目の列範囲（帯の左端からの相対）
    static func facilitySpan(_ index: Int, width: Int) -> Range<Int> {
        (width * index / 3)..<(width * (index + 1) / 3)
    }

    /// セルが施設帯の建物なら、その種類
    static func facility(at cell: GridPoint, layout: FloorLayout) -> FacilityKind? {
        let band = facilityBand(layout: layout)
        guard (band.origin.y..<band.origin.y + facilityBandRows).contains(cell.y) else { return nil }
        let dx = cell.x - band.origin.x
        for (i, kind) in facilityOrder.enumerated() where facilitySpan(i, width: band.width).contains(dx) {
            return kind
        }
        return nil
    }

    /// 建物の中心セル（ドックの施設ショートカットで MapFocusRequest.point に使う）
    static func facilityCenter(_ kind: FacilityKind, layout: FloorLayout) -> GridPoint {
        let band = facilityBand(layout: layout)
        let index = facilityOrder.firstIndex(of: kind) ?? 0
        let span = facilitySpan(index, width: band.width)
        return GridPoint(x: band.origin.x + (span.lowerBound + span.upperBound) / 2, y: band.origin.y + 1)
    }

    // MARK: カメラ

    /// 初回表示：区画＋北の施設帯＋隣接区画 1 つ分（売地看板）が HUD とドックの間に収まる倍率にして中央に置く
    private func fitIfNeeded(layout: FloorLayout) {
        guard !didFit, canvasSize.width > 0, canvasSize.height > 0 else { return }
        didFit = true
        let size = FloorLayout.parcelSize
        let band = Self.facilityBand(layout: layout)
        var minX = band.origin.x
        var maxX = band.origin.x + band.width
        let minY = band.origin.y
        var maxY = ((layout.parcels.map { $0.y }.max() ?? 0) + 1) * size
        for coord in Self.addableParcels(layout: layout) {
            minX = min(minX, coord.x * size)
            maxX = max(maxX, (coord.x + 1) * size)
            maxY = max(maxY, (coord.y + 1) * size)
        }
        let columns = CGFloat(maxX - minX)
        let rows = CGFloat(maxY - minY)
        let margin = FloorGridGeometry.margin
        let availableWidth = canvasSize.width - margin * 2
        let availableHeight = max(canvasSize.height - Self.hudHeight - Self.dockHeight - margin * 2, 1)
        let base = FloorGridGeometry.baseCellSize
        let fit = min(availableWidth / (columns * base), availableHeight / (rows * base))
        let fitted = min(max(fit, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        ignoreNextZoomChange = fitted != zoom
        zoom = fitted
        let cs = base * zoom
        panOffset = CGSize(
            width: (canvasSize.width - columns * cs) / 2 - margin - CGFloat(minX) * cs,
            height: Self.hudHeight + (availableHeight + margin * 2 - rows * cs) / 2 - margin - CGFloat(minY) * cs
        )
    }

    /// 装置が画面外なら中央へパンする
    private func focus(on toolId: UUID) {
        guard let tool = store.state.fab.placed.first(where: { $0.id == toolId }) else { return }
        let size = FloorLayout.footprintSize(modelId: tool.modelId, rotation: tool.rotation)
        focus(origin: tool.origin, width: size.width, depth: size.depth)
    }

    private func focus(origin: GridPoint, width: Int, depth: Int) {
        guard canvasSize.width > 0 else { return }
        let geometry = FloorGridGeometry(zoom: zoom, pan: panOffset)
        let rect = geometry.rect(origin: origin, width: width, depth: depth)
        let bounds = CGRect(origin: .zero, size: canvasSize)
        guard !bounds.contains(rect) else { return }
        panOffset = CGSize(width: panOffset.width + bounds.midX - rect.midX,
                           height: panOffset.height + bounds.midY - rect.midY)
    }

    /// セルを画面中央に置く（ダブルタップズーム用）
    private func center(on cell: GridPoint) {
        guard canvasSize.width > 0 else { return }
        let cs = FloorGridGeometry.baseCellSize * zoom
        let margin = FloorGridGeometry.margin
        panOffset = CGSize(width: canvasSize.width / 2 - margin - (CGFloat(cell.x) + 0.5) * cs,
                           height: canvasSize.height / 2 - margin - (CGFloat(cell.y) + 0.5) * cs)
    }

    // MARK: 追跡中 FOUP の方向矢印（§4.5）

    /// 8 方位の矢印（東から反時計回り、45° ごと）
    static let directionArrows = ["→", "↗", "↑", "↖", "←", "↙", "↓", "↘"]

    /// 追跡中ロットが見えているセル範囲の外にあるなら、画面中央から見た方向の矢印。
    /// 範囲内・追跡なし・ロットが見つからない（出荷済み・仮想搬送中）・キャンバス未確定なら nil
    private func trackedLotDirection(state: GameState) -> String? {
        guard let lotId = store.trackedLotId, let layout = state.fab.layout,
              canvasSize.width > 0, canvasSize.height > 0,
              let cell = Self.lotAnchorCell(state: state, layout: layout, lotId: lotId) else { return nil }
        let geometry = FloorGridGeometry(zoom: zoom, pan: panOffset)
        let topLeft = geometry.cell(at: .zero)
        let bottomRight = geometry.cell(at: CGPoint(x: canvasSize.width, y: canvasSize.height))
        if (topLeft.x...bottomRight.x).contains(cell.x) && (topLeft.y...bottomRight.y).contains(cell.y) {
            return nil
        }
        let target = geometry.center(cell)
        // 画面座標は y が下向きなので、角度は上向きを正にして求める
        let angle = atan2(-(target.y - canvasSize.height / 2), target.x - canvasSize.width / 2)
        let sector = Int((angle / (.pi / 4)).rounded())
        return Self.directionArrows[(sector % 8 + 8) % 8]
    }

    /// ロットの代表セル：レール上は path[cellIndex]、ポート内は装置の原点、ストッカー／投入口はそのエリアの原点
    static func lotAnchorCell(state: GameState, layout: FloorLayout, lotId: UUID) -> GridPoint? {
        guard let lot = state.fab.sim?.lots.first(where: { $0.id == lotId }) else { return nil }
        switch lot.location {
        case .rail(let cellIndex, _):
            return lot.path.indices.contains(cellIndex) ? lot.path[cellIndex] : nil
        case .port(let toolId, _):
            return state.fab.placed.first(where: { $0.id == toolId })?.origin
        case .stocker:
            return layout.stocker.origin
        case .entry:
            return layout.entry.origin
        case .inTransit:
            // 仮想搬送（layout なしの旧モード）はフロア上に位置を持たない
            return nil
        }
    }

    private func handleFocusRequest(_ request: MapFocusRequest?) {
        guard let request else { return }
        if let toolId = request.toolId {
            selectedToolId = toolId
            focus(on: toolId)
        } else if let point = request.point {
            focus(origin: point, width: 1, depth: 1)
        }
        focusRequest = nil
    }

    /// 「移動」依頼：長押しと同じ持ち上げを始める（対象が無ければ何もせず依頼だけ消す）
    private func handleMoveRequest(_ toolId: UUID?) {
        guard let toolId else { return }
        beginLift(toolId: toolId)
        moveRequest = nil
    }

    // MARK: 浮動ツールバー・レールモードバー

    /// ゴーストの近く（基本は直下、入らなければ直上）に浮動ツールバーを出す
    @ViewBuilder
    private func ghostToolbarLayer(layout: FloorLayout, geometry g: FloorGridGeometry, size: CGSize) -> some View {
        if let ghost = ghostStatus(layout: layout) {
            let footprint = FloorLayout.footprintSize(modelId: ghost.tool.modelId, rotation: ghostRotation)
            let rect = g.rect(origin: ghost.origin, width: footprint.width, depth: footprint.depth)
            let height: CGFloat = (ghost.error == nil && message == nil) ? 52 : 80
            let halfWidth = min(175, size.width / 2)
            let fitsBelow = rect.maxY + 10 + height <= size.height - Self.dockHeight - 8
            let rawY = fitsBelow ? rect.maxY + 10 + height / 2 : rect.minY - 10 - height / 2
            let y = min(max(rawY, Self.hudHeight + height / 2), size.height - height / 2)
            let x = min(max(rect.midX, halfWidth), size.width - halfWidth)
            ghostToolbar(layout: layout, ghost: ghost)
                .frame(maxWidth: halfWidth * 2)
                .position(x: x, y: y)
        }
    }

    private func ghostToolbar(layout: FloorLayout, ghost: GhostStatus) -> some View {
        VStack(spacing: 6) {
            if let error = ghost.error {
                Text(error)
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    ghostRotation = (ghostRotation + 90) % 360
                } label: {
                    Label("回転", systemImage: "rotate.right")
                }
                .buttonStyle(.bordered)
                // 確定はこのボタンだけ（β1 実機FB対応）
                Button {
                    confirmPlacement(layout: layout)
                } label: {
                    Label(confirmTitle, systemImage: "checkmark.circle.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .disabled(ghost.error != nil)
                Button("キャンセル") {
                    cancelGhost()
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var confirmTitle: String {
        switch placement {
        case .purchase(let modelId):
            let price = Catalog.model(id: modelId)?.priceYen ?? 0
            return "ここに置く（\(MoneyFormat.yen(price))）"
        case .stored:
            return "ここに置く"
        case nil:
            return "ここへ移動"
        }
    }

    private func railModeBar(layout: FloorLayout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("道具", selection: $railTool) {
                    Text("敷設").tag(RailTool.draw)
                    Text("消しゴム").tag(RailTool.erase)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 170)
                Spacer(minLength: 0)
                Button {
                    undoLastStroke()
                } label: {
                    Label("元に戻す", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(lastStrokeNewCells.isEmpty)
                Button("完了") {
                    store.railMode = false
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            railStatus(layout: layout)
            if let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func railStatus(layout: FloorLayout) -> some View {
        switch railTool {
        case .draw:
            if railStroke.isEmpty {
                Text("1本指でなぞって敷設（向きはなぞった方向）、タップで向きを回す。2本指でフロアを動かせます。新規 1セル \(MoneyFormat.yen(Engine.railCellCostYen))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let preview = railPreview(layout: layout)
                let cost = Double(preview.newCount) * Engine.railCellCostYen
                Text("新規 \(preview.newCount)セル × \(MoneyFormat.yen(Engine.railCellCostYen)) = \(MoneyFormat.yen(cost))")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(cost > store.state.cashYen ? Color.red : Color.primary)
            }
        case .erase:
            if railStroke.isEmpty {
                Text("なぞったレールを撤去します（購入したレールは全額返金、最初からあるレールは返金なし）。2本指でフロアを動かせます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let targets = eraseTargets(layout: layout)
                let refund = Engine.railRefundYen(state: store.state, points: targets)
                Text("撤去 \(targets.count)セル（+\(MoneyFormat.yen(refund))）")
                    .font(.caption.bold())
                    .monospacedDigit()
            }
        }
    }

    // MARK: 描画

    private func drawFloor(_ context: GraphicsContext, size: CGSize, data: FloorDrawData, overlay: FloorEditOverlay,
                           decor: MapDecor, geometry g: FloorGridGeometry, now: Double, simElapsed: Double,
                           showNumbers: Bool, inventoryChips: Double) {
        let bounds = CGRect(origin: .zero, size: size)
        let cs = g.cellSize
        let layout = data.layout
        let parcelSize = FloorLayout.parcelSize

        // 1. 外側（未購入より暗い）
        context.fill(Path(bounds), with: .color(Color(white: 0.16)))

        // 施設帯の地面（区画の外接矩形の北側 3 行。§1.3・付録B 段1）
        let band = Self.facilityBand(layout: layout)
        let bandRect = g.rect(origin: band.origin, width: band.width, depth: Self.facilityBandRows)
        if bandRect.intersects(bounds) {
            context.fill(Path(roundedRect: bandRect.insetBy(dx: 1, dy: 1), cornerRadius: cs * 0.3),
                         with: .color(Color(red: 0.33, green: 0.40, blue: 0.31)))
            // フロアとの境の縁石
            var curb = Path()
            curb.move(to: CGPoint(x: bandRect.minX + 1, y: bandRect.maxY - 1))
            curb.addLine(to: CGPoint(x: bandRect.maxX - 1, y: bandRect.maxY - 1))
            context.stroke(curb, with: .color(Color(white: 0.75).opacity(0.6)), lineWidth: max(cs * 0.08, 1))
        }

        // 2. 区画
        var gridLines = Path()
        var parcelBorders = Path()
        var cellTints = Path()
        var perfDots = Path()
        for py in 0...FloorLayout.maxParcel {
            for px in 0...FloorLayout.maxParcel {
                let coord = ParcelCoord(x: px, y: py)
                let rect = g.rect(origin: GridPoint(x: px * parcelSize, y: py * parcelSize), width: parcelSize, depth: parcelSize)
                guard rect.intersects(bounds) else { continue }
                if layout.parcels.contains(coord) {
                    context.fill(Path(rect), with: .color(Color(white: 0.95)))
                    // クリーンルーム床（P5環境・第2ゲート）: パネルの市松＋グレーチング孔を手続き描画（アセット0KB）
                    for cy in 0..<parcelSize {
                        for cx in 0..<parcelSize {
                            let cellRect = CGRect(x: rect.minX + CGFloat(cx) * cs, y: rect.minY + CGFloat(cy) * cs,
                                                  width: cs, height: cs)
                            guard cellRect.intersects(bounds) else { continue }
                            if (cx + cy) % 2 == 0 { cellTints.addRect(cellRect) }
                            let d = max(cs * 0.09, 1)
                            perfDots.addEllipse(in: CGRect(x: cellRect.midX - d / 2, y: cellRect.maxY - d - cs * 0.08,
                                                           width: d, height: d))
                        }
                    }
                    for i in 1..<parcelSize {
                        let x = rect.minX + CGFloat(i) * cs
                        gridLines.move(to: CGPoint(x: x, y: rect.minY))
                        gridLines.addLine(to: CGPoint(x: x, y: rect.maxY))
                        let y = rect.minY + CGFloat(i) * cs
                        gridLines.move(to: CGPoint(x: rect.minX, y: y))
                        gridLines.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                    parcelBorders.addRect(rect)
                } else {
                    context.fill(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(Color(white: 0.26)))
                }
            }
        }
        context.fill(cellTints, with: .color(Color(white: 0.90)))
        context.fill(perfDots, with: .color(Color.gray.opacity(0.35)))
        context.stroke(gridLines, with: .color(Color.gray.opacity(0.22)), lineWidth: 0.5)
        context.stroke(parcelBorders, with: .color(Color.gray.opacity(0.5)), lineWidth: 1)
        // 売地看板（隣接する未購入区画に常時。資金が足りれば明るく、足りなければ灰色＋不足額。§2.6）
        for coord in overlay.addableParcels {
            let rect = g.rect(origin: GridPoint(x: coord.x * parcelSize, y: coord.y * parcelSize), width: parcelSize, depth: parcelSize)
            guard rect.intersects(bounds) else { continue }
            drawForSaleSign(context, parcelRect: rect, cost: decor.parcelCostYen, cash: decor.cashYen, cellSize: cs)
        }

        // 3. レール（熱色の地色 → 土台 → 芯線 → 方向シェブロン）
        // 熱色レール（§3.1）凡例：混雑度＝そのセルに連なる待ち列の長さ。
        //   0〜1 = 地色なし／2〜3 = 黄／4〜5 = 橙／6 以上 = 赤（半透明でレールが透けて見える濃さ）
        var heatYellow = Path()
        var heatOrange = Path()
        var heatRed = Path()
        for rail in data.rails {
            guard let level = data.congestion[rail.point], level >= 2 else { continue }
            let rect = g.rect(origin: rail.point, width: 1, depth: 1)
            guard rect.intersects(bounds) else { continue }
            switch level {
            case 2...3: heatYellow.addRect(rect)
            case 4...5: heatOrange.addRect(rect)
            default: heatRed.addRect(rect)
            }
        }
        context.fill(heatYellow, with: .color(Color.yellow.opacity(0.35)))
        context.fill(heatOrange, with: .color(Color.orange.opacity(0.42)))
        context.fill(heatRed, with: .color(Color.red.opacity(0.42)))

        var trackBase = Path()
        var trackCore = Path()
        var chevrons = Path()
        let half = cs / 2
        for rail in data.rails {
            let c = g.center(rail.point)
            guard bounds.insetBy(dx: -cs, dy: -cs).contains(c) else { continue }
            for arm in rail.arms {
                let d = arm.delta
                let end = CGPoint(x: c.x + CGFloat(d.dx) * half, y: c.y + CGFloat(d.dy) * half)
                trackBase.move(to: c)
                trackBase.addLine(to: end)
                trackCore.move(to: c)
                trackCore.addLine(to: end)
            }
            let f = rail.direction.delta
            let fx = CGFloat(f.dx)
            let fy = CGFloat(f.dy)
            let s = cs * 0.2
            chevrons.move(to: CGPoint(x: c.x - fx * s * 0.6 - fy * s, y: c.y - fy * s * 0.6 + fx * s))
            chevrons.addLine(to: CGPoint(x: c.x + fx * s, y: c.y + fy * s))
            chevrons.addLine(to: CGPoint(x: c.x - fx * s * 0.6 + fy * s, y: c.y - fy * s * 0.6 - fx * s))
        }
        context.stroke(trackBase, with: .color(Color(white: 0.78)),
                       style: StrokeStyle(lineWidth: cs * 0.42, lineCap: .round, lineJoin: .round))
        context.stroke(trackCore, with: .color(Color(white: 0.45)),
                       style: StrokeStyle(lineWidth: cs * 0.12, lineCap: .round, lineJoin: .round))
        context.stroke(chevrons, with: .color(Color(white: 0.25)),
                       style: StrokeStyle(lineWidth: max(cs * 0.07, 1), lineCap: .round, lineJoin: .round))

        // 進行方向の流れドット（β1 実機FB対応）：各レールセルに 1 個、出口方向へ流れる光点。
        // 静止シェブロンだけでは向きが伝わらないための補強。1 パスにまとめて 1 回の fill で描くので
        // セル数が増えても描画コールは増えない（0.9 秒周期でセル 1 個分を移動）
        var flowDots = Path()
        let flowPhase = now.truncatingRemainder(dividingBy: 0.9) / 0.9 - 0.5
        let dotR = max(cs * 0.085, 1.2)
        for rail in data.rails {
            let c = g.center(rail.point)
            guard bounds.insetBy(dx: -cs, dy: -cs).contains(c) else { continue }
            let f = rail.direction.delta
            let p = CGPoint(x: c.x + CGFloat(f.dx) * CGFloat(flowPhase) * cs,
                            y: c.y + CGFloat(f.dy) * CGFloat(flowPhase) * cs)
            flowDots.addEllipse(in: CGRect(x: p.x - dotR, y: p.y - dotR, width: dotR * 2, height: dotR * 2))
        }
        context.fill(flowDots, with: .color(Color.cyan.opacity(0.5)))

        // ポート候補の口（レールモード中だけ。「ここへつなぐ」を示す薄い青。§2.5）
        if !overlay.portCells.isEmpty {
            var mouths = Path()
            let m = cs * 0.34
            for point in overlay.portCells {
                let c = g.center(point)
                guard bounds.insetBy(dx: -cs, dy: -cs).contains(c) else { continue }
                mouths.addRoundedRect(in: CGRect(x: c.x - m / 2, y: c.y - m / 2, width: m, height: m),
                                      cornerSize: CGSize(width: m * 0.3, height: m * 0.3))
            }
            context.fill(mouths, with: .color(Color.blue.opacity(0.28)))
            context.stroke(mouths, with: .color(Color.blue.opacity(0.55)), lineWidth: 1)
        }

        // 4. 固定設備（ストッカー・投入口・出荷口）
        let labelSize = max(cs * 0.42, 8)
        let stockerRect = g.rect(origin: layout.stocker.origin, width: FloorLayout.stockerSize.width,
                                 depth: FloorLayout.stockerSize.depth).insetBy(dx: cs * 0.06, dy: cs * 0.06)
        // ストッカー（P5環境・第2ゲート）: ラック棚＋収納FOUPのスロットで見せる（手続き描画）
        context.fill(Path(roundedRect: stockerRect, cornerRadius: cs * 0.2), with: .color(Color(white: 0.30)))
        let rackInner = stockerRect.insetBy(dx: cs * 0.12, dy: cs * 0.12)
        context.fill(Path(roundedRect: rackInner, cornerRadius: cs * 0.1), with: .color(Color(white: 0.45)))
        let rackCols = 3, rackRows = 2
        let slotW = rackInner.width / CGFloat(rackCols), slotH = rackInner.height / CGFloat(rackRows)
        var shelf = Path()
        for r in 1..<rackRows {
            shelf.move(to: CGPoint(x: rackInner.minX, y: rackInner.minY + slotH * CGFloat(r)))
            shelf.addLine(to: CGPoint(x: rackInner.maxX, y: rackInner.minY + slotH * CGFloat(r)))
        }
        for c in 1..<rackCols {
            shelf.move(to: CGPoint(x: rackInner.minX + slotW * CGFloat(c), y: rackInner.minY))
            shelf.addLine(to: CGPoint(x: rackInner.minX + slotW * CGFloat(c), y: rackInner.maxY))
        }
        context.stroke(shelf, with: .color(Color(white: 0.25)), lineWidth: max(cs * 0.05, 1))
        for i in 0..<min(data.stockerLots, rackCols * rackRows) {
            let slot = CGRect(x: rackInner.minX + slotW * CGFloat(i % rackCols),
                              y: rackInner.minY + slotH * CGFloat(i / rackCols),
                              width: slotW, height: slotH).insetBy(dx: slotW * 0.18, dy: slotH * 0.18)
            let slotPath = Path(roundedRect: slot, cornerRadius: slot.height * 0.15)
            context.fill(slotPath, with: .color(Color(red: 0.93, green: 0.86, blue: 0.70)))
            context.stroke(slotPath, with: .color(Color.brown.opacity(0.8)), lineWidth: 1)
        }
        if data.stockerLots == 0 {
            context.draw(Text("ST").font(.system(size: labelSize * 1.2, weight: .heavy)).foregroundColor(.white),
                         at: CGPoint(x: stockerRect.midX, y: stockerRect.midY))
        }
        if data.stockerLots > 0 {
            drawBadge(context, text: "×\(data.stockerLots)", at: CGPoint(x: stockerRect.maxX, y: stockerRect.minY),
                      color: .orange, fontSize: labelSize)
        }
        // 充填メーター（§3.1）：下辺に沿った割合バー。90% 以上で橙、満杯で赤の 1 秒周期点滅
        let stockerFull = data.stockerCapacity > 0 && data.stockerLots >= data.stockerCapacity
        if data.stockerCapacity > 0 {
            let fill = min(CGFloat(data.stockerLots) / CGFloat(data.stockerCapacity), 1)
            let barHeight = max(cs * 0.14, 2.5)
            let track = CGRect(x: stockerRect.minX + cs * 0.12, y: stockerRect.maxY - barHeight - cs * 0.03,
                               width: stockerRect.width - cs * 0.24, height: barHeight)
            context.fill(Path(roundedRect: track, cornerRadius: barHeight / 2), with: .color(Color.black.opacity(0.45)))
            let barColor: Color
            if stockerFull {
                barColor = Color.red.opacity(now.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.35)
            } else if fill >= 0.9 {
                barColor = .orange
            } else {
                barColor = Color(red: 0.35, green: 0.8, blue: 0.45)
            }
            if fill > 0 {
                let bar = CGRect(x: track.minX, y: track.minY, width: track.width * fill, height: track.height)
                context.fill(Path(roundedRect: bar, cornerRadius: barHeight / 2), with: .color(barColor))
            }
        }
        let entryRect = g.rect(origin: layout.entry.origin, width: FloorLayout.entrySize.width,
                               depth: FloorLayout.entrySize.depth).insetBy(dx: cs * 0.06, dy: cs * 0.06)
        // ストッカー満杯の間は投入が止まるので灰色に落とす（§3.1）
        context.fill(Path(roundedRect: entryRect, cornerRadius: cs * 0.15),
                     with: .color(stockerFull ? Color(white: 0.55) : Color.green.opacity(0.75)))
        context.draw(Text("IN").font(.system(size: labelSize, weight: .heavy)).foregroundColor(.white),
                     at: CGPoint(x: entryRect.midX, y: entryRect.midY))
        if data.entryLots > 0 {
            drawBadge(context, text: "×\(data.entryLots)", at: CGPoint(x: entryRect.maxX, y: entryRect.minY),
                      color: .orange, fontSize: labelSize)
        }
        let shippingRect = g.rect(origin: layout.shipping.origin, width: FloorLayout.shippingSize.width,
                                  depth: FloorLayout.shippingSize.depth).insetBy(dx: cs * 0.06, dy: cs * 0.06)
        context.fill(Path(roundedRect: shippingRect, cornerRadius: cs * 0.15), with: .color(Color.blue.opacity(0.7)))
        context.draw(Text("OUT").font(.system(size: labelSize * 0.8, weight: .heavy)).foregroundColor(.white),
                     at: CGPoint(x: shippingRect.midX, y: shippingRect.midY))

        // 投入口・出荷口の大きな明示（β1 実機FB対応）：脈動する枠＋日本語ラベルプレートで
        // 「どこから入ってどこへ出るか」を一目で分かるようにする
        let portPulse = 0.45 + 0.3 * sin(now * 2 * Double.pi / 1.6)
        context.stroke(Path(roundedRect: entryRect.insetBy(dx: -cs * 0.10, dy: -cs * 0.10), cornerRadius: cs * 0.22),
                       with: .color(Color.green.opacity(portPulse)), lineWidth: 2.5)
        context.stroke(Path(roundedRect: shippingRect.insetBy(dx: -cs * 0.10, dy: -cs * 0.10), cornerRadius: cs * 0.22),
                       with: .color(Color.blue.opacity(portPulse)), lineWidth: 2.5)
        let portLabelSize = max(cs * 0.52, 10)
        drawPortLabel(context, text: "投入口 IN", above: entryRect,
                      color: Color.green.opacity(0.92), fontSize: portLabelSize)
        drawPortLabel(context, text: "出荷口 OUT", above: shippingRect,
                      color: Color.blue.opacity(0.92), fontSize: portLabelSize)
        // 投入口の小プレート（§3.1）：満杯なら「投入停止」、ノード切替中は排出の進み具合＋砂時計。
        // 投入口ラベルプレート（上）と重ならないよう、投入口の下辺に掛けて下へ積む
        var entryNoteY = entryRect.maxY - cs * 0.2
        let noteSize = max(cs * 0.36, 8)
        if stockerFull {
            let plate = drawSmallPlate(context, text: "投入停止", topCenter: CGPoint(x: entryRect.midX, y: entryNoteY),
                                       color: Color(white: 0.35), fontSize: noteSize)
            entryNoteY = plate.maxY + cs * 0.06
        }
        if let target = data.nodeSwitchTargetName {
            let plate = drawSmallPlate(context, text: "排出中 → \(target)（残り \(data.nodeSwitchRemainingWIP)）",
                                       topCenter: CGPoint(x: entryRect.midX, y: entryNoteY),
                                       color: Color(red: 0.55, green: 0.35, blue: 0.75), fontSize: noteSize,
                                       leadingInset: noteSize * 1.3)
            drawHourglass(context, center: CGPoint(x: plate.minX + noteSize * 0.75, y: plate.midY), size: noteSize * 1.0)
        }

        // 4.5 施設帯の建物（R1 はアイコンプレート。決定 #15）＋ライブ表示
        if bandRect.intersects(bounds) {
            for (i, kind) in Self.facilityOrder.enumerated() {
                let span = Self.facilitySpan(i, width: band.width)
                let rect = g.rect(origin: GridPoint(x: band.origin.x + span.lowerBound, y: band.origin.y),
                                  width: span.count, depth: Self.facilityBandRows)
                drawFacilityPlate(context, kind: kind, rect: rect, decor: decor, cellSize: cs, now: now)
            }
        }

        // 5. 装置
        var toolRects: [UUID: CGRect] = [:]
        for item in data.tools {
            let tool = item.tool
            let footprint = FloorLayout.footprintSize(modelId: tool.modelId, rotation: tool.rotation)
            let rect = g.rect(origin: tool.origin, width: footprint.width, depth: footprint.depth)
                .insetBy(dx: cs * 0.06, dy: cs * 0.06)
            toolRects[tool.id] = rect
            guard rect.intersects(bounds) else { continue }
            let accent = item.process?.accent ?? Color.gray
            if let sprite = EquipmentSprites.meta(modelId: tool.modelId) {
                // P5 スプライト描画（状態ランプとモデル名ラベルは従来どおり後段で描く）
                drawSpriteTool(context, item: item, rect: rect, sprite: sprite, now: now,
                               zoom: cs / FloorGridGeometry.baseCellSize)
            } else {
                let body = Path(roundedRect: rect, cornerRadius: cs * 0.18)
                context.fill(body, with: .color(Color(white: 0.98)))
                context.fill(body, with: .color(accent.opacity(item.isStandby ? 0.06 : 0.16)))
                context.stroke(body, with: .color(accent.opacity(item.isStandby ? 0.35 : 0.85)), lineWidth: 1.5)

                // グリフ（EquipmentPainter の 100×100 座標系を矩形内の正方形へ）
                if let process = item.process {
                    let side = min(rect.width, rect.height) * 0.8
                    var glyph = context
                    glyph.translateBy(x: rect.midX - side / 2, y: rect.midY - side / 2)
                    glyph.scaleBy(x: side / 100, y: side / 100)
                    glyph.opacity = item.isStandby ? 0.3 : 1
                    EquipmentPainter(context: glyph, accent: accent).draw(modelId: tool.modelId, process: process)
                }
            }
            context.draw(Text(tool.modelId).font(.system(size: max(cs * 0.34, 7), weight: .bold)).foregroundColor(accent),
                         at: CGPoint(x: rect.minX + cs * 0.12, y: rect.minY + cs * 0.06), anchor: .topLeading)

            // 状態ランプ（右上）
            let r = max(cs * 0.14, 3)
            let lamp = Path(ellipseIn: CGRect(x: rect.maxX - r * 2 - cs * 0.1, y: rect.minY + cs * 0.1, width: r * 2, height: r * 2))
            context.fill(lamp, with: .color(item.lamp))
            context.stroke(lamp, with: .color(item.lamp == FloorDrawData.idleLamp ? Color.gray : Color.white), lineWidth: 1)

            // 工程順バッジ（左下。β1 実機FB対応）：番号は常時、工程名はズームが十分なときだけ併記し、
            // 引いた表示では番号だけにして邪魔にならないようにする
            if let step = item.stepRank, let process = item.process {
                let br = max(cs * 0.30, 6)
                let badgeCenter = CGPoint(x: rect.minX + br + cs * 0.05, y: rect.maxY - br - cs * 0.05)
                let badge = Path(ellipseIn: CGRect(x: badgeCenter.x - br, y: badgeCenter.y - br, width: br * 2, height: br * 2))
                context.fill(badge, with: .color(accent))
                context.stroke(badge, with: .color(Color.white), lineWidth: 1.2)
                context.draw(Text("\(step)").font(.system(size: br * 1.02, weight: .heavy)).foregroundColor(.white),
                             at: badgeCenter)
                if cs >= 20 {
                    context.draw(Text(process.shortName).font(.system(size: max(cs * 0.32, 8), weight: .bold))
                                    .foregroundColor(Color(white: 0.22)),
                                 at: CGPoint(x: badgeCenter.x + br + cs * 0.09, y: badgeCenter.y), anchor: .leading)
                }
            }

            // 切断プラグ（§3.1）：未接続の装置の入力側（左辺中央）に 1 秒周期で点滅
            if item.isUnconnected, now.truncatingRemainder(dividingBy: 1) < 0.6 {
                drawUnpluggedPlug(context, at: CGPoint(x: rect.minX, y: rect.midY), size: max(cs * 0.5, 8))
            }
            // 歩留まり異常中は検査装置の上に「！」（§3.4）
            if data.excursionActive, item.process == .inspection {
                drawBadge(context, text: "！", at: CGPoint(x: rect.midX, y: rect.minY - cs * 0.1),
                          color: .red, fontSize: max(cs * 0.45, 9))
            }
        }

        // 6. ボトルネック（赤の脈動枠）・選択枠
        if let id = data.bottleneckToolId, let rect = toolRects[id] {
            let pulse = 0.55 + 0.45 * sin(now * 2 * Double.pi / 1.2)
            context.stroke(Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: cs * 0.22),
                           with: .color(Color.red.opacity(pulse)), lineWidth: 3)
            // 律速看板（§3.1）：上辺中央に赤地の小看板
            drawBadge(context, text: "律速", at: CGPoint(x: rect.midX, y: rect.minY),
                      color: .red, fontSize: max(cs * 0.36, 8))
        }
        // 配置直後フラッシュ（§3.2）：白枠を 0.25 秒周期で 2 回点滅（前半 0.5 秒）
        if let id = overlay.placementFlashToolId, let rect = toolRects[id],
           overlay.placementFlashPhase < 0.5,
           overlay.placementFlashPhase.truncatingRemainder(dividingBy: 0.25) < 0.125 {
            context.stroke(Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: cs * 0.24),
                           with: .color(Color.white), lineWidth: 3)
        }
        if let id = highlightedToolId, let rect = toolRects[id] {
            context.stroke(Path(roundedRect: rect.insetBy(dx: -4, dy: -4), cornerRadius: cs * 0.26),
                           with: .color(Color.cyan), lineWidth: 3)
        }
        // 持ち上げ中の元位置（点線で残す）
        if let id = overlay.liftedToolId, let rect = toolRects[id] {
            context.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: cs * 0.2),
                           with: .color(Color.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }

        // 6.5 寸断矢印（§3.1）：前工程の出口 → 次工程の入口を赤の点線で結び、中点に ✗
        for link in data.lineBreaks {
            let a = g.center(link.from)
            let b = g.center(link.to)
            var dashed = Path()
            dashed.move(to: a)
            dashed.addLine(to: b)
            context.stroke(dashed, with: .color(Color.red.opacity(0.85)),
                           style: StrokeStyle(lineWidth: max(cs * 0.1, 2), lineCap: .round, dash: [cs * 0.3, cs * 0.22]))
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let r = max(cs * 0.3, 6)
            context.fill(Path(ellipseIn: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2)),
                         with: .color(Color.white))
            context.stroke(Path(ellipseIn: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2)),
                           with: .color(Color.red), lineWidth: 1.5)
            context.draw(Text("✗").font(.system(size: r * 1.3, weight: .heavy)).foregroundColor(.red), at: mid)
        }

        // 7. FOUP（レール上 → ポート内。合計 maxDrawnLots まで）
        var budget = Self.maxDrawnLots
        let lotWidth = cs * 0.42
        let lotHeight = cs * 0.34
        let advance = simElapsed * Engine.gameMinutesPerRealSecond / SimCore.railCellGameMin
        for lot in data.railLots {
            guard budget > 0 else { break }
            guard case .rail(let index, let progress) = lot.location, index >= 0, index < lot.path.count else { continue }
            let a = g.center(lot.path[index])
            let b = index + 1 < lot.path.count ? g.center(lot.path[index + 1]) : a
            let stopped = progress >= 0.999
            // 補間は次セルの手前（0.95）まで。停止中は動かさない
            let shown = stopped ? 1 : min(progress + advance, max(progress, 0.95))
            let t = CGFloat(min(max(shown, 0), 1))
            let center = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            guard bounds.insetBy(dx: -cs, dy: -cs).contains(center) else { continue }
            budget -= 1
            drawFOUP(context, center: center, width: lotWidth, height: lotHeight)
            // 品質帯（§3.3）：本体中央に横線
            if let band = data.lotBands[lot.id], band != LotQualityBand.none {
                var stripe = Path()
                stripe.move(to: CGPoint(x: center.x - lotWidth / 2 + 1, y: center.y))
                stripe.addLine(to: CGPoint(x: center.x + lotWidth / 2 - 1, y: center.y))
                context.stroke(stripe, with: .color(band == .red ? Color.red : Color.green),
                               lineWidth: max(lotHeight * 0.22, 1.5))
            }
            // 追跡中の FOUP は黄色い輪郭（§4.5）
            if lot.id == data.trackedLotId {
                let ring = CGRect(x: center.x - lotWidth * 0.85, y: center.y - lotHeight * 0.95,
                                  width: lotWidth * 1.7, height: lotHeight * 1.9)
                context.stroke(Path(ellipseIn: ring), with: .color(Color.yellow), lineWidth: 2)
            }
            if stopped {
                drawHourglass(context, center: CGPoint(x: center.x, y: center.y - cs * 0.42), size: max(cs * 0.36, 7))
            }
        }
        let portSide = cs * 0.24
        for item in data.tools where item.portLots > 0 {
            guard budget > 0, let rect = toolRects[item.tool.id], rect.intersects(bounds) else { continue }
            for k in 0..<item.portLots {
                guard budget > 0 else { break }
                let x = rect.minX + cs * 0.1 + CGFloat(k) * (portSide + 2)
                guard x + portSide <= rect.maxX else { break }
                budget -= 1
                let square = CGRect(x: x, y: rect.maxY - portSide - cs * 0.08, width: portSide, height: portSide)
                drawFOUP(context, center: CGPoint(x: square.midX, y: square.midY), width: portSide, height: portSide)
            }
        }

        // 7.5 123 オーバーレイ（§3.5）：数値ラベル（白文字＋暗い下地）
        if showNumbers {
            let numberSize = max(cs * 0.3, 7)
            for item in data.tools {
                guard let rect = toolRects[item.tool.id], rect.intersects(bounds) else { continue }
                drawNumberLabel(context, text: "\(item.busyPercent)%｜待\(item.waitingLots)",
                                at: CGPoint(x: rect.maxX, y: rect.minY), anchor: .topTrailing, fontSize: numberSize)
            }
            drawNumberLabel(context, text: "\(data.stockerLots)/\(data.stockerCapacity)",
                            at: CGPoint(x: stockerRect.midX, y: stockerRect.midY), anchor: .center, fontSize: numberSize)
            drawNumberLabel(context, text: "WIP \(data.wipCount)/\(data.wipCap)",
                            at: CGPoint(x: entryRect.midX, y: entryRect.midY), anchor: .center, fontSize: numberSize)
            drawNumberLabel(context, text: "在庫 \(Int(inventoryChips))",
                            at: CGPoint(x: shippingRect.midX, y: shippingRect.midY), anchor: .center, fontSize: numberSize)
        }

        // 8. 編集プレビュー
        if let origin = overlay.ghostOrigin {
            let rect = g.rect(origin: origin, width: overlay.ghostSize.width, depth: overlay.ghostSize.depth)
            let color = overlay.ghostValid ? Color.green : Color.red
            let path = Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: cs * 0.18)
            context.fill(path, with: .color(color.opacity(0.35)))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
        }
        for point in overlay.strokeCells {
            let rect = g.rect(origin: point, width: 1, depth: 1).insetBy(dx: 1, dy: 1)
            context.fill(Path(rect), with: .color(Color.blue.opacity(0.3)))
        }
        for point in overlay.blockedCells {
            let rect = g.rect(origin: point, width: 1, depth: 1).insetBy(dx: 1, dy: 1)
            context.fill(Path(rect), with: .color(Color.red.opacity(0.35)))
        }
        for point in overlay.eraseCells {
            let rect = g.rect(origin: point, width: 1, depth: 1).insetBy(dx: 1, dy: 1)
            context.fill(Path(rect), with: .color(Color.red.opacity(0.35)))
            context.stroke(Path(rect), with: .color(Color.red), lineWidth: 1.5)
        }

        // 9. デッドロック ビネット（§3.1）：画面外周の赤い内側ストロークを 1.5 秒周期で脈動
        if data.isDeadlocked {
            let pulse = 0.35 + 0.3 * sin(now * 2 * Double.pi / 1.5)
            for (width, alpha) in [(CGFloat(36), 0.25), (CGFloat(18), 0.5), (CGFloat(6), 0.9)] {
                context.stroke(Path(bounds.insetBy(dx: width / 2, dy: width / 2)),
                               with: .color(Color.red.opacity(pulse * alpha)), lineWidth: width)
            }
        }
    }

    /// FOUP（暫定：ベージュの小矩形）
    /// P5 スプライト描画（design/redesign-1.0.md §5）
    /// 本体はフットプリント矩形に下端アンカーで重ね、上方向にオーバードローする。
    /// 可動部（プラテン）は processing（ランプ緑）のときだけ、正円テクスチャを
    /// 楕円に潰してから回す。輪郭のシルエットは回転不変で、表面の模様だけが回る。
    /// ズーム 0.5 未満では LOD として回転を止める（§5.2）。
    private func drawSpriteTool(_ context: GraphicsContext, item: FloorDrawData.ToolItem, rect: CGRect,
                                sprite: EquipmentSpriteMeta, now: Double, zoom: CGFloat) {
        let front = sprite.orientations.front
        let body = front.body
        let aspect = CGFloat(body.pixelSize.height) / CGFloat(body.pixelSize.width)
        let drawW = rect.width * CGFloat(body.drawScale)
        let drawRect = CGRect(x: rect.midX - drawW / 2, y: rect.maxY - drawW * aspect,
                              width: drawW, height: drawW * aspect)
        var base = context
        base.opacity = item.isStandby ? 0.35 : 1
        base.draw(base.resolve(Image(body.image)), in: drawRect)

        guard zoom >= 0.5, item.lamp == .green, let layer = front.layers.first else { return }
        let anim = layer.animation
        guard anim.type == "rotate", anim.activeWhen == "processing" else { return }
        let r = layer.rectInBody
        let platen = CGRect(x: drawRect.minX + CGFloat(r.x) * drawRect.width,
                            y: drawRect.minY + CGFloat(r.y) * drawRect.height,
                            width: CGFloat(r.width) * drawRect.width,
                            height: CGFloat(r.height) * drawRect.height)
        var spin = context
        spin.translateBy(x: platen.midX, y: platen.midY)
        spin.scaleBy(x: 1, y: CGFloat(anim.squashY))
        spin.rotate(by: .radians(-now * 2 * Double.pi / anim.periodSec))
        let half = platen.width / 2
        spin.draw(spin.resolve(Image(layer.image)),
                  in: CGRect(x: -half, y: -half, width: platen.width, height: platen.width))
    }

    private func drawFOUP(_ context: GraphicsContext, center: CGPoint, width: CGFloat, height: CGFloat) {
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        // 接地影（P5環境・第2ゲート）
        let shadow = CGRect(x: rect.minX + width * 0.06, y: rect.maxY - height * 0.18,
                            width: width * 0.88, height: height * 0.3)
        context.fill(Path(ellipseIn: shadow), with: .color(Color.black.opacity(0.18)))
        let path = Path(roundedRect: rect, cornerRadius: min(width, height) * 0.2)
        context.fill(path, with: .color(Color(red: 0.93, green: 0.86, blue: 0.70)))
        context.stroke(path, with: .color(Color.brown.opacity(0.8)), lineWidth: 1)
        // 蓋の継ぎ目
        var seam = Path()
        seam.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + height * 0.28))
        seam.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + height * 0.28))
        context.stroke(seam, with: .color(Color.brown.opacity(0.5)), lineWidth: 1)
        // 前面の窓帯
        let win = CGRect(x: rect.minX + width * 0.18, y: rect.minY + height * 0.45,
                         width: width * 0.64, height: height * 0.3)
        context.fill(Path(roundedRect: win, cornerRadius: height * 0.06),
                     with: .color(Color(white: 0.35).opacity(0.55)))
        // 上部の取っ手
        let handle = CGRect(x: center.x - width * 0.14, y: rect.minY - height * 0.10,
                            width: width * 0.28, height: height * 0.12)
        context.stroke(Path(roundedRect: handle, cornerRadius: height * 0.05),
                       with: .color(Color.brown.opacity(0.9)), lineWidth: 1)
    }

    /// 投入口／出荷口の大きなラベルプレート（施設の上に、三角のポインタつきで描く。β1 実機FB対応）
    private func drawPortLabel(_ context: GraphicsContext, text: String, above rect: CGRect, color: Color, fontSize: CGFloat) {
        // 幅の見積もり：全角は fontSize 相当、半角（ASCII）は 0.55 倍
        var width: CGFloat = fontSize * 0.9
        for ch in text {
            width += ch.isASCII ? fontSize * 0.55 : fontSize
        }
        let height = fontSize * 1.5
        let plate = CGRect(x: rect.midX - width / 2, y: max(rect.minY - height - 3, 2), width: width, height: height)
        let path = Path(roundedRect: plate, cornerRadius: height / 2)
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(Color.white.opacity(0.85)), lineWidth: 1.2)
        context.draw(Text(text).font(.system(size: fontSize, weight: .heavy)).foregroundColor(.white),
                     at: CGPoint(x: plate.midX, y: plate.midY))
        // 施設へつなぐ小さな三角ポインタ
        var tri = Path()
        tri.move(to: CGPoint(x: rect.midX - fontSize * 0.28, y: plate.maxY))
        tri.addLine(to: CGPoint(x: rect.midX + fontSize * 0.28, y: plate.maxY))
        tri.addLine(to: CGPoint(x: rect.midX, y: min(rect.minY, plate.maxY + fontSize * 0.4)))
        tri.closeSubpath()
        context.fill(tri, with: .color(color))
    }

    /// 右上に重ねる数字バッジ
    private func drawBadge(_ context: GraphicsContext, text: String, at point: CGPoint, color: Color, fontSize: CGFloat) {
        let width = fontSize * (0.7 * CGFloat(text.count) + 0.8)
        let height = fontSize * 1.4
        let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
        context.fill(Path(roundedRect: rect, cornerRadius: height / 2), with: .color(color))
        context.draw(Text(text).font(.system(size: fontSize, weight: .bold)).foregroundColor(.white),
                     at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// 文字列の幅の見積もり（全角は fontSize 相当、半角（ASCII）は 0.55 倍。drawPortLabel と同じ）
    private static func estimatedTextWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        text.reduce(0) { $0 + ($1.isASCII ? fontSize * 0.55 : fontSize) }
    }

    /// 投入口の下に積む小プレート（「投入停止」「排出中 → …」）。描いた矩形を返す
    @discardableResult
    private func drawSmallPlate(_ context: GraphicsContext, text: String, topCenter: CGPoint, color: Color,
                                fontSize: CGFloat, leadingInset: CGFloat = 0) -> CGRect {
        let width = Self.estimatedTextWidth(text, fontSize: fontSize) + fontSize * 0.9 + leadingInset
        let height = fontSize * 1.45
        let plate = CGRect(x: topCenter.x - width / 2, y: topCenter.y, width: width, height: height)
        let path = Path(roundedRect: plate, cornerRadius: height * 0.3)
        context.fill(path, with: .color(color.opacity(0.92)))
        context.stroke(path, with: .color(Color.white.opacity(0.8)), lineWidth: 1)
        context.draw(Text(text).font(.system(size: fontSize, weight: .bold)).foregroundColor(.white),
                     at: CGPoint(x: plate.midX + leadingInset / 2, y: plate.midY))
        return plate
    }

    /// 砂時計のピクセル絵（上下の受け皿＋砂の入った上下のガラス＋くびれ。小さな矩形の組み合わせ）
    private func drawHourglass(_ context: GraphicsContext, center: CGPoint, size: CGFloat) {
        let u = size / 8  // 8×8 ドットの格子
        let ox = center.x - size / 2
        let oy = center.y - size / 2
        func dot(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * u, y: oy + y * u, width: w * u, height: h * u)
        }
        var frame = Path()
        frame.addRect(dot(0, 0, 8, 1))    // 上の受け皿
        frame.addRect(dot(0, 7, 8, 1))    // 下の受け皿
        var glass = Path()
        glass.addRect(dot(1, 1, 6, 1))    // 上のガラス（広 → 狭）
        glass.addRect(dot(2, 2, 4, 1))
        glass.addRect(dot(3, 3, 2, 1))    // くびれ
        glass.addRect(dot(3, 4, 2, 1))
        glass.addRect(dot(2, 5, 4, 1))    // 下のガラス（狭 → 広）
        glass.addRect(dot(1, 6, 6, 1))
        var sand = Path()
        sand.addRect(dot(2, 1, 4, 1))     // 上に残る砂
        sand.addRect(dot(3, 2, 2, 1))
        sand.addRect(dot(3.5, 3, 1, 2))   // くびれを落ちる砂
        sand.addRect(dot(2, 6, 4, 1))     // 下に積もった砂
        context.fill(glass, with: .color(Color(red: 0.85, green: 0.93, blue: 1.0)))
        context.fill(sand, with: .color(Color(red: 0.95, green: 0.72, blue: 0.25)))
        context.fill(frame, with: .color(Color(red: 0.45, green: 0.28, blue: 0.12)))
    }

    /// 切断プラグのピクセル絵（差込口の箱＋2本の刃。tip＝刃先を置く点）。左辺から外へ突き出す
    private func drawUnpluggedPlug(_ context: GraphicsContext, at tip: CGPoint, size: CGFloat) {
        let u = size / 6
        let body = CGRect(x: tip.x - size, y: tip.y - u * 2, width: u * 3.5, height: u * 4)
        var blades = Path()
        blades.addRect(CGRect(x: body.maxX, y: tip.y - u * 1.4, width: u * 2.2, height: u * 0.8))
        blades.addRect(CGRect(x: body.maxX, y: tip.y + u * 0.6, width: u * 2.2, height: u * 0.8))
        var cord = Path()
        cord.addRect(CGRect(x: body.minX - u * 1.5, y: tip.y - u * 0.4, width: u * 1.5, height: u * 0.8))
        context.fill(blades, with: .color(Color(white: 0.75)))
        context.fill(cord, with: .color(Color(white: 0.2)))
        context.fill(Path(body), with: .color(Color.red))
        context.stroke(Path(body), with: .color(Color.white), lineWidth: 1)
    }

    /// 123 オーバーレイの数値ラベル（白文字＋暗い下地）
    private func drawNumberLabel(_ context: GraphicsContext, text: String, at point: CGPoint, anchor: UnitPoint,
                                 fontSize: CGFloat) {
        let width = Self.estimatedTextWidth(text, fontSize: fontSize) + fontSize * 0.6
        let height = fontSize * 1.35
        let rect = CGRect(x: point.x - width * anchor.x, y: point.y - height * anchor.y, width: width, height: height)
        context.fill(Path(roundedRect: rect, cornerRadius: height * 0.25), with: .color(Color.black.opacity(0.68)))
        context.draw(Text(text).font(.system(size: fontSize, weight: .semibold).monospacedDigit()).foregroundColor(.white),
                     at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// 売地看板（板＋支柱＋価格。資金不足なら灰色で不足額も出す）。区画の枠は控えめな点線
    private func drawForSaleSign(_ context: GraphicsContext, parcelRect rect: CGRect, cost: Double, cash: Double,
                                 cellSize cs: CGFloat) {
        let affordable = cash >= cost
        context.stroke(Path(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerRadius: cs * 0.3),
                       with: .color(Color.white.opacity(affordable ? 0.28 : 0.12)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        let w = min(rect.width * 0.72, max(cs * 4.2, 64))
        let h = w * (affordable ? 0.5 : 0.62)
        let board = CGRect(x: rect.midX - w / 2, y: rect.midY - h * 0.75, width: w, height: h)
        var posts = Path()
        for fx: CGFloat in [0.28, 0.72] {
            let x = board.minX + w * fx
            posts.move(to: CGPoint(x: x, y: board.maxY))
            posts.addLine(to: CGPoint(x: x, y: board.maxY + h * 0.45))
        }
        context.stroke(posts, with: .color(Color(white: 0.55)), lineWidth: max(w * 0.035, 1.5))
        let path = Path(roundedRect: board, cornerRadius: h * 0.12)
        context.fill(path, with: .color(affordable ? Color(red: 0.99, green: 0.86, blue: 0.36) : Color(white: 0.6)))
        context.stroke(path, with: .color(affordable ? Color(red: 0.6, green: 0.42, blue: 0.1) : Color(white: 0.4)),
                       lineWidth: max(w * 0.03, 1.2))
        let ink = affordable ? Color(red: 0.35, green: 0.2, blue: 0.0) : Color(white: 0.22)
        if affordable {
            context.draw(Text("売地").font(.system(size: h * 0.34, weight: .heavy)).foregroundColor(ink),
                         at: CGPoint(x: board.midX, y: board.minY + h * 0.36))
            context.draw(Text(MoneyFormat.yen(cost)).font(.system(size: h * 0.22, weight: .bold)).foregroundColor(ink),
                         at: CGPoint(x: board.midX, y: board.minY + h * 0.74))
        } else {
            context.draw(Text("売地").font(.system(size: h * 0.27, weight: .heavy)).foregroundColor(ink),
                         at: CGPoint(x: board.midX, y: board.minY + h * 0.26))
            context.draw(Text(MoneyFormat.yen(cost)).font(.system(size: h * 0.17, weight: .bold)).foregroundColor(ink),
                         at: CGPoint(x: board.midX, y: board.minY + h * 0.55))
            context.draw(Text("あと\(MoneyFormat.yen(cost - cash))").font(.system(size: h * 0.15, weight: .bold))
                            .foregroundColor(Color(red: 0.55, green: 0.1, blue: 0.1)),
                         at: CGPoint(x: board.midX, y: board.minY + h * 0.80))
        }
    }

    private static func facilityStyle(_ kind: FacilityKind) -> (name: String, symbol: String, color: Color) {
        switch kind {
        case .office:
            return ("事務所", "🏢", Color(red: 0.25, green: 0.45, blue: 0.70))
        case .research:
            return ("研究棟", "🔬", Color(red: 0.48, green: 0.36, blue: 0.70))
        case .library:
            return ("資料室", "📚", Color(red: 0.62, green: 0.42, blue: 0.24))
        }
    }

    /// 施設帯の建物 1 棟（角丸の板＋絵文字＋名前）とライブ表示（￥吹き出し・煙・！・未読数）
    private func drawFacilityPlate(_ context: GraphicsContext, kind: FacilityKind, rect: CGRect, decor: MapDecor,
                                   cellSize cs: CGFloat, now: Double) {
        let plate = rect.insetBy(dx: cs * 0.3, dy: cs * 0.3)
        guard plate.width > 0, plate.height > 0 else { return }
        let style = Self.facilityStyle(kind)
        let radius = min(plate.width, plate.height) * 0.18
        context.fill(Path(roundedRect: plate.offsetBy(dx: 0, dy: cs * 0.08), cornerRadius: radius),
                     with: .color(Color.black.opacity(0.25)))
        let path = Path(roundedRect: plate, cornerRadius: radius)
        context.fill(path, with: .color(style.color))
        context.stroke(path, with: .color(Color.white.opacity(0.85)), lineWidth: max(cs * 0.06, 1.2))
        let iconSize = min(plate.height * 0.42, plate.width * 0.32)
        context.draw(Text(style.symbol).font(.system(size: iconSize)),
                     at: CGPoint(x: plate.midX, y: plate.minY + plate.height * 0.36))
        let nameSize = min(max(cs * 0.42, 8), plate.width / CGFloat(style.name.count + 1))
        context.draw(Text(style.name).font(.system(size: nameSize, weight: .heavy)).foregroundColor(.white),
                     at: CGPoint(x: plate.midX, y: plate.minY + plate.height * 0.78))

        let corner = CGPoint(x: plate.maxX - cs * 0.1, y: plate.minY + cs * 0.1)
        let badgeSize = max(cs * 0.4, 8)
        switch kind {
        case .office:
            if decor.subsidyAvailable {
                drawBubble(context, text: "￥", tip: CGPoint(x: plate.maxX - cs * 0.5, y: plate.minY + cs * 0.1),
                           fontSize: max(cs * 0.5, 9))
            }
        case .research:
            if decor.researchActive {
                // 煙突と、上へ流れて薄れる煙（周期 2.4 秒）
                let chimney = CGRect(x: plate.minX + plate.width * 0.18, y: plate.minY - cs * 0.3,
                                     width: cs * 0.28, height: cs * 0.36)
                context.fill(Path(chimney), with: .color(Color(white: 0.35)))
                for k in 0..<3 {
                    let phase = (now / 2.4 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let p = CGFloat(phase)
                    let r = cs * (0.12 + 0.16 * p)
                    let center = CGPoint(x: chimney.midX + CGFloat(sin(phase * 2 * Double.pi)) * cs * 0.15,
                                         y: chimney.minY - r - p * cs * 1.1)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                                 with: .color(Color(white: 0.8).opacity(0.6 * (1 - phase))))
                }
            }
            if decor.researchUnseen {
                drawBadge(context, text: "！", at: corner, color: .red, fontSize: badgeSize)
            }
        case .library:
            if decor.unreadGlossary > 0 {
                drawBadge(context, text: "\(decor.unreadGlossary)", at: corner, color: .orange, fontSize: badgeSize)
            }
        }
    }

    /// 吹き出し（tip が尾の先）
    private func drawBubble(_ context: GraphicsContext, text: String, tip: CGPoint, fontSize: CGFloat) {
        let w = fontSize * 1.8
        let h = fontSize * 1.5
        let tail = fontSize * 0.45
        let rect = CGRect(x: tip.x - w / 2, y: tip.y - tail - h, width: w, height: h)
        var bubble = Path(roundedRect: rect, cornerRadius: h * 0.35)
        bubble.move(to: CGPoint(x: tip.x - fontSize * 0.25, y: rect.maxY - 0.5))
        bubble.addLine(to: tip)
        bubble.addLine(to: CGPoint(x: tip.x + fontSize * 0.2, y: rect.maxY - 0.5))
        bubble.closeSubpath()
        context.fill(bubble, with: .color(Color.white))
        context.stroke(Path(roundedRect: rect, cornerRadius: h * 0.35), with: .color(Color.green), lineWidth: 1.5)
        context.draw(Text(text).font(.system(size: fontSize, weight: .heavy)).foregroundColor(Color(red: 0.1, green: 0.55, blue: 0.2)),
                     at: CGPoint(x: rect.midX, y: rect.midY))
    }
}

// MARK: - レールモードの2本指パン

/// SwiftUI には2本指ドラッグが無いので、UIKit の 2 本指 UIPanGestureRecognizer をウィンドウに付けて拾う。
/// 認識器は自分（キャンバスの背景に敷いた透明ビュー）の範囲内のタッチだけを受け取り、
/// タッチは奪わない（cancelsTouchesInView = false）ので SwiftUI 側のピンチ・ドラッグと共存する
private struct TwoFingerPanCatcher: UIViewRepresentable {
    var isEnabled: Bool
    /// 2本指が動き始めてからの移動量
    var onChanged: (CGSize) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        context.coordinator.parent = self
        context.coordinator.recognizer.isEnabled = isEnabled
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer.isEnabled = isEnabled
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.recognizer.view?.removeGestureRecognizer(coordinator.recognizer)
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator else { return }
            coordinator.anchor = self
            let recognizer = coordinator.recognizer
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TwoFingerPanCatcher?
        weak var anchor: UIView?

        lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.minimumNumberOfTouches = 2
            recognizer.maximumNumberOfTouches = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        @objc func handle(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let t = recognizer.translation(in: recognizer.view)
                parent?.onChanged(CGSize(width: t.x, height: t.y))
            case .ended, .cancelled, .failed:
                parent?.onEnded()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let anchor else { return false }
            return anchor.bounds.contains(touch.location(in: anchor))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
