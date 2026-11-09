import SwiftUI

// MARK: - R1 建設ドロワー
// 設計書 design/simcity-rebuild.md §2.2。ドックの「建設 ＋」から下に出す自前オーバーレイ（シートにしない）。
// 表示中もマップは触れる。購入・倉庫のタイルをタップすると placement をセットして閉じ、ゴーストは MapScene が出す。
// 配置開始で 1 段縮む挙動は MapScene のゴーストと ContentView の排他表示で担保するので、ここは固定高。
// 旧 ShopView の FilterChip・ShopModelCard の数値部・blockMessage をここへ移植した（ShopView には依存しない）。

struct BuildDrawer: View {
    @EnvironmentObject private var store: GameStore

    @Binding var placement: PlacementRequest?
    var onClose: () -> Void
    var onEnterRailMode: () -> Void

    /// 画面に対するドロワーの高さ（§2.2）
    static let heightFraction: CGFloat = 0.4

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch store.buildDrawerTab {
            case .shop:
                BuildShopTab(placement: $placement, onClose: onClose)
            case .storage:
                BuildStorageTab(placement: $placement, onClose: onClose)
            case .rail:
                BuildRailTab(onEnterRailMode: onEnterRailMode)
            case .remove:
                BuildRemoveTab()
            }
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical, alignment: .bottom) { length, _ in
            length * Self.heightFraction
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        .padding(.horizontal, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("建設", selection: $store.buildDrawerTab) {
                Text("購入").tag(BuildDrawerTab.shop)
                Text(storageTitle).tag(BuildDrawerTab.storage)
                Text("レール").tag(BuildDrawerTab.rail)
                Text("撤去").tag(BuildDrawerTab.remove)
            }
            .pickerStyle(.segmented)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("閉じる"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var storageTitle: String {
        let count = store.state.fab.storedEquipment.count
        return count > 0 ? "倉庫 \(count)" : "倉庫"
    }
}

// MARK: - 購入タブ

private struct BuildShopTab: View {
    @EnvironmentObject private var store: GameStore
    @Binding var placement: PlacementRequest?
    var onClose: () -> Void

    /// 「i」で数値を展開しているモデル
    @State private var expandedModelId: String?

    private var filteredModels: [EquipmentModel] {
        guard let filter = store.shopProcessFilter else { return Catalog.equipment }
        return Catalog.models(for: filter)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredModels) { model in
                        BuildModelTile(
                            model: model,
                            isExpanded: expandedModelId == model.id,
                            onToggleInfo: {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    expandedModelId = expandedModelId == model.id ? nil : model.id
                                }
                            },
                            onSelect: {
                                placement = .purchase(modelId: model.id)
                                onClose()
                            })
                    }
                    Text("タイルをタップすると、マップ上で置く場所を選べます（「ここに置く」で購入）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                BuildProcessChip(title: "全て", isSelected: store.shopProcessFilter == nil) {
                    store.shopProcessFilter = nil
                }
                ForEach(ProcessType.allCases) { process in
                    BuildProcessChip(title: process.shortName, isSelected: store.shopProcessFilter == process) {
                        store.shopProcessFilter = process
                    }
                }
                Spacer(minLength: 8)
                Text("資金 \(MoneyFormat.yen(store.state.cashYen))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct BuildProcessChip: View {
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

/// 購入タブのモデルタイル（サムネ・名前・価格・公称WPH・所持台数・ロック理由。「i」で From→To を展開）
private struct BuildModelTile: View {
    @EnvironmentObject private var store: GameStore
    let model: EquipmentModel
    let isExpanded: Bool
    let onToggleInfo: () -> Void
    let onSelect: () -> Void

    var body: some View {
        let state = store.state
        let block = Engine.buyBlockReason(state: state, modelId: model.id)
        let isLocked = Self.isLockedOut(block)
        let isShort: Bool = {
            if case .insufficientCash? = block { return true }
            return false
        }()
        // 所持台数は設置中＋倉庫
        let owned = Engine.ownedCount(state: state, modelIds: [model.id])

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: onSelect) {
                    HStack(alignment: .center, spacing: 10) {
                        EquipmentThumbnail(model: model)
                            .frame(width: 48, height: 48)
                            .grayscale(isLocked ? 1 : 0)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.name)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                if isLocked {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 8) {
                                Text(MoneyFormat.yen(model.priceYen))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(isShort ? Color.red : Color.primary)
                                Text("公称 \(MoneyFormat.decimal(model.nominalWPH, digits: 0)) WPH")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("所持 \(owned)台")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .monospacedDigit()
                            if let message = Self.blockMessage(block) {
                                Label(message, systemImage: isLocked ? "lock" : "exclamationmark.circle")
                                    .font(.caption2)
                                    .foregroundStyle(isLocked ? Color.secondary : Color.red)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLocked)

                Button(action: onToggleInfo) {
                    Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text("\(model.name)の数値"))
            }

            if isExpanded {
                infoBlock(state: state, isLocked: isLocked)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground).opacity(0.85)))
        .opacity(isLocked ? 0.65 : 1)
    }

    /// 「i」の展開部（旧 ShopModelCard の数値部）
    @ViewBuilder
    private func infoBlock(state: GameState, isLocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("対応 \(supportedNodesText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isLocked {
                Text("ロック中のため、購入後の数値は表示できません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let node = Engine.currentNode(state: state)
                let unit = Engine.unitWPH(model: model, level: 1, state: state)
                let current = store.derived.lineWPH
                let predicted = Engine.lineWPHAfterAdding(state: state, modelId: model.id)
                detailRow("\(node.displayName)での1台実効WPH", MoneyFormat.decimal(unit, digits: 2))
                fromToRow("購入後ラインWPH",
                          from: MoneyFormat.decimal(current), to: MoneyFormat.decimal(predicted),
                          improved: predicted > current + 1e-9)
                if predicted <= current + 1e-9 {
                    Text("この工程はボトルネックではないため、ラインWPHは増えません")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let currentYield = store.derived.processYields[model.process] ?? 0
                let predictedYield = Engine.processYieldAfterAdding(state: state, modelId: model.id)
                fromToRow("購入後 工程歩留まり",
                          from: MoneyFormat.percent(currentYield), to: MoneyFormat.percent(predictedYield),
                          improved: predictedYield > currentYield + 1e-9)
                if model.process == .inspection {
                    let currentDetection = store.derived.detectionRate
                    let predictedDetection = Engine.detectionRateAfterAdding(state: state, modelId: model.id)
                    fromToRow("購入後 検出率",
                              from: MoneyFormat.percent(currentDetection), to: MoneyFormat.percent(predictedDetection),
                              improved: predictedDetection > currentDetection + 1e-9)
                }
            }
        }
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
        .font(.caption)
    }

    /// From→To 行。改善時のみ緑
    private func fromToRow(_ title: String, from: String, to: String, improved: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(from) → \(to)")
                .monospacedDigit()
                .bold()
                .foregroundStyle(improved ? Color.green : Color.secondary)
        }
        .font(.caption)
    }

    /// ロック・不明な機種はゴースト配置へ進ませない（資金不足は進めて、確定ボタン側で止める §2.2-3）
    static func isLockedOut(_ reason: BuyBlockReason?) -> Bool {
        guard let reason else { return false }
        switch reason {
        case .locked, .unknownModel: return true
        default: return false
        }
    }

    static func blockMessage(_ reason: BuyBlockReason?) -> String? {
        guard let reason else { return nil }
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
}

// MARK: - 倉庫タブ

private struct BuildStorageTab: View {
    @EnvironmentObject private var store: GameStore
    @Binding var placement: PlacementRequest?
    var onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        let stored = store.state.fab.storedEquipment
        if stored.isEmpty {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "shippingbox")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("倉庫は空です")
                    .font(.subheadline.bold())
                Text("ToolCard の「倉庫へ」で外した装置がここに並びます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("タップするとマップ上で置く場所を選べます（設置は無料）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(stored) { instance in
                            Button {
                                placement = .stored(toolId: instance.id)
                                onClose()
                            } label: {
                                storedTile(instance)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func storedTile(_ instance: EquipmentInstance) -> some View {
        HStack(spacing: 8) {
            if let model = Catalog.model(id: instance.modelId) {
                EquipmentThumbnail(model: model)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.subheadline.bold())
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Lv\(instance.level)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            } else {
                Text("不明な装置（\(instance.modelId)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground).opacity(0.85)))
        .contentShape(Rectangle())
    }
}

// MARK: - レールタブ

private struct BuildRailTab: View {
    var onEnterRailMode: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("レールで装置どうしをつなぐと、FOUP が工程順に流れます", systemImage: "arrow.triangle.branch")
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("・新しく敷くと 1セル \(MoneyFormat.yen(Engine.railCellCostYen))。既存レールの向きの描き替えは無料")
                    Text("・撤去すると、お金を払って敷いたセルは \(MoneyFormat.yen(Engine.railCellCostYen)) を全額返金。最初から敷かれていた無償のセルは返金なし")
                    Text("・レールモードでは 1本指でなぞって敷設／消しゴム、2本指でフロアを動かします。「完了」で戻ります")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button(action: onEnterRailMode) {
                    Label("レールを引く", systemImage: "pencil.and.outline")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
    }
}

// MARK: - 撤去タブ

private struct BuildRemoveTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("撤去は装置のカードから行います", systemImage: "hand.tap")
                .font(.subheadline.bold())
            Text("マップ上の装置をタップすると、下にカードが出ます。カードの「倉庫へ」で外す（あとで置き直せます）、「売却」でモデル価格の50%を受け取れます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("レールの撤去は「レール」タブから消しゴムで行います。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 装置サムネ（建設ドロワー・ToolCard 共用）

/// ドット絵スプライトがある機種はスプライト、無い機種はベクタの EquipmentIllustration
struct EquipmentThumbnail: View {
    let model: EquipmentModel

    var body: some View {
        if let sprite = EquipmentSprites.meta(modelId: model.id) {
            Image(sprite.orientations.front.body.image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .accessibilityLabel(Text(model.name))
        } else {
            EquipmentIllustration(model: model)
        }
    }
}
