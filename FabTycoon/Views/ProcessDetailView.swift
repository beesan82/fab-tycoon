import SwiftUI

struct ProcessDetailView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    let process: ProcessType
    /// ショップへ遷移（フィルタとタブの書き換えは呼び出し側）
    let onAddEquipment: () -> Void

    @State private var pendingSell: EquipmentInstance?

    init(process: ProcessType, onAddEquipment: @escaping () -> Void) {
        self.process = process
        self.onAddEquipment = onAddEquipment
    }

    /// 設置中の装置（この工程分）
    private var instances: [EquipmentInstance] {
        store.state.fab.equipment.filter { Catalog.model(id: $0.modelId)?.process == process }
    }

    /// 倉庫の装置（この工程分）
    private var storedInstances: [EquipmentInstance] {
        store.state.fab.storedEquipment.filter { Catalog.model(id: $0.modelId)?.process == process }
    }

    var body: some View {
        let state = store.state
        let derived = store.derived
        NavigationStack {
            List {
                Section("工程について") {
                    Text(process.educationText)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(process.connectionNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(process.realDurationText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    infoRow("工程の実効WPH", "\(MoneyFormat.decimal(derived.wph(process), digits: 2)) WPH")
                    infoRow("稼働台数", "\(derived.units(process))台")
                    let standby = Engine.standbyCount(state: state, process: process)
                    if standby > 0 {
                        infoRow("待機台数", "\(standby)台")
                    }
                    infoRow("パス数（\(Engine.currentNode(state: state).displayName)）", "\(passes(state: state))")
                    infoRow("工程歩留まり", MoneyFormat.percent(derived.processYields[process] ?? 0))
                    if process == .inspection {
                        infoRow("検査検出率", MoneyFormat.percent(derived.detectionRate))
                    }
                    if derived.bottleneck == process {
                        Label("この工程がボトルネックです", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if derived.secondBottleneck == process {
                        Label("次のボトルネック候補です", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("設置中の装置") {
                    if instances.isEmpty {
                        Text("装置がありません。この工程が止まるとライン全体が停止します。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(instances) { instance in
                        EquipmentRow(
                            instance: instance,
                            onSell: { pendingSell = instance },
                            onDetach: { store.detachEquipment(instance.id) }
                        )
                    }
                }

                if !storedInstances.isEmpty {
                    Section("倉庫の装置") {
                        ForEach(storedInstances) { instance in
                            StoredEquipmentRow(instance: instance) {
                                pendingSell = instance
                            }
                        }
                    }
                }

                Section {
                    Button {
                        onAddEquipment()
                    } label: {
                        Label("この工程に装置を追加", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle(process.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
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
                    pendingSell = nil
                }
                Button("キャンセル", role: .cancel) {
                    pendingSell = nil
                }
            } message: { instance in
                Text(sellMessage(for: instance, state: state, derived: derived))
            }
        }
    }

    private func passes(state: GameState) -> Int {
        Engine.passCount(
            for: process,
            node: Engine.currentNode(state: state),
            topLitho: Engine.topLithoClass(state: state)
        )
    }

    private func sellMessage(for instance: EquipmentInstance, state: GameState, derived: DerivedState) -> String {
        if state.fab.storedEquipment.contains(where: { $0.id == instance.id }) {
            return "返金はモデル価格の50%です。倉庫の装置はラインに影響していないため、売却してもラインWPH・歩留まりは変わりません。"
        }
        let after = Engine.lineWPHAfterSelling(state: state, instanceId: instance.id)
        let yieldAfter = Engine.processYieldAfterSelling(state: state, instanceId: instance.id)
        var text = "返金はモデル価格の50%です（改良投資分は戻りません）。\nラインWPH \(MoneyFormat.decimal(derived.lineWPH)) → \(MoneyFormat.decimal(after))"
        text += "\n工程歩留まり \(MoneyFormat.percent(derived.processYields[process] ?? 0)) → \(MoneyFormat.percent(yieldAfter))"
        if process == .inspection {
            let detectionAfter = Engine.detectionRateAfterSelling(state: state, instanceId: instance.id)
            text += "\n検出率 \(MoneyFormat.percent(derived.detectionRate)) → \(MoneyFormat.percent(detectionAfter))"
        }
        // 稼働装置が0台になる売却は強く警告し、買い戻せない場合は詰みを明示する
        let unitsAfter = Engine.activeUnitsAfterSelling(state: state, instanceId: instance.id)
        if derived.units(process) > 0 && unitsAfter == 0 {
            text += "\n\n⚠️ この装置を売ると\(process.displayName)の装置が0台になり、ラインが停止します。"
            let cashAfter = state.cashYen + Engine.sellRefundYen(instance: instance)
            if let cheapest = Engine.cheapestModelPriceYen(state: state, process: process), cashAfter < cheapest {
                text += "\n買い戻す資金も足りません（最安機種 \(MoneyFormat.yen(cheapest))）。このままだと詰みます（止まったラインは統計画面の緊急救済の補助金で立て直せます）。"
            }
        } else if after <= 0 {
            text += "\nこの工程の装置がなくなり、ラインが停止します。"
        }
        return text
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 装置行

private struct EquipmentRow: View {
    @EnvironmentObject private var store: GameStore
    let instance: EquipmentInstance
    let onSell: () -> Void
    let onDetach: () -> Void

    var body: some View {
        let state = store.state
        let derived = store.derived
        if let model = Catalog.model(id: instance.modelId) {
            let unit = Engine.unitWPH(model: model, level: instance.level, state: state)
            let cost = Engine.upgradeCostYen(state: state, instance: instance)
            let isStandby = Engine.isStandby(instance, state: state)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    EquipmentIllustration(model: model)
                        .frame(width: 76, height: 76)
                        .grayscale(isStandby ? 1 : 0)
                        .opacity(isStandby ? 0.5 : 1)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Text(model.name)
                                .font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text("Lv\(instance.level)")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        Text(isStandby
                             ? "1台あたり実効 0.00 WPH（待機中）"
                             : "1台あたり実効 \(MoneyFormat.decimal(unit, digits: 2)) WPH（稼働率適用前）")
                            .font(.caption)
                            .foregroundStyle(isStandby ? Color.orange : Color.secondary)
                    }
                }
                if isStandby {
                    Label("待機中：現在のノード（\(Engine.currentNode(state: state).displayName)）では稼働しません。スロットを空けるなら倉庫へ外しましょう。",
                          systemImage: "pause.circle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let education = Catalog.education(for: model.id) {
                    EquipmentEducationBlock(education: education)
                }
                HStack(spacing: 8) {
                    if let cost {
                        let after = Engine.lineWPHAfterUpgrading(state: state, instanceId: instance.id)
                        let yieldAfter = Engine.processYieldAfterUpgrading(state: state, instanceId: instance.id)
                        Button {
                            store.upgrade(instance.id)
                        } label: {
                            VStack(spacing: 2) {
                                Text("改良 \(MoneyFormat.yen(cost))")
                                Text("ライン → \(MoneyFormat.decimal(after))")
                                    .font(.caption2)
                                Text("工程歩留まり \(MoneyFormat.percent(derived.processYields[model.process] ?? 0)) → \(MoneyFormat.percent(yieldAfter))")
                                    .font(.caption2)
                                if model.process == .inspection {
                                    let detectionAfter = Engine.detectionRateAfterUpgrading(state: state, instanceId: instance.id)
                                    Text("検出率 \(MoneyFormat.percent(derived.detectionRate)) → \(MoneyFormat.percent(detectionAfter))")
                                        .font(.caption2)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.cashYen < cost)
                    } else {
                        Button {} label: {
                            Text("最大")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(true)
                    }
                    Button(role: .destructive) {
                        onSell()
                    } label: {
                        VStack(spacing: 2) {
                            Text("売却")
                            Text("+\(MoneyFormat.yen(Engine.sellRefundYen(instance: instance)))")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if isStandby {
                        // 待機中の装置はスロットを塞ぐだけなので、外す操作を目立たせる
                        Button {
                            onDetach()
                        } label: {
                            Text("倉庫へ外す")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    } else {
                        Button {
                            onDetach()
                        } label: {
                            Text("倉庫へ外す")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 4)
        } else {
            Text("不明な装置（\(instance.modelId)）")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 倉庫の装置行

private struct StoredEquipmentRow: View {
    @EnvironmentObject private var store: GameStore
    let instance: EquipmentInstance
    let onSell: () -> Void

    var body: some View {
        let canAttach = store.state.fab.freeSlots > 0
        if let model = Catalog.model(id: instance.modelId) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    EquipmentIllustration(model: model)
                        .frame(width: 44, height: 44)
                    Text(model.name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text("Lv\(instance.level)")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                HStack(spacing: 8) {
                    Button {
                        store.attachEquipment(instance.id)
                    } label: {
                        Text("設置する")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAttach)
                    Button(role: .destructive) {
                        onSell()
                    } label: {
                        VStack(spacing: 2) {
                            Text("売却")
                            Text("+\(MoneyFormat.yen(Engine.sellRefundYen(instance: instance)))")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                if !canAttach {
                    Text("空きスロットがありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } else {
            Text("不明な装置（\(instance.modelId)）")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - この装置について

private struct EquipmentEducationBlock: View {
    let education: EquipmentEducation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("この装置について")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(education.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(education.mechanism)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Label("豆知識", systemImage: "lightbulb.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text(education.trivia)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("代表メーカー：\(education.makers.joined(separator: "、"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill)))
    }
}
