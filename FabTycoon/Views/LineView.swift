import SwiftUI

/// 詳細カードの対象（フロアで装置・出荷口をタップして切り替える）
enum FloorSelection: Equatable {
    case process(ProcessType)
    case shipping
}

/// 移行確認シートの対象ノード
struct NodeSwitchTarget: Identifiable, Equatable {
    let id: String
}

/// 詰まり解消の結果表示
struct DeadlockResolution: Identifiable {
    let id = UUID()
    let moved: Int
    let scrapped: Int
}

struct LineView: View {
    @EnvironmentObject private var store: GameStore
    @State private var selectedProcess: ProcessType?
    @State private var selection: FloorSelection = .process(.lithography)
    @State private var didInitSelection = false
    @State private var nodeSwitchTarget: NodeSwitchTarget?
    @State private var showsDefectAnalysis = false
    /// フロア上で選択・ハイライト中の装置（問題リストからも設定する）
    @State private var highlightedToolId: UUID?
    @State private var showsProblems = false
    @State private var showsResolveConfirm = false
    @State private var deadlockResolution: DeadlockResolution?

    var body: some View {
        let state = store.state
        let derived = store.derived
        let node = Engine.currentNode(state: state)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary(state: state, derived: derived, node: node)
                    .padding(.horizontal)

                nextGoalCard(state: state, derived: derived)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    floorBanners(state: state)
                    FloorGridView(selection: $selection, highlightedToolId: $highlightedToolId)
                }
                .padding(.horizontal)

                detailCard(state: state, derived: derived)
                    .padding(.horizontal)

                nodeSection(state: state, node: node)
                    .padding(.horizontal)

                Text("現実の28nmロジックでは、ウェハ投入から出荷まで約1〜2か月、工程は数百ステップに及ぶのが目安です。このゲームはその時間を×600に圧縮しています。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            guard !didInitSelection else { return }
            didInitSelection = true
            selection = .process(store.derived.bottleneck ?? .lithography)
        }
        .sheet(item: $selectedProcess) { process in
            ProcessDetailView(process: process) {
                selectedProcess = nil
                store.openShop(for: process)
            }
            .environmentObject(store)
        }
        .sheet(item: $nodeSwitchTarget) { target in
            NodeSwitchSheet(targetNodeId: target.id)
                .environmentObject(store)
        }
        .sheet(isPresented: $showsDefectAnalysis) {
            DefectAnalysisSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showsProblems) {
            LayoutProblemsSheet { toolId in
                highlightedToolId = toolId
                if let modelId = Engine.installedTools(state: store.state).first(where: { $0.id == toolId })?.modelId,
                   let process = Catalog.model(id: modelId)?.process {
                    selection = .process(process)
                }
                showsProblems = false
            }
            .environmentObject(store)
        }
        .alert("詰まりを解消しますか？", isPresented: $showsResolveConfirm) {
            Button("解消する", role: .destructive) {
                let result = store.resolveDeadlock()
                // 確認アラートが閉じてから結果を出す
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    deadlockResolution = DeadlockResolution(moved: result.moved, scrapped: result.scrapped)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("レール上・搬送中・処理済みのロットを手運びでストッカーへ移します。ストッカーが満杯の分は廃棄されます。")
        }
        .alert("詰まりを解消しました", isPresented: Binding(
            get: { deadlockResolution != nil },
            set: { if !$0 { deadlockResolution = nil } }
        ), presenting: deadlockResolution) { _ in
            Button("OK") { deadlockResolution = nil }
        } message: { result in
            Text(result.scrapped > 0
                 ? "\(result.moved)ロットをストッカーへ移し、\(result.scrapped)ロットを廃棄しました。"
                 : "\(result.moved)ロットをストッカーへ移しました。")
        }
    }

    // MARK: フロアのバナー（排出中・詰まり・レイアウトの問題）

    @ViewBuilder
    private func floorBanners(state: GameState) -> some View {
        let problems = store.layoutProblems
        let deadlocked = store.simDeadlocked
        if let pendingNodeId = state.fab.nodeSwitch.pendingNodeId {
            let name = Catalog.node(id: pendingNodeId)?.displayName ?? pendingNodeId
            VStack(alignment: .leading, spacing: 8) {
                Label("排出中：仕掛かりが流れ切ったら \(name) へ切り替えます", systemImage: "hourglass")
                    .font(.subheadline.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Button("切替をやめる") {
                    store.cancelNodeSwitch()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(0.12)))
        }
        if deadlocked {
            VStack(alignment: .leading, spacing: 8) {
                Label("ラインが詰まっています（ロットが互いに道をふさいでいます）", systemImage: "exclamationmark.octagon.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showsResolveConfirm = true
                } label: {
                    Text("詰まりを解消")
                        .bold()
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.red))
        }
        if !problems.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("レイアウトに問題があります")
                    .font(.subheadline.bold())
                Spacer()
                Button("問題 \(problems.count) 件") {
                    showsProblems = true
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.15)))
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
            VStack(alignment: .leading, spacing: 2) {
                Text(clockText(gameHours: state.gameHoursElapsed))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Text("現実の1秒＝ゲーム内10分")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            // 次の一手アドバイザー
            Label(Engine.advisorMessage(state: state, derived: derived), systemImage: "lightbulb")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: 次の目標

    private func nextGoalCard(state: GameState, derived: DerivedState) -> some View {
        Group {
            if let spec = Engine.nextMilestone(state: state) {
                let texts = Engine.milestoneProgressTexts(state: state, derived: derived, spec: spec)
                VStack(alignment: .leading, spacing: 8) {
                    Label("次の目標", systemImage: "flag.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Text(spec.title)
                        .font(.headline)
                    ProgressView(value: Engine.milestoneProgress(state: state, derived: derived, spec: spec))
                        .tint(.orange)
                    Text("現在 \(texts.current) ／ 目標 \(texts.target)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(spec.learningNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("全ての目標を達成しました", systemImage: "flag.checkered")
                    .font(.headline)
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    /// 「Day 3 07:30」形式のゲーム内時計
    private func clockText(gameHours: Double) -> String {
        let totalMinutes = Int(max(gameHours, 0) * 60)
        let day = totalMinutes / 1440 + 1
        let hour = (totalMinutes / 60) % 24
        let minute = totalMinutes % 60
        return "Day \(day) \(String(format: "%02d", hour)):\(String(format: "%02d", minute))"
    }

    @ViewBuilder
    private func statusLabel(state: GameState, derived: DerivedState) -> some View {
        if derived.lineWPH <= 0 {
            Label("停止中：稼働装置ゼロの工程あり", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
        } else {
            Label("稼働中", systemImage: "circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
        }
    }

    // MARK: 詳細カード

    @ViewBuilder
    private func detailCard(state: GameState, derived: DerivedState) -> some View {
        switch selection {
        case .process(let process):
            processCard(process, state: state, derived: derived)
        case .shipping:
            shippingCard(state: state, derived: derived)
        }
    }

    private func processCard(_ process: ProcessType, state: GameState, derived: DerivedState) -> some View {
        let count = Engine.installedTools(state: state).filter { Catalog.model(id: $0.modelId)?.process == process }.count
        let standby = Engine.standbyCount(state: state, process: process)
        let wph = derived.wph(process)
        let load: Double = wph > 0 ? min(max(derived.lineWPH / wph, 0), 1) : 0
        let node = Engine.currentNode(state: state)
        let passes = Engine.passCount(for: process, node: node, topLitho: Engine.topLithoClass(state: state))
        let passText = passes == 1
            ? "\(node.displayName)では最後に 1 回だけ通る"
            : "\(node.displayName)ではこの工程を \(passes) 回通る"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(process.accent)
                    .frame(width: 6, height: 22)
                Text(process.displayName)
                    .font(.title3.bold())
            }
            Text("装置 \(count)台（稼働\(derived.units(process))台） ・ 実効WPH \(MoneyFormat.decimal(wph, digits: 2)) ・ 負荷 \(MoneyFormat.percent(load, digits: 0)) ・ 工程歩留まり \(MoneyFormat.percent(derived.processYields[process] ?? 0))")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if standby > 0 {
                Label("待機中の装置が\(standby)台あります（現在のノードでは稼働しません）", systemImage: "pause.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if process == .inspection {
                Label("検出率 \(MoneyFormat.percent(derived.detectionRate))（見逃した不良はそのまま出荷されます）", systemImage: "magnifyingglass")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if state.activeExcursion != nil {
                    Label("歩留まり異常が発生しています（ライン歩留まり −\(MoneyFormat.decimal(derived.excursionYieldLoss * 100, digits: 1))pt）", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        showsDefectAnalysis = true
                    } label: {
                        Text("欠陥分析を開く")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            if derived.bottleneck == process {
                Label("このラインの速度はここで決まっています", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
            } else if derived.secondBottleneck == process {
                Label("次のボトルネック候補です", systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
            Label(passText, systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.bold())
                .monospacedDigit()
            Text(process.educationText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(process.connectionNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    selectedProcess = process
                } label: {
                    Text("装置を管理（改良・売却）")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    store.openShop(for: process)
                } label: {
                    Text("装置を追加")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func shippingCard(state: GameState, derived: DerivedState) -> some View {
        let inventory = state.fab.inventoryChips
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.gray)
                Text("出荷・倉庫")
                    .font(.title3.bold())
            }
            HStack {
                Text("完成チップ在庫 \(MoneyFormat.count(inventory)) / \(MoneyFormat.count(Engine.inventoryCap)) 個")
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
            }
            Toggle("自動販売", isOn: Binding(
                get: { store.state.fab.autoSellEnabled },
                set: { _ in store.toggleAutoSell() }
            ))
            Button {
                store.sellAllInventory()
            } label: {
                Text("一括売却（\(MoneyFormat.yen(Engine.inventorySaleValueYen(state: state, priceYen: derived.currentPriceYen)))）")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(inventory < 1)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: ノード

    private func previousNode(before id: String) -> NodeSpec? {
        guard let index = Catalog.nodes.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return Catalog.nodes[index - 1]
    }

    private func nodeSection(state: GameState, node: NodeSpec) -> some View {
        let next = Catalog.nextNode(after: node.id)
        let previous = previousNode(before: node.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("ノード", systemImage: "cpu")
                    .font(.headline)
                Spacer()
                BadgeView(text: "現在 \(node.displayName)", systemImage: nil, color: .blue)
                if let next {
                    BadgeView(text: "次 \(next.displayName)", systemImage: nil, color: .gray)
                }
            }
            if let next {
                if Engine.canSwitchNode(state: state, toNodeId: next.id) {
                    Button {
                        nodeSwitchTarget = NodeSwitchTarget(id: next.id)
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
                    nodeSwitchTarget = NodeSwitchTarget(id: previous.id)
                } label: {
                    Label("\(previous.displayName)へ戻す", systemImage: "arrow.uturn.backward.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func lockBanner(next: NodeSpec, state: GameState) -> some View {
        let researchName = Engine.nodeUnlockResearch(nodeId: next.id)?.name
        let needsResearch = Catalog.isPlayable(nodeId: next.id) && !Engine.isNodeUnlocked(state: state, nodeId: next.id)
        let title = needsResearch ? "\(next.displayName)は研究で解放" : "\(next.displayName)は今後のアップデートで解放"
        let detail = needsResearch
            ? "研究『\(researchName ?? "\(next.displayName)プロセス")』を完了すると移行できます"
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

// MARK: - レイアウトの問題シート

struct LayoutProblemsSheet: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    /// 装置の問題をタップしたとき（フロアでハイライトしてシートを閉じるのは呼び出し側）
    let onSelectTool: (UUID) -> Void

    init(onSelectTool: @escaping (UUID) -> Void) {
        self.onSelectTool = onSelectTool
    }

    var body: some View {
        let problems = store.layoutProblems
        NavigationStack {
            List {
                if problems.isEmpty {
                    Text("問題はありません。")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(Array(problems.enumerated()), id: \.offset) { item in
                            problemRow(item.element)
                        }
                    } footer: {
                        Text("装置の問題をタップすると、フロア上でその装置をハイライトします。レールはフロアの「編集」→「レール」で引き直せます。")
                    }
                }
            }
            .navigationTitle("レイアウトの問題")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func problemRow(_ problem: LayoutProblem) -> some View {
        if let toolId = toolId(of: problem) {
            Button {
                onSelectTool(toolId)
            } label: {
                HStack {
                    Label(problem.message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "scope")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toolId(of problem: LayoutProblem) -> UUID? {
        switch problem {
        case .unconnectedInput(let toolId, _), .unconnectedOutput(let toolId, _):
            return toolId
        case .lineBreak:
            return nil
        }
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
