import SwiftUI

struct LineView: View {
    @EnvironmentObject private var store: GameStore
    @State private var selectedProcess: ProcessType?

    var body: some View {
        let state = store.state
        let derived = store.derived
        let node = Engine.currentNode(state: state)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary(state: state, derived: derived, node: node)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("工程")
                        .font(.headline)
                        .padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ProcessType.allCases) { process in
                                Button {
                                    selectedProcess = process
                                } label: {
                                    ProcessCardView(
                                        process: process,
                                        units: derived.units(process),
                                        wph: derived.wph(process),
                                        maxWPH: derived.maxProcessWPH,
                                        rank: rank(of: process, in: derived)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                }

                inventoryRow(state: state, derived: derived)
                    .padding(.horizontal)

                if let next = Catalog.nextNode(after: node.id) {
                    lockBanner(next: next)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(item: $selectedProcess) { process in
            ProcessDetailView(process: process) {
                selectedProcess = nil
                store.openShop(for: process)
            }
            .environmentObject(store)
        }
    }

    // MARK: 概要

    private func summary(state: GameState, derived: DerivedState, node: NodeSpec) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.fab.name)
                    .font(.title3.bold())
                Spacer()
                statusLabel(state: state, derived: derived)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ラインWPH")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MoneyFormat.decimal(derived.lineWPH, digits: 2))
                        .font(.title.bold())
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("歩留まり")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MoneyFormat.percent(derived.currentYield))
                        .font(.title.bold())
                        .monospacedDigit()
                    if derived.isLearning {
                        let learned = state.learningWafers[node.id] ?? 0
                        Text("学習中（累計\(MoneyFormat.count(learned))枚）")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Text("学習完了")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
            }
            Text("単価 \(MoneyFormat.yen(derived.currentPriceYen))／個")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func statusLabel(state: GameState, derived: DerivedState) -> some View {
        if derived.lineWPH <= 0 {
            Label("停止中：装置ゼロの工程あり", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
        } else if !state.fab.running {
            Label("停止中：材料費不足", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
        } else {
            Label("稼働中", systemImage: "circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
        }
    }

    // MARK: 在庫

    private func inventoryRow(state: GameState, derived: DerivedState) -> some View {
        let inventory = state.fab.inventoryChips
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("在庫")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(MoneyFormat.count(inventory)) / \(MoneyFormat.count(Engine.inventoryCap)) 個")
                        .font(.headline)
                        .monospacedDigit()
                }
                Spacer()
                Toggle("自動販売", isOn: Binding(
                    get: { store.state.fab.autoSellEnabled },
                    set: { _ in store.toggleAutoSell() }
                ))
                .fixedSize()
            }
            Button {
                store.sellAllInventory()
            } label: {
                Text("一括売却（\(MoneyFormat.yen(inventory * derived.currentPriceYen))）")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(inventory < 1)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: ロックバナー

    private func lockBanner(next: NodeSpec) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(next.displayName)はスライス2で解放")
                    .font(.subheadline.bold())
                Text("研究ツリーとノード移行は次のスライスで実装予定です")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.secondary)
        )
    }

    private func rank(of process: ProcessType, in derived: DerivedState) -> BottleneckRank {
        if derived.bottleneck == process { return .primary }
        if derived.secondBottleneck == process { return .secondary }
        return .normal
    }
}

// MARK: - 工程カード

enum BottleneckRank {
    case normal
    case primary
    case secondary
}

struct ProcessCardView: View {
    let process: ProcessType
    let units: Int
    let wph: Double
    let maxWPH: Double
    let rank: BottleneckRank

    private var loadRatio: Double {
        guard maxWPH > 0 else { return 0 }
        return min(max(wph / maxWPH, 0), 1)
    }

    private var accent: Color {
        switch rank {
        case .primary: return .red
        case .secondary: return .yellow
        case .normal: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: process.symbolName)
                Text(process.shortName)
                    .font(.headline)
                    .lineLimit(1)
            }
            Text("\(units)台")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(MoneyFormat.decimal(wph, digits: 2))
                .font(.title3.bold())
                .monospacedDigit()
            + Text(" WPH")
                .font(.caption)
                .foregroundColor(.secondary)
            ProgressView(value: loadRatio)
                .tint(accent)
            Group {
                switch rank {
                case .primary:
                    Text("ボトルネック")
                        .foregroundStyle(.red)
                case .secondary:
                    Text("次のボトルネック")
                        .foregroundStyle(.orange)
                case .normal:
                    Text(" ")
                }
            }
            .font(.caption.bold())
        }
        .padding(12)
        .frame(width: 140, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(accent, lineWidth: rank == .normal ? 0 : 3)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

extension ProcessType {
    var symbolName: String {
        switch self {
        case .lithography: return "sun.max.fill"
        case .deposition: return "square.stack.3d.up.fill"
        case .etching: return "scissors"
        case .implant: return "bolt.fill"
        case .cmp: return "arrow.triangle.2.circlepath"
        case .inspection: return "magnifyingglass"
        case .packaging: return "shippingbox.fill"
        }
    }
}
