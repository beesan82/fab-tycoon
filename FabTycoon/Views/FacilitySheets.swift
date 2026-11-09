import SwiftUI

// MARK: - 施設シート（R1 マップ中心）
// 設計書 design/simcity-rebuild.md §1.3・§1.5・§5.1。施設＝建物に入る、なので .sheet で出す。
// 中身は既存 View の流用が基本（事務所＝StatsView、研究棟＝ResearchView、資料室＝GlossaryView）。
// 投入口（EntrySheet）と出荷口（ShippingSheet）は旧 LineView のノード節・出荷カードをここへ移した自己完結版。

enum FacilitySheetKind: String, Identifiable, Hashable {
    case office, research, library, entry, shipping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .office: return "事務所"
        case .research: return "研究棟"
        case .library: return "資料室"
        case .entry: return "投入口"
        case .shipping: return "出荷口"
        }
    }
}

/// シートの出し分け対象に使う文字列 ID の包み（.sheet(item:) 用）
private struct FacilityStringTarget: Identifiable {
    let id: String
}

struct FacilitySheetView: View {
    @EnvironmentObject private var store: GameStore

    let kind: FacilitySheetKind
    /// 資料室を開くときに詳細を出す図鑑エントリ（ToolCard の「図鑑で読む」から）
    var glossaryTargetId: String? = nil

    var body: some View {
        switch kind {
        case .office:
            FacilityNavigation(title: kind.title) {
                StatsView()
            }
        case .research:
            FacilityNavigation(title: kind.title) {
                ResearchView()
            }
            .onAppear { store.markResearchCompletionSeen() }
        case .library:
            LibrarySheet(targetId: glossaryTargetId)
        case .entry:
            FacilityNavigation(title: kind.title) {
                EntrySheet()
            }
        case .shipping:
            FacilityNavigation(title: kind.title) {
                ShippingSheet()
            }
        }
    }
}

/// NavigationStack＋見出し＋「閉じる」の共通枠
private struct FacilityNavigation<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - 資料室

/// GlossaryView は自前の NavigationStack を持ち、パスを外から渡せない（遷移先は navigationDestination(for: String)）。
/// GlossaryView を変えずに済ませるため、建物名と「閉じる」は上に帯で出し、
/// 開くエントリの指定があれば図鑑の上に詳細をもう 1 枚シートで重ねる（閉じると図鑑一覧に戻る）
private struct LibrarySheet: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    let targetId: String?

    @State private var detailTarget: FacilityStringTarget?
    @State private var didOpenTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(FacilitySheetKind.library.title)
                    .font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            GlossaryView()
        }
        .task {
            guard !didOpenTarget else { return }
            didOpenTarget = true
            // 未解放のエントリは本文を見せない（GlossaryView の一覧と同じ扱い）
            guard let targetId,
                  Engine.glossaryEntries(state: store.state).contains(where: { $0.id == targetId && $0.unlocked })
            else { return }
            // 資料室シートの表示アニメーションが終わってから重ねる
            try? await Task.sleep(for: .seconds(0.35))
            detailTarget = FacilityStringTarget(id: targetId)
        }
        .sheet(item: $detailTarget) { target in
            GlossaryDetailSheet(entryId: target.id)
                .environmentObject(store)
        }
    }
}

private struct GlossaryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let entryId: String

    var body: some View {
        NavigationStack {
            GlossaryDetailView(entryId: entryId)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("図鑑へ") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - 投入口

/// ノード（移行・戻す・排出中のキャンセル）、製品の切替、歩留まりの学習枚数（§1.3）
struct EntrySheet: View {
    @EnvironmentObject private var store: GameStore

    @State private var nodeSwitchTarget: FacilityStringTarget?

    var body: some View {
        let state = store.state
        let derived = store.derived
        let node = Engine.currentNode(state: state)
        List {
            nodeSection(state: state, node: node)
            productSection(state: state)
            learningSection(state: state, derived: derived, node: node)
        }
        .sheet(item: $nodeSwitchTarget) { target in
            NodeSwitchSheet(targetNodeId: target.id)
                .environmentObject(store)
        }
    }

    // MARK: ノード（旧 LineView.nodeSection・floorBanners の排出中バナー）

    private func previousNode(before id: String) -> NodeSpec? {
        guard let index = Catalog.nodes.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return Catalog.nodes[index - 1]
    }

    @ViewBuilder
    private func nodeSection(state: GameState, node: NodeSpec) -> some View {
        let next = Catalog.nextNode(after: node.id)
        let previous = previousNode(before: node.id)
        Section("ノード") {
            HStack(spacing: 8) {
                BadgeView(text: "現在 \(node.displayName)", systemImage: "cpu", color: .blue)
                if let next {
                    BadgeView(text: "次 \(next.displayName)", systemImage: nil, color: .gray)
                }
                Spacer()
            }
            if let pendingNodeId = state.fab.nodeSwitch.pendingNodeId {
                let name = Catalog.node(id: pendingNodeId)?.displayName ?? pendingNodeId
                VStack(alignment: .leading, spacing: 8) {
                    Label("排出中：仕掛かりが流れ切ったら \(name) へ切り替えます", systemImage: "hourglass")
                        .font(.subheadline.bold())
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("切替をやめる") {
                        store.cancelNodeSwitch()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            if let next {
                if Engine.canSwitchNode(state: state, toNodeId: next.id) {
                    Button {
                        nodeSwitchTarget = FacilityStringTarget(id: next.id)
                    } label: {
                        Label("\(next.displayName)へ移行", systemImage: "arrow.up.forward.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    lockBanner(next: next, state: state)
                }
            }
            if let previous, Engine.canSwitchNode(state: state, toNodeId: previous.id) {
                Button {
                    nodeSwitchTarget = FacilityStringTarget(id: previous.id)
                } label: {
                    Label("\(previous.displayName)へ戻す", systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func lockBanner(next: NodeSpec, state: GameState) -> some View {
        let researchName = Engine.nodeUnlockResearch(nodeId: next.id)?.name
        let needsResearch = Catalog.isPlayable(nodeId: next.id) && !Engine.isNodeUnlocked(state: state, nodeId: next.id)
        let title = needsResearch ? "\(next.displayName)は研究で解放" : "\(next.displayName)は今後のアップデートで解放"
        let detail = needsResearch
            ? "研究棟で『\(researchName ?? "\(next.displayName)プロセス")』を完了すると移行できます"
            : "次のノードは今後のアップデートで解放されます"
        return HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: 製品（ProductsView の製品カード相当の簡易版。比較の詳細は ProductsView へ）

    @ViewBuilder
    private func productSection(state: GameState) -> some View {
        let currentProduct = Engine.currentProduct(state: state)
        Section {
            HStack {
                Text("製造中")
                Spacer()
                Text(currentProduct.name)
                    .foregroundStyle(.secondary)
            }
            ForEach(Catalog.products.filter { $0.id != state.currentProductId }) { product in
                productRow(product, state: state)
            }
            NavigationLink {
                ProductsView()
                    .navigationTitle("製品")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Text("単価・歩留まりを比べる")
            }
        } header: {
            Text("製品")
        }
    }

    private func productRow(_ product: ProductSpec, state: GameState) -> some View {
        let reasons = Engine.productBlockReasons(state: state, productId: product.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.name)
                    .font(.headline)
                Spacer()
                Text("ダイ単価 \(MoneyFormat.yen(Engine.diePriceYen(state: state, productId: product.id)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button {
                _ = store.switchProduct(product.id)
            } label: {
                Text("この製品に切り替える")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!reasons.isEmpty)
            if !reasons.isEmpty {
                Text(reasons.joined(separator: "／"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 学習枚数（state.learningWafers と DerivedState の学習値）

    @ViewBuilder
    private func learningSection(state: GameState, derived: DerivedState, node: NodeSpec) -> some View {
        let learned = state.learningWafers[node.id] ?? 0
        let span = node.yieldMax - node.yieldInit
        let progress = span > 0 ? min(max((derived.learnedYield - node.yieldInit) / span, 0), 1) : 1
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(node.displayName)の学習")
                    Spacer()
                    if derived.isLearning {
                        Text("学習中")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    } else {
                        Text("学習完了")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }
                }
                ProgressView(value: progress)
                    .tint(derived.isLearning ? .orange : .green)
                Text("学習による歩留まり \(MoneyFormat.percent(derived.learnedYield))（初期 \(MoneyFormat.percent(node.yieldInit)) → 上限 \(MoneyFormat.percent(node.yieldMax))）")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            row("このノードで流した枚数", "\(MoneyFormat.count(learned)) 枚")
            row("累計投入ウェハ（全ノード）", "\(MoneyFormat.decimal(state.stats.totalWafersInput, digits: 1)) 枚")
        } header: {
            Text("歩留まりの学習")
        } footer: {
            Text("新しいノードはウェハを流すほど欠陥が減り、歩留まりが上がります。ノードごとの学習枚数は、移行して戻しても保持されます。")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 出荷口

/// 完成品在庫・自動販売・一括売却（旧 LineView.shippingCard）、単価・市況、歩留まりの要約（§1.3）
struct ShippingSheet: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        let state = store.state
        let derived = store.derived
        let inventory = state.fab.inventoryChips
        let fill = Engine.inventoryCap > 0 ? min(max(inventory / Engine.inventoryCap, 0), 1) : 0
        List {
            Section("完成チップ在庫") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(MoneyFormat.count(inventory)) / \(MoneyFormat.count(Engine.inventoryCap)) 個")
                        .font(.headline)
                        .monospacedDigit()
                    ProgressView(value: fill)
                        .tint(fill > 0.9 ? .orange : .blue)
                }
                .padding(.vertical, 4)
                Toggle("自動販売", isOn: Binding(
                    get: { store.state.fab.autoSellEnabled },
                    set: { _ in store.toggleAutoSell() }
                ))
                Button {
                    _ = store.sellAllInventory()
                } label: {
                    Text("一括売却（\(MoneyFormat.yen(Engine.inventorySaleValueYen(state: state, priceYen: derived.currentPriceYen)))）")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(inventory < 1)
            }

            Section("価格と市況") {
                row("チップ単価", "\(MoneyFormat.yen(derived.currentPriceYen))／個")
                HStack {
                    Text("市況")
                    Spacer()
                    BadgeView(text: derived.marketCondition.label,
                              systemImage: derived.marketCondition.symbolName,
                              color: derived.marketCondition.color)
                }
                row("市況指数", MoneyFormat.decimal(derived.marketIndex, digits: 2))
            }

            Section {
                row("ライン歩留まり（検査前）", MoneyFormat.percent(derived.lineYield))
                row("検査検出率", MoneyFormat.percent(derived.detectionRate))
                row("出荷良品率", MoneyFormat.percent(derived.shippedYield))
                row("市場不良率", MoneyFormat.percent(derived.marketDefectRate))
            } header: {
                Text("歩留まり")
            } footer: {
                Text("工程ごとの歩留まりと内訳（学習・製品倍率・検出率の成り立ち）は事務所の「歩留まり」で確認できます。")
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ようこそカード（旧セーブ初回、§5.3）

struct WelcomeCardView: View {
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "map.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
            Text("画面がマップ中心になりました")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                guideRow("hand.tap.fill", "装置はタップで情報、長押しで移動などの操作")
                guideRow("plus.circle.fill", "建設は画面下の＋ボタンから")
                guideRow("building.2.fill", "事務所・研究棟・資料室はフロア北側の建物に")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Text("見て回る")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))
        .padding(16)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func guideRow(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
                .frame(width: 24)
        }
    }
}

// MARK: - ノード移行確認シート

struct NodeSwitchSheet: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    let targetNodeId: String

    @State private var mode: NodeSwitchMode = .drain

    init(targetNodeId: String) {
        self.targetNodeId = targetNodeId
    }

    var body: some View {
        let state = store.state
        let from = store.derived
        let wipLots = state.fab.sim?.lots.count ?? 0
        let to = Engine.derived(state: state, asNode: targetNodeId)
        let fromNode = Engine.currentNode(state: state)
        let target = Catalog.node(id: targetNodeId) ?? Catalog.defaultNode
        let warnings = Engine.nodeSwitchWarnings(state: state, toNodeId: targetNodeId)
        let willStop = !Engine.stoppedProcesses(state: state, atNode: targetNodeId).isEmpty
        let blockReason = Engine.nodeSwitchBlockReason(state: state, toNodeId: targetNodeId)
        let fromLearned = state.learningWafers[fromNode.id] ?? 0
        let targetLearned = state.learningWafers[target.id] ?? 0
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Text(fromNode.displayName)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Text(target.displayName)
                            .foregroundStyle(.blue)
                    }
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                }

                Section("移行前 → 移行後") {
                    fromToRow("ラインWPH",
                              from: MoneyFormat.decimal(from.lineWPH, digits: 2),
                              to: MoneyFormat.decimal(to.lineWPH, digits: 2),
                              improved: to.lineWPH > from.lineWPH + 1e-9)
                    fromToRow("歩留まり",
                              from: MoneyFormat.percent(from.lineYield),
                              to: MoneyFormat.percent(to.lineYield),
                              improved: to.lineYield > from.lineYield + 1e-9)
                    fromToRow("収入/分",
                              from: MoneyFormat.signedYen(from.incomePerMinuteYen),
                              to: MoneyFormat.signedYen(to.incomePerMinuteYen),
                              improved: to.incomePerMinuteYen > from.incomePerMinuteYen + 1e-9)
                    fromToRow("検出率",
                              from: MoneyFormat.percent(from.detectionRate),
                              to: MoneyFormat.percent(to.detectionRate),
                              improved: to.detectionRate > from.detectionRate + 1e-9)
                }

                if willStop || !warnings.isEmpty {
                    Section("注意") {
                        if willStop {
                            Label("移行直後はラインが停止します", systemImage: "exclamationmark.octagon.fill")
                                .font(.headline)
                                .foregroundStyle(.red)
                        }
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Section("歩留まりの学習") {
                    Text(targetLearned > 0
                         ? "\(target.displayName)では、これまでに流した累計\(MoneyFormat.count(targetLearned))枚分の学習から再開します。"
                         : "\(target.displayName)では歩留まりが初期値 \(MoneyFormat.percent(target.yieldInit)) から学習し直しになります。新しいノードはウェハを流すほど歩留まりが上がります。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(fromNode.displayName)の学習進捗（累計\(MoneyFormat.count(fromLearned))枚）は保持され、戻したときはそこから再開します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Picker("移行の方式", selection: $mode) {
                        Text("排出モード（仕掛かりを流し切ってから切替）").tag(NodeSwitchMode.drain)
                        Text("今すぐ切替（仕掛かりは廃棄）").tag(NodeSwitchMode.immediate)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("移行の方式")
                } footer: {
                    Text(mode == .drain
                         ? "投入を止め、ライン上の\(wipLots)ロットが出荷されたら切り替えます。その間もラインは動き続けます。"
                         : "ライン上の\(wipLots)ロットは廃棄され、すぐに切り替わります。")
                }

                Section {
                    Button {
                        store.switchNode(targetNodeId, mode: mode)
                        dismiss()
                    } label: {
                        Text("移行する")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(blockReason != nil)
                    if let blockReason {
                        Text(blockReason)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button(role: .cancel) {
                        dismiss()
                    } label: {
                        Text("キャンセル")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .navigationTitle("\(target.displayName)へ移行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
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
        .font(.subheadline)
    }
}

// MARK: - 欠陥分析シート

struct DefectAnalysisSheet: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProcess: ProcessType?
    /// 解決直後に表示する異常（解決すると activeExcursion が消えるので保持しておく）
    @State private var resolvedSpec: ExcursionSpec?
    @State private var wrongMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let resolvedSpec {
                    resolvedSection(resolvedSpec)
                } else if let excursion = store.state.activeExcursion,
                          let spec = Catalog.excursion(id: excursion.specId) {
                    overviewSection(excursion: excursion, spec: spec)
                    hintSection(excursion: excursion, spec: spec)
                    countermeasureSection(spec: spec)
                } else {
                    Text("現在、歩留まり異常は発生していません。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("欠陥分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    // MARK: 解決

    private func resolvedSection(_ spec: ExcursionSpec) -> some View {
        Section("解決しました") {
            Label("歩留まり異常は解消しました", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("原因")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(spec.causeName)
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("実施した対策")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(spec.countermeasureTitle)
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("学習ノート")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(spec.learningNote)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 概要

    private func overviewSection(excursion: ActiveExcursion, spec: ExcursionSpec) -> some View {
        Section("異常の概要") {
            row("発生", "Day \(Int(excursion.startedAtGameHours / 24) + 1)")
            Text(spec.symptom)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            row("ライン歩留まりへの影響", "−\(MoneyFormat.decimal(store.derived.excursionYieldLoss * 100, digits: 1))pt")
            if excursion.wrongGuesses > 0 {
                row("外した対策", "\(excursion.wrongGuesses) 回")
            }
        }
    }

    // MARK: ヒント

    private func hintSection(excursion: ActiveExcursion, spec: ExcursionSpec) -> some View {
        let hints = [spec.stage1Hint, spec.stage2Hint, spec.stage3Hint]
        let revealed = min(max(excursion.hintsRevealed, 0), hints.count)
        let hintCost = Engine.excursionHintCostYen(state: store.state)
        let gradeText: String
        switch Engine.bestInspectionGrade(state: store.state) {
        case 1: gradeText = "Q1（光学）"
        case 2: gradeText = "Q2（電子ビーム）"
        case 3: gradeText = "Q3（AI分類）"
        default: gradeText = "なし"
        }
        return Section("ヒント") {
            ForEach(0..<revealed, id: \.self) { index in
                Label(hints[index], systemImage: "\(index + 1).circle.fill")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if excursion.hintsRevealed >= 1 {
                row("候補工程", Engine.excursionCandidates(state: store.state).map { $0.displayName }.joined(separator: "・"))
            }
            if excursion.hintsRevealed >= 3, Engine.bestInspectionGrade(state: store.state) == 3,
               let causeToolId = excursion.causeToolId, let causeName = causeToolName(causeToolId) {
                Label("\(causeName) を通ったロットだけ歩留まりが落ちています", systemImage: "scope")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if excursion.hintsRevealed < 3 {
                Button {
                    store.revealExcursionHint()
                } label: {
                    Text("さらに分析する（\(MoneyFormat.yen(hintCost))）")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(store.state.cashYen < hintCost)
            }
            Text("検査グレードが高いほど、ヒントで候補を絞り込めます（現在：\(gradeText)）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 原因装置の表示名（「E1 #2（モデル名）」：同モデルの設置順の連番）。設置されていなければ nil
    private func causeToolName(_ toolId: UUID) -> String? {
        let installed = Engine.installedTools(state: store.state)
        guard let tool = installed.first(where: { $0.id == toolId }) else { return nil }
        let sameModel = installed.filter { $0.modelId == tool.modelId }
        let number = (sameModel.firstIndex(where: { $0.id == toolId }) ?? 0) + 1
        let name = Catalog.model(id: tool.modelId)?.name ?? tool.modelId
        return "\(tool.modelId) #\(number)（\(name)）"
    }

    // MARK: 対策

    private func countermeasureSection(spec: ExcursionSpec) -> some View {
        let candidates = Engine.excursionCandidates(state: store.state)
        let cost = Engine.excursionCountermeasureCostYen(state: store.state)
        return Section("対策") {
            ForEach(candidates) { process in
                Button {
                    selectedProcess = process
                } label: {
                    HStack {
                        Text(process.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedProcess == process {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("原因と思われる工程を1つ選んで対策を実行します。当たれば異常は解消し、外せば費用だけ失われて異常は続きます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                guard let selected = selectedProcess else { return }
                switch store.applyExcursionCountermeasure(selected) {
                case .resolved:
                    wrongMessage = nil
                    resolvedSpec = spec
                case .wrongProcess:
                    wrongMessage = "\(selected.displayName)を点検しましたが、異常は解消しませんでした"
                case .insufficientCash:
                    wrongMessage = "資金が不足しています"
                case .noActiveExcursion:
                    break
                }
            } label: {
                Text("対策を実行する（\(MoneyFormat.yen(cost))）")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            // ヒントで候補から外れた工程の選択は無効扱いにする
            .disabled(selectedProcess.map { !candidates.contains($0) } ?? true || store.state.cashYen < cost)
            if let wrongMessage {
                Text(wrongMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .bold()
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

// MARK: - 装置イラスト

/// 見下ろし視点の装置イラスト。内部は 100×100 座標系で描き、正方形にスケーリングする。
struct EquipmentIllustration: View {
    let model: EquipmentModel

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: side / 100, y: side / 100)
            EquipmentPainter(context: context, accent: model.process.accent)
                .draw(modelId: model.id, process: model.process)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(Text(model.name))
    }
}

/// 装置グリフの描画（100×100 座標系）。EquipmentIllustration と FloorGridView の Canvas が共用する
struct EquipmentPainter {
    let context: GraphicsContext
    let accent: Color

    static let housingColor = Color(white: 0.9)
    static let waferColor = Color(red: 0.72, green: 0.76, blue: 0.86)
    static let waterColor = Color(red: 0.2, green: 0.55, blue: 1.0)
    static let laserColor = Color.red

    // MARK: 基本部品

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func housing(_ r: CGRect, radius: CGFloat = 6) {
        let path = Path(roundedRect: r, cornerRadius: radius)
        context.fill(path, with: .color(Self.housingColor))
        context.fill(path, with: .color(accent.opacity(0.15)))
        context.stroke(path, with: .color(accent.opacity(0.7)), lineWidth: 1.5)
    }

    private func panel(_ r: CGRect, color: Color, radius: CGFloat = 2) {
        let path = Path(roundedRect: r, cornerRadius: radius)
        context.fill(path, with: .color(color))
        context.stroke(path, with: .color(Color.black.opacity(0.25)), lineWidth: 0.8)
    }

    private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, fill: Color? = nil, stroke: Color? = nil, lineWidth: CGFloat = 1.5) {
        let path = Path(ellipseIn: rect(x - r, y - r, r * 2, r * 2))
        if let fill {
            context.fill(path, with: .color(fill))
        }
        if let stroke {
            context.stroke(path, with: .color(stroke), lineWidth: lineWidth)
        }
    }

    private func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, color: Color, width: CGFloat = 1.5, dash: [CGFloat] = []) {
        var path = Path()
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
    }

    private func wafer(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        circle(x, y, r, fill: Self.waferColor, stroke: Color.gray, lineWidth: 1)
        circle(x - r * 0.3, y - r * 0.3, r * 0.3, fill: Color.white.opacity(0.5))
    }

    private func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, strength: Double) {
        let path = Path(ellipseIn: rect(x - r, y - r, r * 2, r * 2))
        let gradient = Gradient(colors: [Color.purple.opacity(strength), Color.blue.opacity(strength * 0.5), Color.blue.opacity(0)])
        context.fill(path, with: .radialGradient(gradient, center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
    }

    private func concentric(_ x: CGFloat, _ y: CGFloat, radii: [CGFloat], color: Color, lineWidth: CGFloat = 1.2) {
        for r in radii {
            circle(x, y, r, stroke: color, lineWidth: lineWidth)
        }
    }

    // MARK: 振り分け

    func draw(modelId: String, process: ProcessType) {
        switch modelId {
        case "L1": drawL1()
        case "L2": drawL2()
        case "L3": drawL3()
        case "L4": drawL4()
        case "D1": drawD1()
        case "D2": drawD2()
        case "D3": drawD3()
        case "E1": drawE1()
        case "E2": drawE2()
        case "E3": drawE3()
        case "I1": drawI1()
        case "I2": drawI2()
        case "C1": drawC1()
        case "C2": drawC2()
        case "Q1": drawQ1()
        case "Q2": drawQ2()
        case "Q3": drawQ3()
        case "P1": drawP1()
        case "P2": drawP2()
        case "P3": drawP3()
        default: drawDefault()
        }
    }

    private func drawDefault() {
        housing(rect(12, 22, 76, 56))
        circle(50, 50, 16, fill: accent.opacity(0.3), stroke: accent)
    }

    // MARK: 露光

    private func drawL1() {
        housing(rect(10, 22, 80, 56))
        concentric(50, 40, radii: [13, 8.5, 4], color: accent)
        circle(50, 40, 13, fill: accent.opacity(0.15))
        wafer(50, 64, 8)
    }

    private func drawL2() {
        housing(rect(5, 14, 90, 72))
        circle(50, 33, 14, fill: accent.opacity(0.15))
        concentric(50, 33, radii: [14, 9, 4.5], color: accent)
        // 水滴
        var drop = Path()
        drop.move(to: CGPoint(x: 50, y: 49))
        drop.addLine(to: CGPoint(x: 54, y: 56))
        drop.addLine(to: CGPoint(x: 46, y: 56))
        drop.closeSubpath()
        context.fill(drop, with: .color(Self.waterColor))
        circle(50, 57.5, 4.5, fill: Self.waterColor)
        wafer(50, 73, 9)
    }

    private func drawL3() {
        // 光源部
        housing(rect(3, 28, 28, 44), radius: 5)
        circle(17, 50, 7, fill: Color.orange.opacity(0.6), stroke: Color.orange)
        line(31, 50, 36, 50, color: accent, width: 3)
        // 本体
        housing(rect(36, 6, 60, 88), radius: 6)
        line(36, 50, 96, 50, color: accent.opacity(0.4), width: 1)
        // ミラー
        line(44, 18, 60, 36, color: accent, width: 4)
        line(60, 36, 74, 22, color: Color.purple.opacity(0.5), width: 1, dash: [2, 2])
        wafer(70, 72, 12)
    }

    private func drawL4() {
        // 光源部
        housing(rect(1, 22, 24, 56), radius: 5)
        circle(13, 40, 6, fill: Color.orange.opacity(0.6), stroke: Color.orange)
        circle(13, 60, 6, fill: Color.orange.opacity(0.6), stroke: Color.orange)
        line(25, 50, 28, 50, color: accent, width: 3)
        // 本体（分割多め）
        housing(rect(28, 1, 71, 98), radius: 6)
        line(28, 34, 99, 34, color: accent.opacity(0.4), width: 1)
        line(28, 66, 99, 66, color: accent.opacity(0.4), width: 1)
        line(63, 1, 63, 34, color: accent.opacity(0.4), width: 1)
        line(63, 66, 63, 99, color: accent.opacity(0.4), width: 1)
        // ミラー2枚
        line(34, 10, 50, 26, color: accent, width: 4)
        line(70, 26, 88, 8, color: accent, width: 4)
        line(50, 26, 70, 26, color: Color.purple.opacity(0.5), width: 1, dash: [2, 2])
        concentric(63, 50, radii: [10, 5], color: accent)
        wafer(80, 82, 11)
    }

    // MARK: 成膜

    private func drawD1() {
        housing(rect(6, 28, 88, 44))
        circle(30, 50, 15, fill: accent.opacity(0.2), stroke: accent)
        circle(70, 50, 15, fill: accent.opacity(0.2), stroke: accent)
        wafer(30, 50, 8)
        wafer(70, 50, 8)
    }

    private func drawD2() {
        let chambers: [CGPoint] = [
            CGPoint(x: 27, y: 27), CGPoint(x: 73, y: 27),
            CGPoint(x: 27, y: 73), CGPoint(x: 73, y: 73),
        ]
        for c in chambers {
            line(50, 50, c.x, c.y, color: accent.opacity(0.6), width: 5)
        }
        for c in chambers {
            circle(c.x, c.y, 14, fill: Self.housingColor, stroke: accent)
            circle(c.x, c.y, 14, fill: accent.opacity(0.2))
            wafer(c.x, c.y, 6)
        }
        circle(50, 50, 12, fill: Self.housingColor, stroke: accent, lineWidth: 2)
        line(50, 50, 58, 42, color: accent, width: 2.5)
    }

    private func drawD3() {
        housing(rect(26, 4, 48, 92))
        circle(50, 22, 11, fill: accent.opacity(0.25), stroke: accent)
        wafer(50, 22, 5)
        var y: CGFloat = 42
        while y <= 88 {
            line(33, y, 67, y, color: accent.opacity(0.8), width: 1.5)
            y += 6
        }
    }

    // MARK: エッチング

    private func drawE1() {
        housing(rect(14, 64, 72, 26), radius: 6)
        glow(50, 42, 36, strength: 0.55)
        circle(50, 42, 22, fill: Self.housingColor, stroke: accent, lineWidth: 2)
        circle(50, 42, 22, fill: accent.opacity(0.15))
        wafer(50, 42, 12)
    }

    private func drawE2() {
        housing(rect(5, 66, 90, 24), radius: 6)
        glow(28, 42, 26, strength: 0.55)
        glow(72, 42, 26, strength: 0.55)
        for x in [CGFloat(28), CGFloat(72)] {
            circle(x, 42, 17, fill: Self.housingColor, stroke: accent, lineWidth: 2)
            circle(x, 42, 17, fill: accent.opacity(0.15))
            wafer(x, 42, 9)
        }
    }

    private func drawE3() {
        housing(rect(14, 70, 72, 22), radius: 6)
        glow(50, 42, 36, strength: 0.25)
        circle(50, 42, 27, fill: Self.housingColor, stroke: accent, lineWidth: 2)
        concentric(50, 42, radii: [22, 18, 14, 10, 6], color: accent.opacity(0.75), lineWidth: 1)
        circle(50, 42, 2.5, fill: accent)
    }

    // MARK: イオン注入

    private func drawI1() {
        housing(rect(4, 34, 18, 32), radius: 4)
        housing(rect(22, 43, 54, 14), radius: 3)
        line(14, 50, 76, 50, color: accent, width: 1.5, dash: [4, 3])
        circle(13, 50, 4, fill: accent)
        wafer(86, 50, 11)
    }

    private func drawI2() {
        housing(rect(2, 28, 22, 44), radius: 5)
        housing(rect(24, 36, 54, 28), radius: 4)
        line(14, 50, 78, 50, color: accent, width: 2.5, dash: [5, 3])
        line(26, 40, 78, 40, color: Self.laserColor, width: 2)
        line(26, 60, 78, 60, color: Self.laserColor, width: 2)
        circle(13, 50, 5, fill: accent)
        wafer(87, 50, 12)
        circle(87, 50, 3, fill: Self.laserColor.opacity(0.8))
    }

    // MARK: CMP

    private func drawC1() {
        housing(rect(4, 4, 92, 92), radius: 10)
        circle(46, 54, 34, fill: accent.opacity(0.3), stroke: accent, lineWidth: 2)
        circle(46, 54, 4, fill: accent.opacity(0.6))
        line(92, 8, 62, 40, color: Color.gray, width: 4)
        wafer(60, 42, 11)
        circle(30, 66, 3, fill: Color.white.opacity(0.7))
    }

    private func drawC2() {
        housing(rect(3, 8, 94, 84), radius: 10)
        circle(28, 56, 22, fill: accent.opacity(0.3), stroke: accent, lineWidth: 2)
        circle(72, 56, 22, fill: accent.opacity(0.3), stroke: accent, lineWidth: 2)
        line(50, 12, 34, 48, color: Color.gray, width: 3.5)
        line(50, 12, 66, 48, color: Color.gray, width: 3.5)
        circle(50, 12, 4, fill: Color.gray)
        wafer(34, 48, 8)
        wafer(66, 48, 8)
    }

    // MARK: 検査

    private func drawQ1() {
        housing(rect(8, 10, 84, 80))
        wafer(50, 64, 18)
        panel(rect(43, 14, 14, 34), color: Self.housingColor, radius: 3)
        circle(50, 46, 7, fill: accent.opacity(0.6), stroke: accent)
        circle(50, 46, 3, fill: Color.white.opacity(0.8))
    }

    private func drawQ2() {
        housing(rect(20, 62, 60, 34), radius: 6)
        wafer(50, 79, 13)
        panel(rect(41, 2, 18, 62), color: Self.housingColor, radius: 4)
        concentric(50, 16, radii: [7, 4], color: accent)
        concentric(50, 38, radii: [6, 3], color: accent)
        line(50, 44, 50, 70, color: Color.cyan, width: 1.5, dash: [2, 2])
    }

    private func drawQ3() {
        panel(rect(6, 6, 66, 50), color: Color(white: 0.15), radius: 4)
        var graph = Path()
        graph.addLines([
            CGPoint(x: 12, y: 46), CGPoint(x: 22, y: 38), CGPoint(x: 32, y: 42),
            CGPoint(x: 42, y: 26), CGPoint(x: 52, y: 30), CGPoint(x: 64, y: 14),
        ])
        context.stroke(graph, with: .color(Color.green), lineWidth: 1.5)
        for p in [CGPoint(x: 18, y: 18), CGPoint(x: 30, y: 24), CGPoint(x: 56, y: 44), CGPoint(x: 46, y: 14)] {
            circle(p.x, p.y, 2, fill: Color.orange)
        }
        housing(rect(56, 60, 40, 36), radius: 6)
        wafer(76, 78, 13)
        circle(71, 74, 1.8, fill: Color.red)
        circle(81, 82, 1.8, fill: Color.red)
        line(40, 56, 40, 66, color: Color.gray, width: 3)
    }

    // MARK: ダイシング/パッケージング

    private func drawP1() {
        wafer(44, 56, 36)
        var clipped = context
        clipped.clip(to: Path(ellipseIn: rect(8, 20, 72, 72)))
        var grid = Path()
        var v: CGFloat = 14
        while v <= 80 {
            grid.move(to: CGPoint(x: v, y: 20))
            grid.addLine(to: CGPoint(x: v, y: 92))
            v += 10
        }
        var h: CGFloat = 26
        while h <= 92 {
            grid.move(to: CGPoint(x: 8, y: h))
            grid.addLine(to: CGPoint(x: 80, y: h))
            h += 10
        }
        clipped.stroke(grid, with: .color(accent), lineWidth: 1)
        circle(84, 16, 12, fill: Self.housingColor, stroke: Color.gray, lineWidth: 2)
        circle(84, 16, 3, fill: Color.gray)
        line(84, 4, 84, 28, color: Color.gray.opacity(0.6), width: 1)
    }

    private func drawP2() {
        wafer(42, 58, 34)
        for y in [CGFloat(42), CGFloat(58), CGFloat(74)] {
            line(12, y, 72, y, color: Self.laserColor, width: 1.8, dash: [1.5, 3])
        }
        // 裏返しチップ
        panel(rect(74, 6, 20, 20), color: accent.opacity(0.7), radius: 2)
        for p in [CGPoint(x: 79, y: 11), CGPoint(x: 89, y: 11), CGPoint(x: 79, y: 21), CGPoint(x: 89, y: 21)] {
            circle(p.x, p.y, 1.6, fill: Color.yellow)
        }
        var arrow = Path()
        arrow.addArc(center: CGPoint(x: 84, y: 34), radius: 8, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: true)
        context.stroke(arrow, with: .color(accent), lineWidth: 1.5)
    }

    private func drawP3() {
        panel(rect(4, 12, 92, 76), color: Color(red: 0.55, green: 0.75, blue: 0.55), radius: 4)
        panel(rect(12, 22, 76, 56), color: Self.housingColor, radius: 2)
        panel(rect(34, 30, 32, 40), color: accent.opacity(0.85), radius: 2)
        let hbm: [CGRect] = [
            rect(17, 30, 13, 18), rect(17, 52, 13, 18),
            rect(70, 30, 13, 18), rect(70, 52, 13, 18),
        ]
        for r in hbm {
            panel(r, color: Color.gray.opacity(0.7), radius: 1.5)
        }
    }
}

// MARK: - 工程の色・アイコン

extension ProcessType {
    var accent: Color {
        switch self {
        case .lithography: return .orange
        case .deposition: return .teal
        case .etching: return .purple
        case .implant: return .green
        case .cmp: return .blue
        case .inspection: return .indigo
        case .packaging: return .brown
        }
    }

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
