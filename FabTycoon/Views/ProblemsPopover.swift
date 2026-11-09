import SwiftUI

// MARK: - 問題ポップオーバー（ドック「問題」）
// 設計書 design/simcity-rebuild.md §3.4。シートにせず、ContentView の下部オーバーレイとして出す。
// 行の内訳は ContentView.problemSummary(store:) と同じ数え方（詰まり＋ライン停止＋layoutProblems＋歩留まり異常＋ストッカー満杯）。
// 「見る」のパン・ハイライト・ポップオーバーを閉じる処理、詰まり解消の実行と結果表示は呼び出し側。

struct ProblemsPopover: View {
    @EnvironmentObject private var store: GameStore

    let onClose: () -> Void
    let onFocusTool: (UUID) -> Void
    let onFocusPoint: (GridPoint) -> Void
    let onOpenBuild: (ProcessType?) -> Void
    let onResolveDeadlock: () -> Void

    @State private var advisorExpanded = false

    /// これより多いと行の部分だけスクロールにする（ドックの上に収めるため）
    private static let maxRowsWithoutScroll = 4
    private static let scrollHeight: CGFloat = 240

    /// 1 行分の表示内容。action が nil ならボタンを出さない
    private struct ProblemRow: Identifiable {
        let id: String
        let text: String
        let critical: Bool
        var buttonTitle: String? = nil
        var action: (() -> Void)? = nil
    }

    var body: some View {
        let rows = problemRows()
        let advisor = Engine.advisorMessage(state: store.state, derived: store.derived)
        VStack(alignment: .leading, spacing: 10) {
            header(count: rows.count)
            Divider()
            if rows.isEmpty {
                Label("問題はありません", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            } else if rows.count > Self.maxRowsWithoutScroll {
                ScrollView {
                    rowList(rows)
                }
                .frame(height: Self.scrollHeight)
            } else {
                rowList(rows)
            }
            if !advisor.isEmpty {
                Divider()
                advisorLine(advisor)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 12)
    }

    // MARK: 見出し・行・アドバイザー

    private func header(count: Int) -> some View {
        HStack {
            Label(count > 0 ? "問題 \(count) 件" : "問題", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
            Spacer()
            Button("閉じる", action: onClose)
                .font(.subheadline)
        }
    }

    private func rowList(_ rows: [ProblemRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                rowView(row)
            }
        }
    }

    private func rowView(_ row: ProblemRow) -> some View {
        let color: Color = row.critical ? .red : .orange
        return HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4)
            Text(row.text)
                .font(.subheadline)
                .foregroundStyle(row.critical ? Color.red : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let title = row.buttonTitle, let action = row.action {
                Button(title, action: action)
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                    .tint(color)
                    .controlSize(.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 最下段のアドバイザー（§3.4）。1 行で出し、タップで全文
    private func advisorLine(_ text: String) -> some View {
        Label(text, systemImage: "lightbulb")
            .font(.caption)
            .lineLimit(advisorExpanded ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: advisorExpanded)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { advisorExpanded.toggle() }
    }

    // MARK: 行の組み立て（ContentView.problemSummary と同じ条件）

    private func problemRows() -> [ProblemRow] {
        let state = store.state
        let derived = store.derived
        var rows: [ProblemRow] = []

        // 1. 詰まり（赤）
        if store.simDeadlocked {
            rows.append(ProblemRow(id: "deadlock",
                                   text: "ラインが詰まっています",
                                   critical: true,
                                   buttonTitle: "解消する",
                                   action: onResolveDeadlock))
        }

        // 2. ライン停止（赤）：稼働台数 0 の工程
        if derived.lineWPH <= 0 && !state.fab.placed.isEmpty {
            let stopped = ProcessType.allCases.filter { derived.units($0) == 0 }
            let names = stopped.map(\.displayName).joined(separator: "・")
            rows.append(ProblemRow(id: "lineStopped",
                                   text: stopped.isEmpty
                                       ? "ラインが止まっています"
                                       : "ラインが止まっています（\(names)の装置が稼働していません）",
                                   critical: true,
                                   buttonTitle: "建設",
                                   action: { onOpenBuild(stopped.first) }))
        }

        // 3. レイアウトの問題（橙）。文言は旧 LayoutProblemsSheet と同じ LayoutProblem.message
        for (index, problem) in store.layoutProblems.enumerated() {
            var row = ProblemRow(id: "layout-\(index)", text: problem.message, critical: false)
            if let toolId = toolId(of: problem) {
                row.buttonTitle = "見る"
                row.action = { onFocusTool(toolId) }
            } else if case .lineBreak(let from, let to) = problem, let point = lineBreakPoint(from: from, to: to) {
                row.buttonTitle = "見る"
                row.action = { onFocusPoint(point) }
            }
            rows.append(row)
        }

        // 4. 歩留まり異常（橙）。「見る」は検査工程の装置へ（欠陥分析は検査装置の ToolCard から開く）
        if state.activeExcursion != nil {
            var row = ProblemRow(id: "excursion",
                                 text: "歩留まり異常が発生しています（ライン歩留まり −\(MoneyFormat.decimal(derived.excursionYieldLoss * 100, digits: 1))pt）",
                                 critical: false)
            if let inspectionTool = Engine.installedTools(state: state)
                .first(where: { Catalog.model(id: $0.modelId)?.process == .inspection }) {
                row.buttonTitle = "見る"
                row.action = { onFocusTool(inspectionTool.id) }
            }
            rows.append(row)
        }

        // 5. ストッカー満杯（橙）。「見る」は投入口へ
        if let stocker = state.fab.sim?.stocker, stocker.capacity > 0, stocker.lotIds.count >= stocker.capacity {
            var row = ProblemRow(id: "stockerFull",
                                 text: "ストッカーが満杯です（\(stocker.lotIds.count)/\(stocker.capacity)）",
                                 critical: false)
            if let layout = state.fab.layout, let point = Self.centroid(layout.entryCells()) {
                row.buttonTitle = "見る"
                row.action = { onFocusPoint(point) }
            }
            rows.append(row)
        }

        return rows
    }

    /// 対象装置が特定できる問題の装置 ID（旧 LayoutProblemsSheet.toolId(of:) と同じ）
    private func toolId(of problem: LayoutProblem) -> UUID? {
        switch problem {
        case .unconnectedInput(let toolId, _), .unconnectedOutput(let toolId, _):
            return toolId
        case .lineBreak:
            return nil
        }
    }

    /// ライン寸断の両端（工程の装置群、nil は投入口／出荷口）の中間点。片側しか無ければその中心
    private func lineBreakPoint(from: ProcessType?, to: ProcessType?) -> GridPoint? {
        guard let layout = store.state.fab.layout else { return nil }
        let tools = Engine.installedTools(state: store.state)
        func cells(of process: ProcessType?, port: [GridPoint]) -> [GridPoint] {
            guard let process else { return port }
            return tools
                .filter { Catalog.model(id: $0.modelId)?.process == process }
                .flatMap { layout.cells(of: $0) }
        }
        let a = Self.centroid(cells(of: from, port: layout.entryCells()))
        let b = Self.centroid(cells(of: to, port: layout.shippingCells()))
        switch (a, b) {
        case let (a?, b?):
            return GridPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        case let (a?, nil):
            return a
        case let (nil, b?):
            return b
        default:
            return nil
        }
    }

    private static func centroid(_ cells: [GridPoint]) -> GridPoint? {
        guard !cells.isEmpty else { return nil }
        let x = Double(cells.reduce(0) { $0 + $1.x }) / Double(cells.count)
        let y = Double(cells.reduce(0) { $0 + $1.y }) / Double(cells.count)
        return GridPoint(x: Int(x.rounded(.down)), y: Int(y.rounded(.down)))
    }
}
