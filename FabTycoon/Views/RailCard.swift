import SwiftUI

// MARK: - R2 RailCard・StockerCard（レールセル／ストッカーをタップしたときの下部カード）
// 設計書 design/simcity-rebuild.md §1.5・§3.1・§5.3。ContentView の自前オーバーレイで出す（.sheet にしない）。
// 行列の長さは Engine.railCongestion(state:)（熱色と同じ値）を正とする。

struct RailCard: View {
    @EnvironmentObject private var store: GameStore

    let cell: GridPoint
    let onClose: () -> Void

    var body: some View {
        let state = store.state
        let length = Engine.railCongestion(state: state)[cell]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("レール (\(cell.x), \(cell.y))", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                Spacer()
                Button("閉じる", action: onClose)
                    .font(.subheadline)
            }
            Divider()
            if let length, length > 0 {
                Label("この先 \(length) 台が待っています", systemImage: "hourglass")
                    .font(.subheadline.bold())
                    .foregroundStyle(Self.heatColor(length))
                    .monospacedDigit()
                if let head = Self.headLot(state: state, cell: cell) {
                    Label("先頭の行き先：\(MapCardText.destinationText(state: state, lot: head))",
                          systemImage: "arrow.triangle.turn.up.right.circle")
                        .font(.subheadline)
                }
                Text("行き先の装置のポートが空くまで、後ろの FOUP も進めません。行き先の工程を増やすか、レールを足して逃げ道を作りましょう。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("このレールで待っている FOUP はありません", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
        }
        .mapCardBackground()
    }

    /// 熱色（§3.1：黄 2 個 → 橙 4 個 → 赤 6 個以上）
    private static func heatColor(_ length: Int) -> Color {
        if length >= 6 { return .red }
        if length >= Engine.railCongestionOrangeLength { return .orange }
        return .yellow
    }

    /// 行列の先頭ロット。
    /// 先頭の定義：タップしたセルが属する停止区間（railCongestion と同じ連結成分＝停止セルを RailGraph の exits で
    /// 向きを問わず結んだもの）にいる停止ロットのうち、「停止区間の下流端に最も近い」もの。
    /// 近さは、そのロット自身の経路（lot.path）を現在セルから進行方向へ辿って区間の外へ出るまでに通る区間内セルの数で測り、
    /// 最小のものを先頭とする（0 ＝次のセルがもう区間外＝下流端にいる）。
    /// 分岐・合流で下流端が複数あって同数になったら、待ち時間（waitedGameMin）が長い方、さらに id 順で決める。
    static func headLot(state: GameState, cell: GridPoint) -> Lot? {
        guard let sim = state.fab.sim, let layout = state.fab.layout else { return nil }

        // 停止ロットとそのセル（Engine.railCongestion と同じ判定）
        var stoppedLots: [(lot: Lot, cellIndex: Int)] = []
        var stopped = Set<GridPoint>()
        for lot in sim.lots {
            guard case .rail(let cellIndex, let progress) = lot.location, progress >= 0.999,
                  lot.path.indices.contains(cellIndex) else { continue }
            stoppedLots.append((lot, cellIndex))
            stopped.insert(lot.path[cellIndex])
        }
        guard stopped.contains(cell) else { return nil }

        // タップしたセルの連結成分
        let graph = RailGraph(layout: layout)
        var neighbors: [GridPoint: Set<GridPoint>] = [:]
        for point in stopped {
            for exit in graph.exits(of: point) where stopped.contains(exit.to) {
                neighbors[point, default: []].insert(exit.to)
                neighbors[exit.to, default: []].insert(point)
            }
        }
        var component: Set<GridPoint> = [cell]
        var queue: [GridPoint] = [cell]
        var head = 0
        while head < queue.count {
            let point = queue[head]
            head += 1
            for next in neighbors[point] ?? [] where !component.contains(next) {
                component.insert(next)
                queue.append(next)
            }
        }

        // 下流端までの距離が最小の停止ロット
        var best: (lot: Lot, distance: Int)?
        for (lot, cellIndex) in stoppedLots where component.contains(lot.path[cellIndex]) {
            var distance = 0
            var index = cellIndex + 1
            while index < lot.path.count, component.contains(lot.path[index]) {
                distance += 1
                index += 1
            }
            if let current = best {
                let better = distance < current.distance
                    || (distance == current.distance && lot.waitedGameMin > current.lot.waitedGameMin)
                    || (distance == current.distance && lot.waitedGameMin == current.lot.waitedGameMin
                        && lot.id.uuidString < current.lot.id.uuidString)
                if better { best = (lot, distance) }
            } else {
                best = (lot, distance)
            }
        }
        return best?.lot
    }
}

struct StockerCard: View {
    @EnvironmentObject private var store: GameStore

    let onClose: () -> Void

    /// ノード別の内訳 1 行
    private struct NodeRow: Identifiable {
        let id: String
        let name: String
        let count: Int
        /// 平均の進み（stepIndex ＋ 1 の平均）
        let averageStep: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("ストッカー", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                Spacer()
                Button("閉じる", action: onClose)
                    .font(.subheadline)
            }
            Divider()
            if let sim = store.state.fab.sim {
                content(sim)
            } else {
                Text("ストッカーはまだ動いていません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .mapCardBackground()
    }

    private func content(_ sim: SimSnapshot) -> some View {
        let stocker = sim.stocker
        let count = stocker.lotIds.count
        let capacity = stocker.capacity
        let ratio = capacity > 0 ? min(Double(count) / Double(capacity), 1) : 0
        let isFull = capacity > 0 && count >= capacity
        let rows = Self.nodeRows(sim)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("在庫")
                Spacer()
                Text("\(count) / \(capacity)")
                    .monospacedDigit()
                    .bold()
                    .foregroundStyle(isFull ? Color.red : Color.primary)
            }
            .font(.subheadline)
            ProgressView(value: ratio)
                .tint(isFull ? .red : (ratio >= 0.9 ? .orange : .accentColor))
            if isFull {
                Label("満杯のため投入が止まっています", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
                Text("レールを足すか、行き先の工程を増やしましょう。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("中身は空です")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("中身の内訳")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text("\(row.count) 件 ／ 平均ステップ \(MoneyFormat.decimal(row.averageStep, digits: 0))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill)))
            }
        }
    }

    /// stocker.lotIds のロットを nodeId 別に数える（件数の多い順、同数は nodeId 順）
    private static func nodeRows(_ sim: SimSnapshot) -> [NodeRow] {
        let lotsById = Dictionary(sim.lots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        var stepSums: [String: Int] = [:]
        for lotId in sim.stocker.lotIds {
            guard let lot = lotsById[lotId] else { continue }
            counts[lot.nodeId, default: 0] += 1
            stepSums[lot.nodeId, default: 0] += lot.stepIndex + 1
        }
        return counts
            .map { nodeId, count in
                NodeRow(id: nodeId,
                        name: Catalog.node(id: nodeId)?.displayName ?? nodeId,
                        count: count,
                        averageStep: Double(stepSums[nodeId] ?? 0) / Double(count))
            }
            .sorted { ($1.count, $0.id) < ($0.count, $1.id) }
    }
}
