import SwiftUI

// MARK: - R2 LotCard（FOUP 追跡カード）
// 設計書 design/simcity-rebuild.md §4.5。FOUP をタップすると store.trackLot(id) で追跡が始まり、ContentView の自前オーバーレイで出す。
// 表示は Engine.lotProgress(state:lotId:) を正とする。nil（出荷・消滅でロットが sim から消えた）なら「完成しました」。
// 時間はゲーム内時間（実 1 秒＝ゲーム 10 分）を時間換算して出す。

struct LotCard: View {
    @EnvironmentObject private var store: GameStore

    /// 追跡中の FOUP が画面外にあるときの方向矢印（↑↗→↘↓↙←↖）。画面内なら nil（MapScene が通知）
    var trackedDirection: String? = nil
    /// 「この工程を学ぶ」：現工程の図鑑 id（Catalog.processGlossaryId）を渡す
    var onLearn: (String) -> Void = { _ in }

    var body: some View {
        if let lotId = store.trackedLotId {
            card(lotId: lotId)
        } else {
            EmptyView()
        }
    }

    private func card(lotId: UUID) -> some View {
        let state = store.state
        let progress = Engine.lotProgress(state: state, lotId: lotId)
        let lot = state.fab.sim?.lots.first { $0.id == lotId }
        return VStack(alignment: .leading, spacing: 10) {
            header(lot: lot)
            Divider()
            if let progress {
                progressSection(progress)
                timeAndQualitySection(progress)
                destinationRow(progress, lot: lot)
            } else {
                Label("この FOUP は完成しました", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                Text("ラインを流れ終えて出荷口へ出ました。別の FOUP をタップすると追跡できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    store.trackLot(nil)
                } label: {
                    Label("追跡をやめる", systemImage: "scope")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if let process = progress?.currentProcess {
                    Button {
                        onLearn(Catalog.processGlossaryId(process))
                    } label: {
                        Label("この工程を学ぶ", systemImage: "book")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .mapCardBackground()
    }

    // MARK: 見出し

    private func header(lot: Lot?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.yellow)
            Text("FOUP 追跡")
                .font(.headline)
            if let lot {
                Text(Catalog.node(id: lot.nodeId)?.displayName ?? lot.nodeId)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                Text("\(lot.wafers) 枚")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 画面外にいる間だけ、FOUP のいる方向を右上に出す（§4.5）
            if let trackedDirection {
                Text(trackedDirection)
                    .font(.title3.bold())
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(Color.yellow.opacity(0.15)))
                    .accessibilityLabel(Text("FOUP は画面外（\(trackedDirection) の方向）"))
            }
            Button {
                store.trackLot(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("追跡をやめる"))
        }
    }

    // MARK: 進み（現工程の何回目か＋ルート全体のステップ）

    private func progressSection(_ progress: LotProgress) -> some View {
        let total = max(progress.totalSteps, 1)
        let done = min(max(progress.stepIndex, 0), total)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let process = progress.currentProcess {
                    Text(process.displayName)
                        .font(.subheadline.bold())
                        .foregroundStyle(process.accent)
                    if progress.totalPasses > 0 {
                        Text("\(progress.passNumber)/\(progress.totalPasses) 回目")
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                } else {
                    Text("全工程を通過（出荷待ち）")
                        .font(.subheadline.bold())
                }
                Spacer(minLength: 4)
                Text("ステップ \(min(progress.stepIndex + 1, progress.totalSteps))/\(progress.totalSteps)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(.yellow)
                Text(MoneyFormat.percent(Double(done) / Double(total), digits: 0))
                    .font(.caption.bold())
                    .monospacedDigit()
            }
            if let next = progress.nextProcess {
                Text("次：\(next.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 滞在時間・良品率・推定不良率

    private func timeAndQualitySection(_ progress: LotProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            infoRow("滞在時間",
                    "経過 \(MapCardText.hoursText(progress.elapsedGameMin))（うち待ち \(MapCardText.hoursText(progress.waitedGameMin))）")
            infoRow(progress.lastInspectionDefectRate == nil ? "予想良品率（検査前）" : "予想良品率",
                    MoneyFormat.percent(progress.expectedGoodFraction, digits: 0))
            if let defectRate = progress.lastInspectionDefectRate {
                let isRed = progress.qualityBand == .red
                HStack {
                    if isRed {
                        Label("推定不良率", systemImage: "exclamationmark.triangle.fill")
                    } else {
                        Text("推定不良率（検査済み）")
                    }
                    Spacer()
                    Text(MoneyFormat.percent(defectRate, digits: 0))
                        .monospacedDigit()
                        .bold(isRed)
                }
                .font(.subheadline)
                .foregroundStyle(isRed ? Color.red : Color.secondary)
                if isRed {
                    Text("検査で不良が多く見つかった FOUP です。原因の装置を探しましょう。")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 行き先

    /// ポートで処理中ならその装置を「処理中」、それ以外は行き先の装置（無ければロットの destination）
    private func destinationRow(_ progress: LotProgress, lot: Lot?) -> some View {
        let state = store.state
        let text: String
        if let toolId = progress.currentToolId, Self.isProcessing(state: state, toolId: toolId, lotId: progress.lotId) {
            text = "処理中：\(MapCardText.toolName(state: state, toolId: toolId))"
        } else if let toolId = progress.destinationToolId {
            text = "行き先：\(MapCardText.toolName(state: state, toolId: toolId))"
        } else if let toolId = progress.currentToolId {
            text = "ポートで待機：\(MapCardText.toolName(state: state, toolId: toolId))"
        } else if let lot {
            text = "行き先：\(MapCardText.destinationText(state: state, lot: lot))"
        } else {
            text = "行き先：—"
        }
        return Label(text, systemImage: "arrow.triangle.turn.up.right.circle")
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func isProcessing(state: GameState, toolId: UUID, lotId: UUID) -> Bool {
        guard let tool = state.fab.sim?.tools.first(where: { $0.id == toolId }) else { return false }
        return tool.ports.contains { $0.lotId == lotId && $0.state == .processing }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }
}

// MARK: - フロア上カード共通の文言（LotCard・RailCard・StockerCard）

enum MapCardText {
    /// 設置済み装置の表示名「E1 プラズマエッチャー #2」。通し番号は ToolCardInfo と同じ（同モデルの購入順、1 始まり）
    static func toolName(state: GameState, toolId: UUID) -> String {
        let installed = Engine.installedTools(state: state)
        guard let tool = installed.first(where: { $0.id == toolId }),
              let model = Catalog.model(id: tool.modelId)
        else { return "撤去された装置" }
        let sameModel = installed
            .filter { $0.modelId == tool.modelId }
            .sorted { ($0.purchasedAt, $0.id.uuidString) < ($1.purchasedAt, $1.id.uuidString) }
        let serial = (sameModel.firstIndex(where: { $0.id == toolId }) ?? 0) + 1
        return "\(model.id) \(model.name) #\(serial)"
    }

    /// ロットの行き先（destinationToolId を優先し、無ければレール搬送の destination）
    static func destinationText(state: GameState, lot: Lot) -> String {
        if let toolId = lot.destinationToolId {
            return toolName(state: state, toolId: toolId)
        }
        switch lot.destination {
        case .tool(let toolId):
            return toolName(state: state, toolId: toolId)
        case .stocker:
            return "ストッカー"
        case .shipping:
            return "出荷口"
        case nil:
            return "未定"
        }
    }

    /// ゲーム内の分を「12.5 時間」に
    static func hoursText(_ gameMin: Double) -> String {
        "\(MoneyFormat.decimal(max(gameMin, 0) / 60, digits: 1)) 時間"
    }
}

// MARK: - フロア上カードの外枠（ProblemsPopover と同じ角丸パネル、下部オーバーレイ前提）

extension View {
    func mapCardBackground() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 12)
    }
}
