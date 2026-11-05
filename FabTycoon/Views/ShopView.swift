import SwiftUI

struct ShopView: View {
    @EnvironmentObject private var store: GameStore

    private var filteredModels: [EquipmentModel] {
        guard let filter = store.shopProcessFilter else { return Catalog.equipment }
        return Catalog.models(for: filter)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("装置ショップ")
                    .font(.title3.bold())
                    .padding(.horizontal)
                filterBar
                slotSummary
                    .padding(.horizontal)
                expansionRow
                    .padding(.horizontal)
                ForEach(filteredModels) { model in
                    ShopModelCard(model: model)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "全て", isSelected: store.shopProcessFilter == nil) {
                    store.shopProcessFilter = nil
                }
                ForEach(ProcessType.allCases) { process in
                    FilterChip(title: process.shortName, isSelected: store.shopProcessFilter == process) {
                        store.shopProcessFilter = process
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var slotSummary: some View {
        let fab = store.state.fab
        return HStack {
            Label("空きスロット \(fab.freeSlots) / \(fab.slots)", systemImage: "square.grid.3x3")
                .foregroundStyle(fab.freeSlots > 0 ? Color.primary : Color.red)
            Spacer()
            Text("資金 \(MoneyFormat.yen(store.state.cashYen))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    /// 増床（スロット +4）
    private var expansionRow: some View {
        let state = store.state
        let fab = state.fab
        let cost = Engine.expansionCostYen(state: state)
        let canExpand = Engine.canExpandFab(state: state)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("増床（スロット拡張）")
                    .font(.subheadline.bold())
                Text("スロット \(fab.slots) → \(fab.slots + Engine.expansionSlotCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Button {
                    store.expandFab()
                } label: {
                    VStack(spacing: 2) {
                        Text("増床する（+\(Engine.expansionSlotCount)枠）")
                        Text(MoneyFormat.yen(cost))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canExpand)
                if !canExpand {
                    Text("資金不足（あと\(MoneyFormat.yen(cost - state.cashYen))）")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }
}

// MARK: - フィルタチップ

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(Capsule().fill(isSelected ? Color.accentColor : Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - モデルカード

private struct ShopModelCard: View {
    @EnvironmentObject private var store: GameStore
    let model: EquipmentModel

    var body: some View {
        let state = store.state
        let node = Engine.currentNode(state: state)
        let lockReasons = Engine.lockReasons(model: model, nodeId: node.id)
        let isLocked = !lockReasons.isEmpty
        let block = Engine.buyBlockReason(state: state, modelId: model.id)
        // 所持台数は設置中＋倉庫
        let owned = Engine.ownedCount(state: state, modelIds: [model.id])

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                EquipmentIllustration(model: model)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.process.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.name)
                        .font(.headline)
                    if let education = Catalog.education(for: model.id) {
                        Text(education.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text("所持 \(owned)台")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }

            Text(MoneyFormat.yen(model.priceYen))
                .font(.title3.bold())
                .monospacedDigit()

            HStack(spacing: 12) {
                Text("公称 \(MoneyFormat.decimal(model.nominalWPH, digits: 0)) WPH")
                Text("対応 \(supportedNodesText)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if isLocked {
                ForEach(lockReasons, id: \.self) { reason in
                    Label(reason, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                let unit = Engine.unitWPH(model: model, level: 1, state: state)
                let current = store.derived.lineWPH
                let predicted = Engine.lineWPHAfterAdding(state: state, modelId: model.id)
                Divider()
                detailRow("\(node.displayName)での1台実効WPH", MoneyFormat.decimal(unit, digits: 2))
                HStack {
                    Text("購入後ラインWPH")
                    Spacer()
                    Text("\(MoneyFormat.decimal(current)) → \(MoneyFormat.decimal(predicted))")
                        .monospacedDigit()
                        .bold()
                        .foregroundStyle(predicted > current + 1e-9 ? Color.green : Color.secondary)
                }
                .font(.subheadline)
                if predicted <= current + 1e-9 {
                    Text("この工程はボトルネックではないため、ラインWPHは増えません")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                let currentYield = store.derived.processYields[model.process] ?? 0
                let predictedYield = Engine.processYieldAfterAdding(state: state, modelId: model.id)
                fromToRow("購入後 工程歩留まり", current: currentYield, predicted: predictedYield)
                if model.process == .inspection {
                    let currentDetection = store.derived.detectionRate
                    let predictedDetection = Engine.detectionRateAfterAdding(state: state, modelId: model.id)
                    fromToRow("購入後 検出率", current: currentDetection, predicted: predictedDetection)
                }
                if let message = blockMessage(block) {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button {
                    store.buy(model.id)
                } label: {
                    Text("購入")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(block != nil)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .opacity(isLocked ? 0.6 : 1)
    }

    private var supportedNodesText: String {
        model.supportedNodeIds
            .map { Catalog.node(id: $0)?.displayName ?? $0 }
            .joined(separator: "/")
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    /// 割合の From→To 行。改善時のみ緑
    private func fromToRow(_ title: String, current: Double, predicted: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(MoneyFormat.percent(current)) → \(MoneyFormat.percent(predicted))")
                .monospacedDigit()
                .bold()
                .foregroundStyle(predicted > current + 1e-9 ? Color.green : Color.secondary)
        }
        .font(.subheadline)
    }

    private func blockMessage(_ reason: BuyBlockReason?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case .unknownModel:
            return "不明な装置です"
        case .locked(let reasons):
            return reasons.joined(separator: "／")
        case .noFreeSlot:
            return "スロット不足（空きがありません）"
        case .insufficientCash(let shortfall):
            return "資金不足（あと\(MoneyFormat.yen(shortfall))）"
        }
    }
}
