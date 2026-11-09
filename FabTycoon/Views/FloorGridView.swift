import SwiftUI
import UIKit  // P5 スプライトの存在確認（UIImage）とメタデータ（NSDataAsset）用

// MARK: - 1.0 フロア（グリッド描画＋配置編集）
// 設計書 design/redesign-1.0.md §2・§3・§6。絵は暫定ベクタ（P5 で差し替え前提）。
// 描画は Canvas 1枚に集約し、データは state.fab.layout / placed / sim から FloorDrawData に詰めて渡す。
// 編集モード中もシミュレーションは止めない。

/// フロアの編集モード
enum FloorEditMode: Hashable {
    case none
    case tools
    case rails
    case parcels
}

/// レール編集の道具
enum FloorRailTool: Hashable {
    case draw
    case erase
    case pan
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
    }

    let layout: FloorLayout
    let rails: [RailItem]
    let tools: [ToolItem]
    let railLots: [Lot]
    let stockerLots: Int
    let entryLots: Int
    let gameMin: Double
    let bottleneckToolId: UUID?

    static let idleLamp = Color.white

    init(state: GameState, layout: FloorLayout, problems: [LayoutProblem]) {
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
        let causeToolId = state.activeExcursion?.causeToolId
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
                                  stepRank: model.flatMap { stepRanks[$0.process] }))
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
    }
}

/// 編集中のプレビュー（ゴースト・なぞったレール・追加可能な区画）
struct FloorEditOverlay {
    var ghostOrigin: GridPoint?
    var ghostSize: (width: Int, depth: Int) = (0, 0)
    var ghostValid = false
    var strokeCells: [GridPoint] = []
    var blockedCells: [GridPoint] = []
    var eraseCells: [GridPoint] = []
    var addableParcels: [ParcelCoord] = []
}

struct FloorGridView: View {
    @EnvironmentObject private var store: GameStore
    /// 詳細カードの対象（閲覧時に装置・出荷口をタップすると切り替える）
    @Binding var selection: FloorSelection
    /// 選択中の装置（問題リストからのハイライトと共通）
    @Binding var highlightedToolId: UUID?

    @State private var zoom: CGFloat = 1
    @State private var zoomAtGestureStart: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var panAtDragStart: CGSize?
    @State private var canvasSize: CGSize = .zero
    @State private var didFit = false
    @State private var simClock = FloorSimClock()

    @State private var editMode: FloorEditMode = .none
    @State private var editMessage: String?
    // 装置
    @State private var paletteToolId: UUID?
    @State private var isMoving = false
    @State private var ghostOrigin: GridPoint?
    @State private var ghostRotation = 0
    @State private var pendingSell: EquipmentInstance?
    // レール
    @State private var railTool: FloorRailTool = .draw
    @State private var railStroke: [GridPoint] = []
    // 区画
    @State private var pendingParcel: ParcelCoord?

    static let floorHeight: CGFloat = 360
    static let zoomRange: ClosedRange<CGFloat> = 0.5...2.0
    /// 同時に描く FOUP の上限
    static let maxDrawnLots = 80

    init(selection: Binding<FloorSelection>, highlightedToolId: Binding<UUID?>) {
        _selection = selection
        _highlightedToolId = highlightedToolId
    }

    var body: some View {
        let state = store.state
        VStack(alignment: .leading, spacing: 8) {
            modeBar
            if let layout = state.fab.layout {
                let data = FloorDrawData(state: state, layout: layout, problems: store.layoutProblems)
                floorCanvas(layout: layout, data: data)
                    .frame(height: Self.floorHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(editMode == .none ? Color.gray.opacity(0.3) : Color.accentColor, lineWidth: editMode == .none ? 1 : 2)
                    )
                bottomBar(layout: layout)
            } else {
                Text("フロアのデータがありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .onChange(of: editMode) { _, _ in
            resetEditing()
        }
        .onChange(of: highlightedToolId) { _, newId in
            if let newId {
                focus(on: newId)
            }
        }
        .confirmationDialog(
            "装置を売却しますか？",
            isPresented: Binding(
                get: { pendingSell != nil },
                set: { if !$0 { pendingSell = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingSell
        ) { instance in
            Button("売却する（+\(MoneyFormat.yen(Engine.sellRefundYen(instance: instance)))）", role: .destructive) {
                store.sellEquipment(instance.id)
                if highlightedToolId == instance.id {
                    highlightedToolId = nil
                }
                pendingSell = nil
            }
            Button("キャンセル", role: .cancel) {
                pendingSell = nil
            }
        } message: { _ in
            Text("返金はモデル価格の50%です（改良投資分は戻りません）。ポートにいたロットはストッカーへ運ばれます。")
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
                    editMessage = "区画を購入できませんでした（資金不足）"
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

    // MARK: 切替バー

    private var modeBar: some View {
        HStack(spacing: 8) {
            if editMode == .none {
                Label("フロア", systemImage: "square.grid.3x3")
                    .font(.headline)
                Spacer()
                Button {
                    editMode = .tools
                } label: {
                    Label("編集", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
            } else {
                Picker("編集", selection: $editMode) {
                    Text("装置").tag(FloorEditMode.tools)
                    Text("レール").tag(FloorEditMode.rails)
                    Text("区画").tag(FloorEditMode.parcels)
                }
                .pickerStyle(.segmented)
                Button("完了") {
                    editMode = .none
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: キャンバス

    private func floorCanvas(layout: FloorLayout, data: FloorDrawData) -> some View {
        let geometry = FloorGridGeometry(zoom: zoom, pan: panOffset)
        let overlay = editOverlay(layout: layout)
        let clock = simClock
        let paused = data.railLots.isEmpty && data.bottleneckToolId == nil
        return GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let elapsed = clock.elapsed(gameMin: data.gameMin, now: now)
                    drawFloor(context, size: size, data: data, overlay: overlay, geometry: geometry,
                              now: now, simElapsed: elapsed)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(geometry.cell(at: location), layout: layout)
            }
            .gesture(dragGesture(geometry: geometry, layout: layout))
            .simultaneousGesture(magnifyGesture)
            .onAppear {
                canvasSize = geo.size
                fitIfNeeded(layout: layout)
            }
            .onChange(of: geo.size) { _, newSize in
                canvasSize = newSize
            }
        }
    }

    // MARK: ジェスチャ

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
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

    /// レール編集（敷設・消しゴム）ではセル列をなぞり、装置配置中はゴーストをドラッグで動かし、それ以外はパン。
    /// 配置中のドラッグは確定しない（確定は「ここに置く」ボタンに分離。β1 実機FB対応）
    private func dragGesture(geometry: FloorGridGeometry, layout: FloorLayout) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if editMode == .tools && (paletteToolId != nil || isMoving) {
                    updateGhost(to: geometry.cell(at: value.location), layout: layout)
                } else if editMode == .rails && railTool != .pan {
                    if railStroke.isEmpty {
                        extendStroke(to: geometry.cell(at: value.startLocation))
                    }
                    extendStroke(to: geometry.cell(at: value.location))
                } else {
                    let start = panAtDragStart ?? panOffset
                    if panAtDragStart == nil {
                        panAtDragStart = panOffset
                    }
                    panOffset = CGSize(width: start.width + value.translation.width,
                                       height: start.height + value.translation.height)
                }
            }
            .onEnded { _ in
                if editMode == .rails && railTool != .pan {
                    commitStroke(layout: layout)
                }
                panAtDragStart = nil
            }
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

    private func handleTap(_ cell: GridPoint, layout: FloorLayout) {
        editMessage = nil
        let placed = store.state.fab.placed
        let hitTool = placed.first { layout.cells(of: $0).contains(cell) }
        switch editMode {
        case .none:
            if let hitTool {
                highlightedToolId = hitTool.id
                if let process = Catalog.model(id: hitTool.modelId)?.process {
                    selection = .process(process)
                }
            } else if layout.shippingCells().contains(cell) {
                highlightedToolId = nil
                selection = .shipping
            } else {
                highlightedToolId = nil
            }
        case .tools:
            if paletteToolId != nil || isMoving {
                // 配置中：タップはゴーストの移動だけ。確定は「ここに置く」ボタン（再タップ確定は廃止）
                updateGhost(to: cell, layout: layout)
            } else {
                highlightedToolId = hitTool?.id
            }
        case .rails:
            switch railTool {
            case .erase:
                if layout.railIndex[cell] != nil && !store.removeRail(at: cell) {
                    editMessage = "撤去できません（ストッカーが満杯です）"
                }
            case .draw:
                // 1セルのタップ：既存レールは向きを時計回りに回す（無償）、空きなら東向きで敷く
                if var existing = layout.railIndex[cell] {
                    existing.direction = existing.direction.rotatedCW
                    store.setRail(cell: existing)
                } else if layout.railPlacementError(at: cell, among: store.state.fab.placed) == nil {
                    if !store.setRail(cell: RailCell(point: cell, direction: .east, kind: .straight)) {
                        editMessage = "資金が不足しています"
                    }
                }
            case .pan:
                break
            }
        case .parcels:
            let coord = layout.parcel(of: cell)
            if layout.canAddParcel(coord) {
                pendingParcel = coord
            }
        }
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
            var failed = 0
            for point in eraseTargets(layout: layout) {
                if !store.removeRail(at: point) {
                    failed += 1
                }
            }
            if failed > 0 {
                editMessage = "\(failed)セルは撤去できませんでした（ストッカーが満杯です）"
            }
            return
        }
        let preview = railPreview(layout: layout)
        var failed = 0
        for cell in preview.cells {
            if !store.setRail(cell: cell) {
                failed += 1
            }
        }
        if failed > 0 {
            editMessage = "資金不足で\(failed)セル敷けませんでした"
        } else if !preview.blocked.isEmpty {
            editMessage = "装置・固定設備・未購入区画の\(preview.blocked.count)セルには敷けません"
        }
    }

    // MARK: 編集状態

    private func resetEditing() {
        paletteToolId = nil
        isMoving = false
        ghostOrigin = nil
        ghostRotation = 0
        railStroke = []
        editMessage = nil
    }

    /// ゴーストの対象装置（パレット選択中／移動中。どちらでもなければ nil）
    private func ghostTarget() -> ToolInstance? {
        let fab = store.state.fab
        if let paletteId = paletteToolId, let instance = fab.storedEquipment.first(where: { $0.id == paletteId }) {
            return ToolInstance(instance: instance)
        }
        if isMoving, let toolId = highlightedToolId {
            return fab.placed.first(where: { $0.id == toolId })
        }
        return nil
    }

    /// ゴーストの対象装置と配置エラー（ゴーストが無ければ nil）
    private func ghostStatus(layout: FloorLayout) -> (tool: ToolInstance, origin: GridPoint, error: String?)? {
        guard let origin = ghostOrigin, let tool = ghostTarget() else { return nil }
        let error = layout.toolPlacementError(tool, origin: origin, rotation: ghostRotation, among: store.state.fab.placed)
        return (tool, origin, error)
    }

    /// タップ／ドラッグでゴーストを動かす。近傍に置けるセルがあればスナップし、
    /// 無ければ指の位置そのまま（赤ゴーストで「置けない」ことが分かる）
    private func updateGhost(to raw: GridPoint, layout: FloorLayout) {
        guard let tool = ghostTarget() else { return }
        editMessage = nil
        ghostOrigin = layout.snappedOrigin(for: tool, near: raw, rotation: ghostRotation,
                                           among: store.state.fab.placed) ?? raw
    }

    /// 「ここに置く」ボタンからの確定（配置／移動の共通処理）
    private func confirmPlacement(layout: FloorLayout) {
        guard let ghost = ghostStatus(layout: layout), ghost.error == nil else {
            editMessage = "ここには置けません"
            return
        }
        if let paletteId = paletteToolId {
            if store.placeStoredTool(toolId: paletteId, origin: ghost.origin, rotation: ghostRotation) {
                paletteToolId = nil
                ghostOrigin = nil
                highlightedToolId = paletteId
            } else {
                editMessage = "ここには置けません"
            }
        } else if isMoving, let toolId = highlightedToolId {
            if store.movePlacedTool(toolId: toolId, origin: ghost.origin, rotation: ghostRotation) {
                isMoving = false
                ghostOrigin = nil
            } else {
                editMessage = "移動できません（置けない場所か、ストッカーが満杯です）"
            }
        }
    }

    private func editOverlay(layout: FloorLayout) -> FloorEditOverlay {
        var overlay = FloorEditOverlay()
        switch editMode {
        case .tools:
            if let ghost = ghostStatus(layout: layout) {
                overlay.ghostOrigin = ghost.origin
                overlay.ghostSize = FloorLayout.footprintSize(modelId: ghost.tool.modelId, rotation: ghostRotation)
                overlay.ghostValid = ghost.error == nil
            }
        case .rails:
            if railTool == .erase {
                overlay.eraseCells = eraseTargets(layout: layout)
            } else if railTool == .draw {
                let preview = railPreview(layout: layout)
                overlay.strokeCells = preview.cells.map { $0.point }
                overlay.blockedCells = preview.blocked
            }
        case .parcels:
            for y in 0...FloorLayout.maxParcel {
                for x in 0...FloorLayout.maxParcel {
                    let coord = ParcelCoord(x: x, y: y)
                    if layout.canAddParcel(coord) {
                        overlay.addableParcels.append(coord)
                    }
                }
            }
        case .none:
            break
        }
        return overlay
    }

    /// 初回表示でフロア全体が横幅に収まる倍率にする
    private func fitIfNeeded(layout: FloorLayout) {
        guard !didFit, canvasSize.width > 0 else { return }
        didFit = true
        let columns = ((layout.parcels.map { $0.x }.max() ?? 0) + 1) * FloorLayout.parcelSize
        let available = canvasSize.width - FloorGridGeometry.margin * 2
        let fit = available / (CGFloat(columns) * FloorGridGeometry.baseCellSize)
        zoom = min(max(fit, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// 装置が画面外なら中央へパンする
    private func focus(on toolId: UUID) {
        guard canvasSize.width > 0, let tool = store.state.fab.placed.first(where: { $0.id == toolId }) else { return }
        let geometry = FloorGridGeometry(zoom: zoom, pan: panOffset)
        let size = FloorLayout.footprintSize(modelId: tool.modelId, rotation: tool.rotation)
        let rect = geometry.rect(origin: tool.origin, width: size.width, depth: size.depth)
        let bounds = CGRect(origin: .zero, size: canvasSize)
        guard !bounds.contains(rect) else { return }
        panOffset = CGSize(width: panOffset.width + bounds.midX - rect.midX,
                           height: panOffset.height + bounds.midY - rect.midY)
    }

    // MARK: 下部バー

    @ViewBuilder
    private func bottomBar(layout: FloorLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch editMode {
            case .none:
                Text("ピンチで拡大・ドラッグで移動。装置をタップすると下に詳細が出ます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .tools:
                toolsBar(layout: layout)
            case .rails:
                railsBar(layout: layout)
            case .parcels:
                Text("緑の区画をタップすると購入できます（\(MoneyFormat.yen(Engine.expansionCostYen(state: store.state)))）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let editMessage {
                Label(editMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func toolsBar(layout: FloorLayout) -> some View {
        let fab = store.state.fab
        if paletteToolId != nil || isMoving {
            let ghost = ghostStatus(layout: layout)
            VStack(alignment: .leading, spacing: 6) {
                // 状態テキスト：ゴースト未表示／置けない理由／置ける
                if let ghost {
                    if let error = ghost.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("置ける場所です。ドラッグで微調整できます")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } else {
                    Text(isMoving ? "移動先をドラッグ／タップで選んでください" : "置きたい場所をドラッグ／タップで選んでください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    // 確定はこのボタンだけ（再タップ確定は廃止。β1 実機FB対応）
                    Button {
                        confirmPlacement(layout: layout)
                    } label: {
                        Label(isMoving ? "ここへ移動" : "ここに置く", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ghost == nil || ghost?.error != nil)
                    Button {
                        ghostRotation = (ghostRotation + 90) % 360
                    } label: {
                        Label("回転", systemImage: "rotate.right")
                    }
                    .buttonStyle(.bordered)
                    Button("キャンセル") {
                        paletteToolId = nil
                        isMoving = false
                        ghostOrigin = nil
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        } else if let toolId = highlightedToolId, let tool = fab.placed.first(where: { $0.id == toolId }) {
            let name = Catalog.model(id: tool.modelId)?.name ?? tool.modelId
            VStack(alignment: .leading, spacing: 6) {
                Text("\(tool.modelId) \(name)（Lv\(tool.level)）")
                    .font(.subheadline.bold())
                HStack(spacing: 8) {
                    Button("移動") {
                        isMoving = true
                        ghostRotation = tool.rotation
                        // 現在位置からゴーストを出す（ドラッグでそのまま動かせる）
                        ghostOrigin = tool.origin
                    }
                    Button("回転") {
                        if !store.rotatePlacedTool(toolId: tool.id) {
                            editMessage = "回転できません（重なるか、ストッカーが満杯です）"
                        }
                    }
                    Button("倉庫へ") {
                        if store.removePlacedToolToStorage(toolId: tool.id) {
                            highlightedToolId = nil
                        } else {
                            editMessage = "外せません（ストッカーが満杯です）"
                        }
                    }
                    Button("売却", role: .destructive) {
                        pendingSell = Engine.equipmentInstance(tool)
                    }
                }
                .buttonStyle(.bordered)
            }
        } else {
            Text("装置をタップで選択。倉庫の装置を選んでフロアに置けます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        palette
    }

    /// 倉庫の装置パレット
    @ViewBuilder
    private var palette: some View {
        let stored = store.state.fab.storedEquipment
        if stored.isEmpty {
            Text("倉庫に装置はありません")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stored) { instance in
                        let model = Catalog.model(id: instance.modelId)
                        let isSelected = paletteToolId == instance.id
                        Button {
                            paletteToolId = isSelected ? nil : instance.id
                            highlightedToolId = nil
                            isMoving = false
                            ghostOrigin = nil
                            ghostRotation = 0
                            editMessage = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(instance.modelId)
                                    .font(.caption.bold())
                                Text(model?.name ?? instance.modelId)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? (model?.process.accent ?? Color.accentColor) : Color(.tertiarySystemFill))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func railsBar(layout: FloorLayout) -> some View {
        Picker("道具", selection: $railTool) {
            Text("敷設").tag(FloorRailTool.draw)
            Text("消しゴム").tag(FloorRailTool.erase)
            Text("移動").tag(FloorRailTool.pan)
        }
        .pickerStyle(.segmented)
        switch railTool {
        case .draw:
            if railStroke.isEmpty {
                Text("ドラッグでレールを引きます（向きはなぞった方向）。1セルのタップで向きを回せます。新規 1セル \(MoneyFormat.yen(Engine.railCellCostYen))、引き直しは無料")
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
                Text("ドラッグでなぞったレールを撤去します（購入したレールは全額返金、最初からあるレールは返金なし）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let targets = eraseTargets(layout: layout)
                let refund = Engine.railRefundYen(state: store.state, points: targets)
                Text("撤去 \(targets.count)セル（+\(MoneyFormat.yen(refund))）")
                    .font(.caption.bold())
                    .monospacedDigit()
            }
        case .pan:
            Text("ドラッグでフロアを動かします")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 描画

    private func drawFloor(_ context: GraphicsContext, size: CGSize, data: FloorDrawData, overlay: FloorEditOverlay,
                           geometry g: FloorGridGeometry, now: Double, simElapsed: Double) {
        let bounds = CGRect(origin: .zero, size: size)
        let cs = g.cellSize
        let layout = data.layout
        let parcelSize = FloorLayout.parcelSize

        // 1. 外側（未購入より暗い）
        context.fill(Path(bounds), with: .color(Color(white: 0.16)))

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
        for coord in overlay.addableParcels {
            let rect = g.rect(origin: GridPoint(x: coord.x * parcelSize, y: coord.y * parcelSize), width: parcelSize, depth: parcelSize)
                .insetBy(dx: 2, dy: 2)
            let path = Path(roundedRect: rect, cornerRadius: 6)
            context.fill(path, with: .color(Color.green.opacity(0.3)))
            context.stroke(path, with: .color(Color.green), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            context.draw(Text("＋").font(.system(size: max(cs * 1.2, 14), weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: rect.midX, y: rect.midY))
        }

        // 3. レール（土台 → 芯線 → 方向シェブロン）
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
        let entryRect = g.rect(origin: layout.entry.origin, width: FloorLayout.entrySize.width,
                               depth: FloorLayout.entrySize.depth).insetBy(dx: cs * 0.06, dy: cs * 0.06)
        context.fill(Path(roundedRect: entryRect, cornerRadius: cs * 0.15), with: .color(Color.green.opacity(0.75)))
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
        }

        // 6. ボトルネック（赤の脈動枠）・選択枠
        if let id = data.bottleneckToolId, let rect = toolRects[id] {
            let pulse = 0.55 + 0.45 * sin(now * 2 * Double.pi / 1.2)
            context.stroke(Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: cs * 0.22),
                           with: .color(Color.red.opacity(pulse)), lineWidth: 3)
        }
        if let id = highlightedToolId, let rect = toolRects[id] {
            context.stroke(Path(roundedRect: rect.insetBy(dx: -4, dy: -4), cornerRadius: cs * 0.26),
                           with: .color(Color.cyan), lineWidth: 3)
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
            if stopped {
                context.draw(Text("⏳").font(.system(size: max(cs * 0.36, 7))),
                             at: CGPoint(x: center.x, y: center.y - cs * 0.42))
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
}
