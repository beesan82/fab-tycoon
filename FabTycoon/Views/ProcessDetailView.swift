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

    private var instances: [EquipmentInstance] {
        store.state.fab.equipment.filter { Catalog.model(id: $0.modelId)?.process == process }
    }

    var body: some View {
        let state = store.state
        let derived = store.derived
        NavigationStack {
            List {
                Section {
                    infoRow("工程の実効WPH", "\(MoneyFormat.decimal(derived.wph(process), digits: 2)) WPH")
                    infoRow("稼働台数", "\(derived.units(process))台")
                    infoRow("パス数（\(Engine.currentNode(state: state).displayName)）", "\(passes(state: state))")
                    if derived.bottleneck == process {
                        Label("この工程がボトルネックです", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if derived.secondBottleneck == process {
                        Label("次のボトルネック候補です", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("装置") {
                    if instances.isEmpty {
                        Text("装置がありません。この工程が止まるとライン全体が停止します。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(instances) { instance in
                        EquipmentRow(instance: instance) {
                            pendingSell = instance
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
        let after = Engine.lineWPHAfterSelling(state: state, instanceId: instance.id)
        var text = "返金はモデル価格の50%です（改良投資分は戻りません）。\nラインWPH \(MoneyFormat.decimal(derived.lineWPH)) → \(MoneyFormat.decimal(after))"
        if after <= 0 {
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

    var body: some View {
        let state = store.state
        if let model = Catalog.model(id: instance.modelId) {
            let unit = Engine.unitWPH(model: model, level: instance.level, state: state)
            let cost = Engine.upgradeCostYen(state: state, instance: instance)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.name)
                        .font(.headline)
                    Spacer()
                    Text("Lv\(instance.level)")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Text("1台あたり実効 \(MoneyFormat.decimal(unit, digits: 2)) WPH（稼働率適用前）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let cost {
                        let after = Engine.lineWPHAfterUpgrading(state: state, instanceId: instance.id)
                        Button {
                            store.upgrade(instance.id)
                        } label: {
                            VStack(spacing: 2) {
                                Text("改良 \(MoneyFormat.yen(cost))")
                                Text("ライン → \(MoneyFormat.decimal(after))")
                                    .font(.caption2)
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
                }
            }
            .padding(.vertical, 4)
        } else {
            Text("不明な装置（\(instance.modelId)）")
                .foregroundStyle(.secondary)
        }
    }
}
