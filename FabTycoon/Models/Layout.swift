import Foundation

// MARK: - 1.0 レイアウトグラフ（グリッド・配置・レール・接続解析）
// 設計書 design/redesign-1.0.md §1.5〜§1.7・§2。P2 では GameState には組み込まず、
// FloorLayout と ToolInstance の配列を値として扱う（セーブ移行は P3、UI は P4）。
// 座標は x が右、y が下に増える。区画は 8×8 セル、最大 6×6 区画。

// MARK: - 方向

extension RailDirection {
    /// 決定的な反復順（north, east, south, west）
    static let ordered: [RailDirection] = [.north, .east, .south, .west]

    var opposite: RailDirection {
        switch self {
        case .north: return .south
        case .east: return .west
        case .south: return .north
        case .west: return .east
        }
    }

    var rotatedCW: RailDirection {
        switch self {
        case .north: return .east
        case .east: return .south
        case .south: return .west
        case .west: return .north
        }
    }

    var rotatedCCW: RailDirection {
        switch self {
        case .north: return .west
        case .east: return .north
        case .south: return .east
        case .west: return .south
        }
    }

    var delta: (dx: Int, dy: Int) {
        switch self {
        case .north: return (0, -1)
        case .east: return (1, 0)
        case .south: return (0, 1)
        case .west: return (-1, 0)
        }
    }

    var isVertical: Bool { self == .north || self == .south }

    /// 隣接セル a → b の移動方向（隣接していなければ nil）
    static func between(_ a: GridPoint, _ b: GridPoint) -> RailDirection? {
        for d in ordered where a.moved(d) == b {
            return d
        }
        return nil
    }
}

extension GridPoint {
    func moved(_ direction: RailDirection) -> GridPoint {
        let d = direction.delta
        return GridPoint(x: x + d.dx, y: y + d.dy)
    }
}

// MARK: - 区画・フロア

struct ParcelCoord: Codable, Equatable, Hashable {
    var x: Int
    var y: Int
}

struct FloorLayout: Codable, Equatable {
    /// 1区画の一辺（セル）
    static let parcelSize = 8
    /// 区画座標の最大値（0...5 → 6×6 区画 = 48×48 セル）
    static let maxParcel = 5
    /// 初期フロア 2×2 区画 = 16×16 セル
    static var initialParcels: Set<ParcelCoord> {
        [ParcelCoord(x: 0, y: 0), ParcelCoord(x: 1, y: 0), ParcelCoord(x: 0, y: 1), ParcelCoord(x: 1, y: 1)]
    }
    /// 固定設備のフットプリント（幅×奥行）
    static let stockerSize: (width: Int, depth: Int) = (2, 2)
    static let entrySize: (width: Int, depth: Int) = (1, 2)
    static let shippingSize: (width: Int, depth: Int) = (1, 2)

    var parcels: Set<ParcelCoord>
    var rails: [RailCell]
    var stocker: Stocker
    var entry: EntryPort
    var shipping: ShippingPort
    /// 敷設費を支払ったレールセル（P6先行分）。撤去時の返金はこの集合に入っているセルだけが対象で、
    /// テンプレート等の無償分は返金 0（無償レールの売却益の抜け穴対策）。
    /// 旧セーブ（このキーを持たない β1 セーブ）では、テンプレート位置と一致しないレールを購入済みとみなす
    var paidRailPoints: Set<GridPoint> = []

    enum CodingKeys: String, CodingKey {
        case parcels
        case rails
        case stocker
        case entry
        case shipping
        case paidRailPoints
    }

    // MARK: 区画

    /// セルが属する区画（負の座標も床関数で割る）
    func parcel(of cell: GridPoint) -> ParcelCoord {
        let size = Self.parcelSize
        func floorDiv(_ v: Int) -> Int { v >= 0 ? v / size : -((-v + size - 1) / size) }
        return ParcelCoord(x: floorDiv(cell.x), y: floorDiv(cell.y))
    }

    func isPurchased(cell: GridPoint) -> Bool {
        parcels.contains(parcel(of: cell))
    }

    /// 範囲内・未購入・既存区画と辺で接する区画だけ追加できる（§2.5）
    func canAddParcel(_ coord: ParcelCoord) -> Bool {
        guard (0...Self.maxParcel).contains(coord.x), (0...Self.maxParcel).contains(coord.y),
              !parcels.contains(coord) else { return false }
        let neighbors = [
            ParcelCoord(x: coord.x - 1, y: coord.y), ParcelCoord(x: coord.x + 1, y: coord.y),
            ParcelCoord(x: coord.x, y: coord.y - 1), ParcelCoord(x: coord.x, y: coord.y + 1),
        ]
        return neighbors.contains { parcels.contains($0) }
    }

    @discardableResult
    mutating func addParcel(_ coord: ParcelCoord) -> Bool {
        guard canAddParcel(coord) else { return false }
        parcels.insert(coord)
        return true
    }

    // MARK: フットプリント

    var railIndex: [GridPoint: RailCell] {
        Dictionary(rails.map { ($0.point, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// 回転 90/270 で幅と奥行が入れ替わる（§2.3）
    static func footprintSize(modelId: String, rotation: Int) -> (width: Int, depth: Int) {
        let base: (width: Int, depth: Int) = Catalog.model(id: modelId)?.simFootprint ?? (width: 2, depth: 2)
        let normalized = ((rotation % 360) + 360) % 360
        if normalized == 90 || normalized == 270 {
            return (width: base.depth, depth: base.width)
        }
        return base
    }

    /// origin を左上とする矩形のセル（y → x の順）
    static func cells(origin: GridPoint, size: (width: Int, depth: Int)) -> [GridPoint] {
        var result: [GridPoint] = []
        for dy in 0..<max(size.depth, 0) {
            for dx in 0..<max(size.width, 0) {
                result.append(GridPoint(x: origin.x + dx, y: origin.y + dy))
            }
        }
        return result
    }

    func cells(of tool: ToolInstance) -> [GridPoint] {
        Self.cells(origin: tool.origin, size: Self.footprintSize(modelId: tool.modelId, rotation: tool.rotation))
    }

    func stockerCells() -> [GridPoint] { Self.cells(origin: stocker.origin, size: Self.stockerSize) }
    func entryCells() -> [GridPoint] { Self.cells(origin: entry.origin, size: Self.entrySize) }
    func shippingCells() -> [GridPoint] { Self.cells(origin: shipping.origin, size: Self.shippingSize) }

    /// 固定設備（ストッカー・投入口・出荷口）が占めるセル
    func facilityCells() -> Set<GridPoint> {
        Set(stockerCells() + entryCells() + shippingCells())
    }

    // MARK: 配置バリデーション（§2.4）

    private static let validRotations: Set<Int> = [0, 90, 180, 270]

    /// 装置を origin・rotation に置けない理由（置けるなら nil）。tools のうち同じ id の装置は自分として除外する
    func toolPlacementError(_ tool: ToolInstance, origin: GridPoint, rotation: Int, among tools: [ToolInstance]) -> String? {
        guard Self.validRotations.contains(rotation) else { return "回転は 0・90・180・270 のいずれかです" }
        let footprint = Self.cells(origin: origin, size: Self.footprintSize(modelId: tool.modelId, rotation: rotation))
        if footprint.contains(where: { !isPurchased(cell: $0) }) { return "購入済みの区画の外です" }
        var toolCells = Set<GridPoint>()
        for other in tools where other.id != tool.id {
            toolCells.formUnion(cells(of: other))
        }
        if footprint.contains(where: { toolCells.contains($0) }) { return "他の装置と重なっています" }
        let facilities = facilityCells()
        if footprint.contains(where: { facilities.contains($0) }) { return "固定設備と重なっています" }
        let railCells = railIndex
        if footprint.contains(where: { railCells[$0] != nil }) { return "レールと重なっています（先にレールを撤去してください）" }
        return nil
    }

    /// 検証を通れば origin・rotation・mirrored を設定したコピーを返す。mirrored が nil なら元の値を保つ
    func placed(_ tool: ToolInstance, origin: GridPoint, rotation: Int, among tools: [ToolInstance],
                mirrored: Bool? = nil) -> ToolInstance? {
        guard toolPlacementError(tool, origin: origin, rotation: rotation, among: tools) == nil else { return nil }
        var result = tool
        result.origin = origin
        result.rotation = rotation
        result.mirrored = mirrored ?? tool.mirrored
        return result
    }

    /// 配置ゴーストの近傍スナップ（β1 実機FB対応）：raw の周囲 radius セル以内で実際に置ける
    /// origin のうち、raw に最も近いもの（マンハッタン距離。同点は y → x の順で決定的）を返す。
    /// raw 自身が置ける場合は raw を返す。範囲内に置ける場所が無ければ nil（ゴーストは raw に出して赤表示）。
    /// ドラッグ配置で指のブレを吸収し、タップ精度に依存しないための補助。
    func snappedOrigin(for tool: ToolInstance, near raw: GridPoint, rotation: Int,
                       among tools: [ToolInstance], radius: Int = 2) -> GridPoint? {
        var candidates: [(point: GridPoint, distance: Int)] = []
        for dy in -radius...radius {
            for dx in -radius...radius {
                let point = GridPoint(x: raw.x + dx, y: raw.y + dy)
                candidates.append((point, abs(dx) + abs(dy)))
            }
        }
        candidates.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.point.y != b.point.y { return a.point.y < b.point.y }
            return a.point.x < b.point.x
        }
        for candidate in candidates {
            if toolPlacementError(tool, origin: candidate.point, rotation: rotation, among: tools) == nil {
                return candidate.point
            }
        }
        return nil
    }

    /// レールを point に置けない理由。既存レールの置き換えは可
    func railPlacementError(at point: GridPoint, among tools: [ToolInstance]) -> String? {
        if !isPurchased(cell: point) { return "購入済みの区画の外です" }
        if tools.contains(where: { cells(of: $0).contains(point) }) { return "装置と重なっています" }
        if facilityCells().contains(point) { return "固定設備と重なっています" }
        return nil
    }

    /// 同じ位置にレールがあれば置き換える
    @discardableResult
    mutating func setRail(_ cell: RailCell, among tools: [ToolInstance]) -> Bool {
        guard railPlacementError(at: cell.point, among: tools) == nil else { return false }
        if let index = rails.firstIndex(where: { $0.point == cell.point }) {
            rails[index] = cell
        } else {
            rails.append(cell)
        }
        return true
    }

    @discardableResult
    mutating func removeRail(at point: GridPoint) -> Bool {
        guard let index = rails.firstIndex(where: { $0.point == point }) else { return false }
        rails.remove(at: index)
        paidRailPoints.remove(point)
        return true
    }
}

// 旧セーブ互換：paidRailPoints を欠いていても読めるようにする。
// extension に置くことで memberwise init を残す
extension FloorLayout {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parcels = try container.decode(Set<ParcelCoord>.self, forKey: .parcels)
        rails = try container.decode([RailCell].self, forKey: .rails)
        stocker = try container.decode(Stocker.self, forKey: .stocker)
        entry = try container.decode(EntryPort.self, forKey: .entry)
        shipping = try container.decode(ShippingPort.self, forKey: .shipping)
        if let paid = try container.decodeIfPresent(Set<GridPoint>.self, forKey: .paidRailPoints) {
            paidRailPoints = paid
        } else {
            // β1 セーブには購入記録が無いため、β1 当時の初期テンプレート（リング型）のレール位置と
            // 一致しないものをプレイヤーが購入したレールとみなす（テンプレ位置の付け替えは記録が
            // 無いので無償扱いになる割り切り）。照合に使うのは現行テンプレートではなく
            // LayoutTemplate.legacyTemplateRailPoints（β1〜β3 のリング位置で固定）：
            // テンプレートを差し替えても旧セーブの復元結果が変わらないようにするため
            paidRailPoints = Set(rails.map { $0.point }).subtracting(LayoutTemplate.legacyTemplateRailPoints)
        }
    }
}

// MARK: - レールグラフ（§1.5）

struct RailGraph {
    let cells: [GridPoint: RailCell]

    init(layout: FloorLayout) {
        cells = layout.railIndex
    }

    /// point から進める隣接セル。直線・コーナー・合流は自セルの向きのみ、分岐・交差は向きと左右。
    /// 隣のレールが逆向き（こちらへ向かってくる）なら進めない。順序は north, east, south, west
    func exits(of point: GridPoint) -> [(direction: RailDirection, to: GridPoint)] {
        guard let cell = cells[point] else { return [] }
        let candidates: [RailDirection]
        switch cell.kind {
        case .straight, .corner, .merge:
            candidates = [cell.direction]
        case .branch, .cross:
            candidates = [cell.direction, cell.direction.rotatedCW, cell.direction.rotatedCCW]
        }
        var result: [(direction: RailDirection, to: GridPoint)] = []
        for d in RailDirection.ordered where candidates.contains(d) {
            let next = point.moved(d)
            if let nextCell = cells[next], nextCell.direction != d.opposite {
                result.append((direction: d, to: next))
            }
        }
        return result
    }

    /// 多始点 BFS。レールのある始点だけを種にし、種がゴールなら [種] を返す。経路は始点・終点を含むセル列
    func shortestPath(from starts: [GridPoint], to goals: Set<GridPoint>) -> [GridPoint]? {
        let seeds = starts.filter { cells[$0] != nil }
        if let hit = seeds.first(where: { goals.contains($0) }) { return [hit] }
        var previous: [GridPoint: GridPoint] = [:]
        var visited = Set<GridPoint>()
        var queue: [GridPoint] = []
        for seed in seeds where !visited.contains(seed) {
            visited.insert(seed)
            queue.append(seed)
        }
        var head = 0
        while head < queue.count {
            let point = queue[head]
            head += 1
            for exit in exits(of: point) where !visited.contains(exit.to) {
                visited.insert(exit.to)
                previous[exit.to] = point
                if goals.contains(exit.to) {
                    var path = [exit.to]
                    var cursor = point
                    path.append(cursor)
                    while let p = previous[cursor] {
                        cursor = p
                        path.append(cursor)
                    }
                    return Array(path.reversed())
                }
                queue.append(exit.to)
            }
        }
        return nil
    }

    /// cell の出口を種にした BFS で goals へ戻る循環経路（先頭は cell、長さ 2 以上）。
    /// cell 自身が goals に含まれていても、1歩以上進んでから最初に goals に着いた経路を返す
    func loopPath(from cell: GridPoint, to goals: Set<GridPoint>) -> [GridPoint]? {
        guard cells[cell] != nil else { return nil }
        let seeds = exits(of: cell).map { $0.to }
        guard let tail = shortestPath(from: seeds, to: goals) else { return nil }
        return [cell] + tail
    }

    /// starts（レールのあるもの）から到達できるセルの集合（始点を含む）
    func reachableCells(from starts: [GridPoint]) -> Set<GridPoint> {
        var visited = Set<GridPoint>()
        var queue: [GridPoint] = []
        for seed in starts where cells[seed] != nil && !visited.contains(seed) {
            visited.insert(seed)
            queue.append(seed)
        }
        var head = 0
        while head < queue.count {
            let point = queue[head]
            head += 1
            for exit in exits(of: point) where !visited.contains(exit.to) {
                visited.insert(exit.to)
                queue.append(exit.to)
            }
        }
        return visited
    }

    /// フットプリントに4近傍で接するレールセル（フットプリント内は除く）。(y, x) 順
    func portCells(footprint: [GridPoint]) -> [GridPoint] {
        let inside = Set(footprint)
        var result = Set<GridPoint>()
        for cell in footprint {
            for d in RailDirection.ordered {
                let next = cell.moved(d)
                if cells[next] != nil && !inside.contains(next) {
                    result.insert(next)
                }
            }
        }
        return result.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }
}

// MARK: - 接続解析（§1.7 ライン寸断・未接続装置）

enum LayoutProblem: Equatable {
    /// from nil = 投入口、to nil = 出荷口
    case lineBreak(from: ProcessType?, to: ProcessType?)
    case unconnectedInput(toolId: UUID, modelId: String)
    case unconnectedOutput(toolId: UUID, modelId: String)

    var message: String {
        switch self {
        case .lineBreak(let from, let to):
            let fromName = from?.displayName ?? "投入口"
            let toName = to?.displayName ?? "出荷口"
            return "\(fromName) → \(toName) のレールが足りません"
        case .unconnectedInput(_, let modelId):
            return "\(Self.modelName(modelId)) が未接続です（入口）"
        case .unconnectedOutput(_, let modelId):
            return "\(Self.modelName(modelId)) が未接続です（出口）"
        }
    }

    private static func modelName(_ modelId: String) -> String {
        Catalog.model(id: modelId)?.name ?? modelId
    }
}

struct LayoutAnalysis {
    var problems: [LayoutProblem]

    /// ライン成立（寸断なし）
    var lineConnected: Bool {
        !problems.contains {
            if case .lineBreak = $0 { return true }
            return false
        }
    }

    /// 施設ノード（投入口・ストッカー・出荷口・装置）
    private enum Node: Hashable {
        case entry, stocker, shipping
        case tool(UUID)
    }

    private struct ProcessPair: Hashable {
        var from: ProcessType
        var to: ProcessType
    }

    static func analyze(layout: FloorLayout, tools: [ToolInstance], nodeId: String, lithoClass: LithoClass) -> LayoutAnalysis {
        let graph = RailGraph(layout: layout)
        let placedTools = tools.filter { Catalog.model(id: $0.modelId) != nil }

        // 施設ノードとポートセル
        var nodes: [Node] = [.entry, .stocker, .shipping]
        var ports: [Node: [GridPoint]] = [
            .entry: graph.portCells(footprint: layout.entryCells()),
            .stocker: graph.portCells(footprint: layout.stockerCells()),
            .shipping: graph.portCells(footprint: layout.shippingCells()),
        ]
        for tool in placedTools {
            nodes.append(.tool(tool.id))
            ports[.tool(tool.id)] = graph.portCells(footprint: layout.cells(of: tool))
        }

        // 施設間エッジ F→G：F のポートから G のポートへレール経路がある（F ≠ G）。
        // shortestPath(...) != nil と同値な到達集合で判定する
        var edges: [Node: Set<Node>] = [:]
        for f in nodes {
            let reachable = graph.reachableCells(from: ports[f] ?? [])
            var targets = Set<Node>()
            for g in nodes where g != f {
                if (ports[g] ?? []).contains(where: { reachable.contains($0) }) {
                    targets.insert(g)
                }
            }
            edges[f] = targets
        }
        func edge(_ f: Node, _ g: Node) -> Bool { edges[f]?.contains(g) ?? false }

        // 投入口から辿れる施設・出荷口へ辿れる施設
        var fromEntry: Set<Node> = [.entry]
        var queue: [Node] = [.entry]
        while let node = queue.popLast() {
            for next in nodes where edge(node, next) && !fromEntry.contains(next) {
                fromEntry.insert(next)
                queue.append(next)
            }
        }
        var toShipping: Set<Node> = [.shipping]
        queue = [.shipping]
        while let node = queue.popLast() {
            for prev in nodes where edge(prev, node) && !toShipping.contains(prev) {
                toShipping.insert(prev)
                queue.append(prev)
            }
        }

        // ルートの連続ペア
        let steps = RouteBuilder.routeSteps(node: Catalog.node(id: nodeId) ?? Catalog.defaultNode, lithoClass: lithoClass)
        func candidates(_ process: ProcessType) -> [ToolInstance] {
            placedTools.filter { tool in
                guard let model = Catalog.model(id: tool.modelId) else { return false }
                return model.process == process && model.supports(nodeId: nodeId)
            }
        }
        func connected(_ p: ProcessType, _ q: ProcessType) -> Bool {
            for a in candidates(p) {
                for b in candidates(q) {
                    let na = Node.tool(a.id)
                    let nb = Node.tool(b.id)
                    if a.id == b.id {
                        if edge(na, .stocker) && edge(.stocker, na) { return true }
                    } else if edge(na, nb) || (edge(na, .stocker) && edge(.stocker, nb)) {
                        return true
                    }
                }
            }
            return false
        }

        var problems: [LayoutProblem] = []
        if let first = steps.first {
            let ok = candidates(first).contains { b in
                let nb = Node.tool(b.id)
                return edge(.entry, nb) || (edge(.entry, .stocker) && edge(.stocker, nb))
            }
            if !ok { problems.append(.lineBreak(from: nil, to: first)) }
        }
        var seenPairs = Set<ProcessPair>()
        if steps.count >= 2 {
            for i in 0..<(steps.count - 1) {
                let pair = ProcessPair(from: steps[i], to: steps[i + 1])
                guard !seenPairs.contains(pair) else { continue }
                seenPairs.insert(pair)
                if !connected(pair.from, pair.to) {
                    problems.append(.lineBreak(from: pair.from, to: pair.to))
                }
            }
        }
        if let last = steps.last {
            let ok = candidates(last).contains { a in
                let na = Node.tool(a.id)
                return edge(na, .shipping) || (edge(na, .stocker) && edge(.stocker, .shipping))
            }
            if !ok { problems.append(.lineBreak(from: last, to: nil)) }
        }

        // 未接続装置（toolId 文字列順）
        let sortedTools = placedTools.sorted { $0.id.uuidString < $1.id.uuidString }
        for tool in sortedTools where !fromEntry.contains(.tool(tool.id)) {
            problems.append(.unconnectedInput(toolId: tool.id, modelId: tool.modelId))
        }
        for tool in sortedTools where !toShipping.contains(.tool(tool.id)) {
            problems.append(.unconnectedOutput(toolId: tool.id, modelId: tool.modelId))
        }
        return LayoutAnalysis(problems: problems)
    }
}

// MARK: - 工程順（可読性）

enum RouteStepOrder {
    /// ルート（RouteBuilder.routeSteps）で各工程が最初に現れる順位（1始まり）。
    /// フロア上の工程順バッジ（①成膜 → ②露光 → …）と、テンプレートの並びが
    /// 工程順に読めることの検証に使う。ルートに現れない工程は含まれない
    static func ranks(node: NodeSpec, lithoClass: LithoClass?) -> [ProcessType: Int] {
        var result: [ProcessType: Int] = [:]
        for step in RouteBuilder.routeSteps(node: node, lithoClass: lithoClass) where result[step] == nil {
            result[step] = result.count + 1
        }
        return result
    }
}

// MARK: - デフォルト配置テンプレート（§2.6）

enum LayoutTemplate {
    /// β1〜β3 の初期テンプレート（リング型）のレールセルの位置集合（40 セル、スパー 2 セル含む）。
    /// 旧セーブ（paidRailPoints を欠く β1 セーブ）の購入済み判定専用に、位置を固定して保持する。
    /// 現行テンプレートを差し替えても、この集合は絶対に変更しないこと（旧セーブの復元結果が変わる）。
    /// リング形状：上段 y=5 を x=0→15、右端 x=15 を y=6→9、下段 y=9 を x=14→0、左端 x=0 を y=8→6、
    /// ストッカー両脇のスパー (3,6)・(6,6)
    static let legacyTemplateRailPoints: Set<GridPoint> = {
        var points = Set<GridPoint>()
        for x in 0...15 { points.insert(GridPoint(x: x, y: 5)) }
        for y in 6...9 { points.insert(GridPoint(x: 15, y: y)) }
        for x in 0...14 { points.insert(GridPoint(x: x, y: 9)) }
        for y in 6...8 { points.insert(GridPoint(x: 0, y: y)) }
        points.insert(GridPoint(x: 3, y: 6))
        points.insert(GridPoint(x: 6, y: 6))
        return points
    }()

    /// 本線の Y。感度測定用に定数化（6 で最終案と完全一致）
    static let templateLaneY = 6

    /// 初期装備（L1×2, D1×2, E1×3, I1, C1, Q1, P1）の 16×16 テンプレート（トラックLINE：一直線型・最終案）。
    /// 蛇行型（トラックE）も実機FBで「蛇行でも輪っかに見える。ラインは一直線がいい」とされたため、
    /// 本線を 1 本の直線に組み替えた。トポロジーは従来どおり 1 本の有向循環路のまま
    /// （一方向・1セル1ロット搬送では循環路が無いと上流へ戻る再入ロットと正面衝突して凍結するため）。
    /// ワンパス化（再入ごとに装置を並べ直す直列ライン）は、初期装備 11 台では再入回数に対して装置が
    /// 足りず不可能だった。見た目だけを「一直線の本線＋目立たない戻り」に変えている。
    /// 構成は本線 16 セル＋戻りレーン 32 セルの計 48 セル：
    /// - 本線（y=6、東向き、(0,6)〜(15,6) の一直線）。両岸に装置を並べ、ポートは全て y=6 に接する
    /// - 戻りレーン：本線東端 (15,6) から東端 x=15 を南下し、南端 y=15 を西へ、西端 x=0 を北上して
    ///   本線始端 (0,6) へ合流する細い 1 レーン（再入＝次層の成膜へ戻る循環専用）
    /// 設計の経緯：
    /// - 第1案（本線 y=8・ストッカー南東隅 (13,13)、岸ごとに西→東で工程順）は定常スループットが
    ///   5.500 WPH まで低下した（蛇行型は 7.458）。原因は (1) ストッカーが遠く払い出しが滞って WIP の
    ///   大半がストッカーに滞留したこと、(2) 露光→エッチング等の主要遷移で毎回ループ全周の搬送を払う
    ///   配置だったこと
    /// - 第2案（本線 y=8・ポートの x 順を工程順に寄せ、ストッカーを投入口脇の南西 (1,9)）は運転点 WIP49 で
    ///   完全に凍結した。凍結時はレール上のロットの大半が成膜行きで、成膜ポートからストッカーへの退避経路が
    ///   長すぎた（D1 (3,6) のポート (3,8),(4,8) からストッカーのポートまで前方距離が約 34 セル）
    /// - 第2.5案（ストッカー (3,9) と P1 を入れ替え、成膜ポートからの退避距離を 3 セル以内に）は短期の定常が
    ///   7.562 WPH で帯内だったが、オフライン進行の長期ラン（約 76,000 step）でレール全セルが埋まって凍結した。
    ///   44 セルではキューの逃げ場が足りない
    /// - 最終案（本テンプレート）：本線を y=6 に上げて戻りレーンを 32 セルに伸ばし、レール 48 セル・
    ///   運転点 53（operatingWipCap = レール数 + 5）にした。長期ラン 200,000 step でも凍結せず、
    ///   定常 7.688 WPH・検出率 0.7811（いずれも従来の判定帯内）
    /// 装置の x 順・岸の振り分け・回転は第2.5案から不変。28nm ルート（72 ステップ）の遷移頻度（成膜→露光 ×15、
    /// 露光→エッチング ×15、エッチング→注入 ×8、エッチング→CMP ×5、成膜への帰還は注入 ×7・エッチング ×6・
    /// CMP ×4・検査 ×2 の計 ×19 等）に基づき、本線上のポートの x 順を工程順に寄せている。成膜（西端）→露光→
    /// エッチング→注入→CMP→検査 と東へ進み、成膜への帰還は東端から戻りレーンで帰るのが搬送総量を最小化する：
    ///   - 北岸は西→東で D1 (1,4)・(3,4) → L1 (5,2)・(8,2) → C1 (11,4) → Q1 (13,4)（成膜 → 露光 → CMP → 検査）
    ///   - 南岸は西→東で P1 (1,7) → ストッカー (3,7) → E1 (5,7)・(7,7)・(9,7) → I1 (11,7)
    ///     （PKG → ストッカー → エッチング → 注入。E1 は露光の x 範囲と重ね、露光の出口から前方にあるエッチを選べる）
    /// 露光 L1 は回転 90 で置く（3 幅×4 奥行、origin y=2 で南辺 y=5 が本線に接する）。4×3 のままでは
    /// 北岸に 2 台と CMP・検査が収まらないため。PKG はルート末尾の 1 回だけなので搬送への影響は小さい。
    /// 投入口は本線始端の北 (0,4) で、ポート (0,6) がそのまま成膜 D1 のポートと重なり、
    /// 「入口のすぐ先が成膜」に見える。出荷口は本線東端の北 (15,4) で、ポートは (15,6)。
    /// ストッカーは南岸 (3,7) に置き、ポート (3,6),(4,6) を成膜 D1 (3,4) のポートと重ねる。全ての成膜ポートから
    /// 退避距離は 3 セル以内、払い出し先の成膜・露光・エッチングへも 0〜2 セル。P1 (1,7) のポート (1,6),(2,6) は
    /// D1 (1,4) のポートと重なるが、PKG はルート末尾の 1 回だけなので無害。
    /// 固定設備の位置は §2.6 の概念図から精密化した
    static func starter16(equipment: [EquipmentInstance]) -> (layout: FloorLayout, placed: [ToolInstance], stored: [ToolInstance]) {
        let laneY = templateLaneY
        var rails: [RailCell] = []
        func rail(_ x: Int, _ y: Int, _ direction: RailDirection, _ kind: RailCellKind) {
            rails.append(RailCell(point: GridPoint(x: x, y: y), direction: direction, kind: kind))
        }
        // 本線（y=6、東向き、一直線）。(0,6) は戻りレーンから北上して入る合流角、(15,6) は南への折れ角
        rail(0, laneY, .east, .corner)
        for x in 1...14 { rail(x, laneY, .east, .straight) }
        rail(15, laneY, .south, .corner)
        // 戻りレーン：東端 x=15 を南下
        for y in (laneY + 1)...14 { rail(15, y, .south, .straight) }
        // 南端 y=15 を西へ
        rail(15, 15, .west, .corner)
        for x in stride(from: 14, through: 1, by: -1) { rail(x, 15, .west, .straight) }
        // 西端 x=0 を北上して本線始端 (0,6) へ合流
        rail(0, 15, .north, .corner)
        for y in stride(from: 14, through: laneY + 1, by: -1) { rail(0, y, .north, .straight) }

        let layout = FloorLayout(
            parcels: FloorLayout.initialParcels,
            rails: rails,
            // ストッカー (3,7)〜(4,8)：ポートセル (3,6),(4,6)（本線、成膜 D1 (3,4) のポートと共有）
            stocker: Stocker(origin: GridPoint(x: 3, y: laneY + 1)),
            // 投入口 (0,4)〜(0,5)：ポートセル (0,6)（本線始端＝成膜ポートと共有）
            entry: EntryPort(origin: GridPoint(x: 0, y: laneY - 2)),
            // 出荷口 (15,4)〜(15,5)：ポートセル (15,6)（本線東端）
            shipping: ShippingPort(origin: GridPoint(x: 15, y: laneY - 2))
        )

        // 装置スロット（modelId ごとに出現順に、origin と回転のペアで割り当てる）。最終案：本線 y=6 を挟み、
        // ポートの x 順をルート遷移頻度に沿った工程順に寄せる（x 順・岸・回転は第2.5案から不変）。
        // 北岸は D1 → L1 → C1 → Q1（成膜 → 露光 → CMP → 検査）、南岸は P1 → ストッカー → E1 → I1
        // （PKG → ストッカー → エッチング → 注入）。P1 (1,7) のポート (1,6),(2,6) は D1 と重なるが
        // PKG はルート末尾の 1 回だけなので無害。
        // L1 は回転 90 で 3×4 になり origin y=2 で南辺 y=5 が本線に接する（4×3 では北岸に収まらない）。
        // E1 は露光の x 範囲 5〜10 と重ね、I1 は 4×2 で南岸 x11〜14 を占める
        let slots: [String: [(origin: GridPoint, rotation: Int)]] = [
            "D1": [(GridPoint(x: 1, y: laneY - 2), 0), (GridPoint(x: 3, y: laneY - 2), 0)],
            "L1": [(GridPoint(x: 5, y: laneY - 4), 90), (GridPoint(x: 8, y: laneY - 4), 90)],
            "C1": [(GridPoint(x: 11, y: laneY - 2), 0)],
            "Q1": [(GridPoint(x: 13, y: laneY - 2), 0)],
            "P1": [(GridPoint(x: 1, y: laneY + 1), 0)],
            "E1": [(GridPoint(x: 5, y: laneY + 1), 0), (GridPoint(x: 7, y: laneY + 1), 0), (GridPoint(x: 9, y: laneY + 1), 0)],
            "I1": [(GridPoint(x: 11, y: laneY + 1), 0)],
        ]

        let tools = equipment.map { ToolInstance(instance: $0) }
        var placedByIndex: [Int: ToolInstance] = [:]
        var placedSoFar: [ToolInstance] = []
        var slotUsed: [String: Int] = [:]
        var leftovers: [Int] = []

        // 1周目：スロットに収まる装置
        for (index, tool) in tools.enumerated() {
            let used = slotUsed[tool.modelId] ?? 0
            if let modelSlots = slots[tool.modelId], used < modelSlots.count {
                slotUsed[tool.modelId] = used + 1
                let slot = modelSlots[used]
                if let result = layout.placed(tool, origin: slot.origin, rotation: slot.rotation, among: placedSoFar) {
                    placedByIndex[index] = result
                    placedSoFar.append(result)
                    continue
                }
            }
            leftovers.append(index)
        }

        // 2周目：余剰は y → x の走査順で最初に置ける空きへ（回転 0）
        let maxX = ((layout.parcels.map { $0.x }.max() ?? 0) + 1) * FloorLayout.parcelSize
        let maxY = ((layout.parcels.map { $0.y }.max() ?? 0) + 1) * FloorLayout.parcelSize
        var stored: [ToolInstance] = []
        for index in leftovers {
            let tool = tools[index]
            var result: ToolInstance?
            scan: for y in 0..<maxY {
                for x in 0..<maxX {
                    if let candidate = layout.placed(tool, origin: GridPoint(x: x, y: y), rotation: 0, among: placedSoFar) {
                        result = candidate
                        break scan
                    }
                }
            }
            if let result = result {
                placedByIndex[index] = result
                placedSoFar.append(result)
            } else {
                stored.append(tool)
            }
        }

        let placed = tools.indices.compactMap { placedByIndex[$0] }
        return (layout, placed, stored)
    }
}
