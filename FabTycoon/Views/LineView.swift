import SwiftUI

/// フロア上で選択中のベイ
enum FloorSelection: Equatable {
    case process(ProcessType)
    case shipping
}

/// 移行確認シートの対象ノード
struct NodeSwitchTarget: Identifiable, Equatable {
    let id: String
}

struct LineView: View {
    @EnvironmentObject private var store: GameStore
    @State private var selectedProcess: ProcessType?
    @State private var selection: FloorSelection = .process(.lithography)
    @State private var didInitSelection = false
    @State private var nodeSwitchTarget: NodeSwitchTarget?
    @State private var showsDefectAnalysis = false

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

                FabFloorView(selection: $selection)
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
        let count = state.fab.equipment.filter { Catalog.model(id: $0.modelId)?.process == process }.count
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

    var body: some View {
        let state = store.state
        let from = store.derived
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
                    Button {
                        store.switchNode(targetNodeId)
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

// MARK: - フロア平面図

/// 4列×2行の蛇行配置。slot 0...6 が工程順、slot 7 が出荷・倉庫。
struct FloorLayout {
    static let columns = 4
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 8
    static let shippingSlot = 7

    let size: CGSize

    var cellSize: CGSize {
        let width = (size.width - Self.padding * 2 - Self.spacing * 3) / 4
        let height = (size.height - Self.padding * 2 - Self.spacing) / 2
        return CGSize(width: max(width, 0), height: max(height, 0))
    }

    func rect(slot: Int) -> CGRect {
        let row = slot / Self.columns
        let index = slot % Self.columns
        let column = row == 0 ? index : Self.columns - 1 - index
        let cell = cellSize
        let x = Self.padding + CGFloat(column) * (cell.width + Self.spacing)
        let y = Self.padding + CGFloat(row) * (cell.height + Self.spacing)
        return CGRect(x: x, y: y, width: cell.width, height: cell.height)
    }

    /// 工程順（露光→…→PKG→出荷）のベイ中心
    var flowCenters: [CGPoint] {
        (0...Self.shippingSlot).map { slot -> CGPoint in
            let r = rect(slot: slot)
            return CGPoint(x: r.midX, y: r.midY)
        }
    }

    /// 搬入口（上部壁面のFOUPストッカー位置）
    var entryPoint: CGPoint {
        CGPoint(x: rect(slot: 0).midX, y: 7)
    }

    /// 搬入口＋工程順のベイ中心（9点・8区間。区間0=搬入、区間i=工程i-1から出る区間）
    var flowPoints: [CGPoint] {
        [entryPoint] + flowCenters
    }
}

/// 滞留表示の対象工程と台数
struct FloorQueue {
    let process: ProcessType
    let count: Int
    let isBottleneck: Bool
}

struct FabFloorView: View {
    @EnvironmentObject private var store: GameStore
    @Binding var selection: FloorSelection

    var body: some View {
        let state = store.state
        let derived = store.derived
        GeometryReader { geo in
            let layout = FloorLayout(size: geo.size)
            ZStack(alignment: .topLeading) {
                FloorBackground()
                ForEach(ProcessType.allCases) { process in
                    bayButton(process: process, layout: layout, state: state, derived: derived)
                }
                shippingButton(layout: layout, state: state)
                FloorFlowLayer(
                    points: layout.flowPoints,
                    bottleneckRect: bottleneckRect(layout: layout, derived: derived),
                    lineWPH: derived.lineWPH,
                    flowing: state.fab.running && derived.lineWPH > 0,
                    segmentWPH: ProcessType.allCases.map { derived.wph($0) },
                    bottleneck: derived.bottleneck,
                    secondBottleneck: derived.secondBottleneck,
                    queues: floorQueues(derived: derived)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .aspectRatio(1.2, contentMode: .fit)
    }

    private func installedModels(for process: ProcessType, state: GameState) -> [EquipmentModel] {
        state.fab.equipment
            .compactMap { Catalog.model(id: $0.modelId) }
            .filter { $0.process == process }
    }

    private func bottleneckRect(layout: FloorLayout, derived: DerivedState) -> CGRect? {
        guard let bottleneck = derived.bottleneck else { return nil }
        return layout.rect(slot: bottleneck.order).insetBy(dx: -1.5, dy: -1.5)
    }

    /// 律速工程（＋次点）の手前に並べる滞留FOUP
    private func floorQueues(derived: DerivedState) -> [FloorQueue] {
        var result: [FloorQueue] = []
        var total = 0
        if let bn = derived.bottleneck {
            let n = FloorVizMath.queueCount(lineWPH: derived.lineWPH, processWPH: derived.wph(bn))
            if n > 0 {
                result.append(FloorQueue(process: bn, count: n, isBottleneck: true))
                total += n
            }
        }
        if let second = derived.secondBottleneck, second != derived.bottleneck {
            var n = FloorVizMath.queueCount(lineWPH: derived.lineWPH, processWPH: derived.wph(second))
            n = min(n, max(9 - total, 0))
            if n > 0 {
                result.append(FloorQueue(process: second, count: n, isBottleneck: false))
            }
        }
        return result
    }

    private func bayButton(process: ProcessType, layout: FloorLayout, state: GameState, derived: DerivedState) -> some View {
        let rect = layout.rect(slot: process.order)
        return Button {
            selection = .process(process)
        } label: {
            let models = installedModels(for: process, state: state)
            FloorBayView(
                process: process,
                models: models,
                standbyModelIds: Set(models.filter { !$0.supports(nodeId: state.fab.currentNodeId) }.map { $0.id }),
                wph: derived.wph(process),
                isBottleneck: derived.bottleneck == process,
                isSecond: derived.secondBottleneck == process,
                isSelected: selection == .process(process),
                size: rect.size,
                showsExcursionBadge: (process == .inspection && state.activeExcursion != nil) || derived.excursionProcess == process,
                isExcursionSource: derived.excursionProcess == process,
                lineRunning: state.fab.running && derived.lineWPH > 0
            )
        }
        .buttonStyle(.plain)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func shippingButton(layout: FloorLayout, state: GameState) -> some View {
        let rect = layout.rect(slot: FloorLayout.shippingSlot)
        return Button {
            selection = .shipping
        } label: {
            FloorShippingView(
                inventory: state.fab.inventoryChips,
                cap: Engine.inventoryCap,
                isSelected: selection == .shipping
            )
        }
        .buttonStyle(.plain)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

// MARK: 床

private struct FloorBackground: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
            Canvas { context, size in
                let step: CGFloat = 16
                var grid = Path()
                var x: CGFloat = step
                while x < size.width {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = step
                while y < size.height {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(grid, with: .color(Color.gray.opacity(0.18)), lineWidth: 0.5)

                // 大タイルの継ぎ目
                let tileStep: CGFloat = 64
                var seams = Path()
                var sx: CGFloat = tileStep
                while sx < size.width {
                    seams.move(to: CGPoint(x: sx, y: 0))
                    seams.addLine(to: CGPoint(x: sx, y: size.height))
                    sx += tileStep
                }
                var sy: CGFloat = tileStep
                while sy < size.height {
                    seams.move(to: CGPoint(x: 0, y: sy))
                    seams.addLine(to: CGPoint(x: size.width, y: sy))
                    sy += tileStep
                }
                context.stroke(seams, with: .color(Color.gray.opacity(0.28)), lineWidth: 1)

                // 穴あきタイル風ドット
                let holeStep: CGFloat = 32
                var holes = Path()
                var hy: CGFloat = holeStep / 2
                while hy < size.height {
                    var hx: CGFloat = holeStep / 2
                    while hx < size.width {
                        holes.addEllipse(in: CGRect(x: hx - 1, y: hy - 1, width: 2, height: 2))
                        hx += holeStep
                    }
                    hy += holeStep
                }
                context.fill(holes, with: .color(Color.gray.opacity(0.10)))

                // 通路ガイド（ベイ間の破線）
                let layout = FloorLayout(size: size)
                var aisles = Path()
                for slot in 0..<3 {
                    let ax = layout.rect(slot: slot).maxX + FloorLayout.spacing / 2
                    aisles.move(to: CGPoint(x: ax, y: 0))
                    aisles.addLine(to: CGPoint(x: ax, y: size.height))
                }
                let ay = layout.rect(slot: 0).maxY + FloorLayout.spacing / 2
                aisles.move(to: CGPoint(x: 0, y: ay))
                aisles.addLine(to: CGPoint(x: size.width, y: ay))
                context.stroke(
                    aisles,
                    with: .color(Color.gray.opacity(0.13)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
            // 壁（二重線）
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.gray.opacity(0.45), lineWidth: 3)
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Color.gray.opacity(0.25), lineWidth: 1)
                .padding(3)
        }
    }
}

// MARK: ベイ共通の外観

private struct FloorBayStyle: ViewModifier {
    let accent: Color
    let isSelected: Bool
    let isSecond: Bool

    private var borderColor: Color {
        if isSelected { return accent }
        if isSecond { return .yellow }
        return Color.gray.opacity(0.4)
    }

    private var borderWidth: CGFloat {
        if isSelected { return 2.5 }
        if isSecond { return 2 }
        return 1
    }

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    accent.opacity(isSelected ? 0.14 : 0.05)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FloorBayHeader: View {
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(subtitle)
                .font(.system(size: 8, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color)
    }
}

// MARK: 工程ベイ

struct FloorBayView: View {
    let process: ProcessType
    let models: [EquipmentModel]
    /// 現在のノードに非対応で待機中のモデルID
    var standbyModelIds: Set<String> = []
    let wph: Double
    let isBottleneck: Bool
    let isSecond: Bool
    let isSelected: Bool
    let size: CGSize
    /// 歩留まり異常バッジ（検査ベイと原因工程ベイに出す）
    var showsExcursionBadge: Bool = false
    /// 歩留まり異常の原因工程（装置ランプを警報表示）
    var isExcursionSource: Bool = false
    /// ラインが稼働中（装置ランプを点滅）
    var lineRunning: Bool = false

    private let headerHeight: CGFloat = 26
    private let footerHeight: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            FloorBayHeader(
                title: process.shortName,
                subtitle: "\(MoneyFormat.decimal(wph, digits: 1)) WPH",
                color: process.accent
            )
            .frame(height: headerHeight)
            equipmentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, footerHeight)
        }
        .overlay(alignment: .bottom) { footer }
        .modifier(FloorBayStyle(accent: process.accent, isSelected: isSelected, isSecond: isSecond))
        .overlay(alignment: .topTrailing) {
            if isBottleneck {
                bottleneckTag
                    .offset(x: 4, y: -7)
            }
        }
    }

    @ViewBuilder
    private var equipmentArea: some View {
        if models.isEmpty {
            Text("装置なし")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            let shown = Array(models.prefix(4))
            let side = iconSide(count: shown.count)
            VStack(spacing: 2) {
                iconRow(Array(shown.prefix(2)), side: side)
                if shown.count > 2 {
                    iconRow(Array(shown.dropFirst(2)), side: side)
                }
            }
        }
    }

    private func iconRow(_ row: [EquipmentModel], side: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(row.enumerated()), id: \.offset) { item in
                let isStandby = standbyModelIds.contains(item.element.id)
                ZStack(alignment: .topTrailing) {
                    EquipmentIllustration(model: item.element)
                        .frame(width: side, height: side)
                        .grayscale(isStandby ? 1 : 0)
                        .opacity(isStandby ? 0.4 : 1)
                    EquipmentStatusLamp(kind: lampKind(isStandby: isStandby))
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    private func lampKind(isStandby: Bool) -> EquipmentStatusLamp.Kind {
        if isExcursionSource { return .alarm }
        if isStandby { return .standby }
        if lineRunning { return .running }
        return .idle
    }

    private var standbyCount: Int {
        models.filter { standbyModelIds.contains($0.id) }.count
    }

    private func iconSide(count: Int) -> CGFloat {
        let width = size.width - 8
        let height = size.height - headerHeight - footerHeight - 4
        let side: CGFloat
        if count <= 1 {
            side = min(width, height) * 0.85
        } else {
            side = min((width - 2) / 2, (height - 2) / 2)
        }
        return max(side, 0)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            if showsExcursionBadge {
                Text("異常")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
                    .fixedSize()
            }
            if models.count > 4 {
                Text("+\(models.count - 4)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(process.accent))
            }
            if standbyCount > 0 {
                Text("待機\(standbyCount)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.gray))
                    .fixedSize()
            }
            Spacer(minLength: 0)
            Text("×\(models.count)台")
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .frame(height: footerHeight)
    }

    private var bottleneckTag: some View {
        Text("ボトルネック")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red))
            .fixedSize()
    }
}

/// 装置の状態ランプ（稼働=緑点滅、アイドル=緑、待機=灰、警報=赤点滅）
private struct EquipmentStatusLamp: View {
    enum Kind { case running, idle, standby, alarm }
    let kind: Kind

    var body: some View {
        switch kind {
        case .standby:
            dot(color: .gray, opacity: 0.75)
        case .idle:
            dot(color: .green, opacity: 0.85)
        case .running:
            TimelineView(.periodic(from: .now, by: 0.6)) { timeline in
                let on = Int(timeline.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                dot(color: .green, opacity: on ? 1.0 : 0.3)
            }
        case .alarm:
            TimelineView(.periodic(from: .now, by: 0.45)) { timeline in
                let on = Int(timeline.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
                dot(color: .red, opacity: on ? 1.0 : 0.25)
            }
        }
    }

    private func dot(color: Color, opacity: Double) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(Color.white, lineWidth: 0.8))
    }
}

// MARK: 出荷・倉庫

struct FloorShippingView: View {
    let inventory: Double
    let cap: Double
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            FloorBayHeader(title: "出荷・倉庫", subtitle: "完成チップ", color: .gray)
                .frame(height: 26)
            VStack(spacing: 2) {
                Image(systemName: "shippingbox.fill")
                    .font(.title3)
                    .foregroundStyle(.gray)
                Text(MoneyFormat.count(inventory))
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("/ \(MoneyFormat.count(cap))")
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(FloorBayStyle(accent: .gray, isSelected: isSelected, isSecond: false))
    }
}

// MARK: 天井搬送レール＋FOUP＋ボトルネック脈動

struct FloorFlowLayer: View {
    /// 搬入口＋工程順のベイ中心（9点・8区間）
    let points: [CGPoint]
    let bottleneckRect: CGRect?
    let lineWPH: Double
    let flowing: Bool
    /// ProcessType.allCases 順の実効WPH（区間 i+1 = 工程 i）
    let segmentWPH: [Double]
    let bottleneck: ProcessType?
    let secondBottleneck: ProcessType?
    let queues: [FloorQueue]

    @State private var clock = FloorFlowClock()

    private static let amber = Color(red: 1.0, green: 0.75, blue: 0.0)

    var body: some View {
        let clock = clock
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !flowing && bottleneckRect == nil)) { timeline in
            Canvas { context, _ in
                draw(in: context, time: timeline.date.timeIntervalSinceReferenceDate, clock: clock)
            }
        }
        .allowsHitTesting(false)
    }

    /// 区間の色：区間0（搬入）→金色。区間 i>=1 は工程 i-1 で判定（ボトルネック→赤、負荷80%以上→橙、それ以外→金色）
    private func segmentColor(_ segment: Int) -> Color {
        guard segment >= 1 else { return Self.amber }
        let processIndex = segment - 1
        let processes = Array(ProcessType.allCases)
        if processIndex < processes.count, let bottleneck, processes[processIndex] == bottleneck {
            return .red
        }
        guard processIndex < segmentWPH.count else { return Self.amber }
        let wph = segmentWPH[processIndex]
        let load = wph > 0 ? min(lineWPH / wph, 1) : 1
        return load >= 0.8 ? .orange : Self.amber
    }

    private func draw(in context: GraphicsContext, time: Double, clock: FloorFlowClock) {
        // 1. ボトルネックの赤脈動枠
        if let rect = bottleneckRect {
            let pulse = 0.55 + 0.45 * sin(time * 2 * Double.pi / 1.2)
            let border = Path(roundedRect: rect, cornerRadius: 9)
            context.stroke(border, with: .color(Color.red.opacity(pulse)), lineWidth: 3)
        }

        guard points.count > 1 else { return }
        // 2. 平滑化クロックを進める（停止中も時刻だけ更新して再開時のジャンプを防ぐ）
        // 区間0（搬入）は先頭工程と同じWPHで重み付けする
        let extendedWPH = [segmentWPH.first ?? 0] + segmentWPH
        let targetWeights = FlowPathMath.segmentTimeWeights(processWPH: extendedWPH, segmentCount: points.count - 1)
        clock.advance(now: time, targetWeights: targetWeights, targetPeriod: FloorVizMath.lapPeriod(lineWPH: lineWPH), flowing: flowing)

        // 3. レール
        drawRails(in: context)

        // 4. ストッカー（搬入口）
        drawStocker(in: context, center: points[0])

        // 5. サイディングと滞留FOUP（停止中も表示）
        for queue in queues {
            let queuePoints = FloorVizMath.queuePoints(pathPoints: points, targetIndex: queue.process.order + 1, count: queue.count)
            guard !queuePoints.isEmpty else { continue }
            if queuePoints.count > 1 {
                var siding = Path()
                siding.move(to: queuePoints[0])
                for p in queuePoints.dropFirst() {
                    siding.addLine(to: p)
                }
                context.stroke(
                    siding,
                    with: .color(Color.gray.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
            }
            let ring: Color = queue.isBottleneck ? .red : .orange
            for p in queuePoints {
                drawFOUP(in: context, center: p, ring: ring)
            }
        }

        // 6. 移動FOUP
        guard flowing else { return }
        guard FlowPathMath.totalLength(points) > 0 else { return }
        let totalQueued = queues.reduce(0) { $0 + $1.count }
        let count = FloorVizMath.movingFOUPCount(lineWPH: lineWPH, totalQueued: totalQueued)
        guard count > 0 else { return }
        let weights = clock.weights
        for index in 0..<count {
            let fraction = (clock.phase + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1)
            let point = FlowPathMath.point(on: points, atTimeFraction: fraction, segmentWeights: weights)
            drawFOUP(in: context, center: point, ring: .white)
        }
    }

    /// 天井搬送レール（土台→支柱→芯線→方向シェブロンの順に重ねる）
    private func drawRails(in context: GraphicsContext) {
        let segmentCount = points.count - 1
        guard segmentCount > 0 else { return }

        // 土台
        for index in 0..<segmentCount {
            var base = Path()
            base.move(to: points[index])
            base.addLine(to: points[index + 1])
            context.stroke(
                base,
                with: .color(Color.white.opacity(0.5)),
                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
            )
        }

        // 支柱ドット
        var pillars = Path()
        for index in 0..<segmentCount {
            let a = points[index]
            let b = points[index + 1]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0.001 else { continue }
            let dirX = (b.x - a.x) / len
            let dirY = (b.y - a.y) / len
            var d: CGFloat = 13
            while d < len {
                let px = a.x + dirX * d
                let py = a.y + dirY * d
                pillars.addEllipse(in: CGRect(x: px - 1.8, y: py - 1.8, width: 3.6, height: 3.6))
                d += 26
            }
        }
        context.fill(pillars, with: .color(Color.gray.opacity(0.55)))

        // 芯線
        for index in 0..<segmentCount {
            var core = Path()
            core.move(to: points[index])
            core.addLine(to: points[index + 1])
            context.stroke(
                core,
                with: .color(segmentColor(index).opacity(flowing ? 0.85 : 0.4)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }

        // 方向シェブロン（座標を自前で回転）
        var chevrons = Path()
        for index in 0..<segmentCount {
            let a = points[index]
            let b = points[index + 1]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0.001 else { continue }
            let angle = atan2(b.y - a.y, b.x - a.x)
            let cosA = cos(angle)
            let sinA = sin(angle)
            let fractions: [CGFloat] = len > 110 ? [1.0 / 3.0, 2.0 / 3.0] : [0.5]
            for t in fractions {
                let cx = a.x + (b.x - a.x) * t
                let cy = a.y + (b.y - a.y) * t
                let local: [CGPoint] = [CGPoint(x: -3, y: -4.5), CGPoint(x: 3.5, y: 0), CGPoint(x: -3, y: 4.5)]
                let world = local.map { p -> CGPoint in
                    CGPoint(x: cx + p.x * cosA - p.y * sinA, y: cy + p.x * sinA + p.y * cosA)
                }
                chevrons.move(to: world[0])
                chevrons.addLine(to: world[1])
                chevrons.addLine(to: world[2])
            }
        }
        context.stroke(
            chevrons,
            with: .color(Color.gray.opacity(0.65)),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )
    }

    /// 搬入口のFOUPストッカー
    private func drawStocker(in context: GraphicsContext, center: CGPoint) {
        let stockerColor = Color.gray.opacity(0.85)
        // 上部の突起
        let nub = Path(CGRect(x: center.x - 3, y: center.y - 9, width: 6, height: 3))
        context.fill(nub, with: .color(stockerColor))
        // 本体
        let body = Path(roundedRect: CGRect(x: center.x - 8, y: center.y - 6, width: 16, height: 12), cornerRadius: 3)
        context.fill(body, with: .color(stockerColor))
        // スロット
        var slots = Path()
        slots.move(to: CGPoint(x: center.x - 5, y: center.y - 1.5))
        slots.addLine(to: CGPoint(x: center.x + 5, y: center.y - 1.5))
        slots.move(to: CGPoint(x: center.x - 5, y: center.y + 2.5))
        slots.addLine(to: CGPoint(x: center.x + 5, y: center.y + 2.5))
        context.stroke(slots, with: .color(Color.white.opacity(0.7)), lineWidth: 1)
    }

    /// FOUP（絶対座標で描画、回転なし。ハンガーは常に上向き）
    private func drawFOUP(in context: GraphicsContext, center: CGPoint, ring: Color) {
        // ハンガー（レールへ吊る）
        var hanger = Path()
        hanger.move(to: CGPoint(x: center.x, y: center.y - 7))
        hanger.addLine(to: CGPoint(x: center.x, y: center.y - 3))
        context.stroke(hanger, with: .color(Color.gray), lineWidth: 1.5)
        // キャリア本体
        let body = Path(roundedRect: CGRect(x: center.x - 6.5, y: center.y - 3.5, width: 13, height: 10), cornerRadius: 2.5)
        context.fill(body, with: .color(Color(red: 0.98, green: 0.65, blue: 0.15)))
        context.stroke(body, with: .color(ring), lineWidth: 1.5)
        // ウェハスロット
        var slots = Path()
        slots.move(to: CGPoint(x: center.x - 4, y: center.y + 0.5))
        slots.addLine(to: CGPoint(x: center.x + 4, y: center.y + 0.5))
        slots.move(to: CGPoint(x: center.x - 4, y: center.y + 3.5))
        slots.addLine(to: CGPoint(x: center.x + 4, y: center.y + 3.5))
        context.stroke(slots, with: .color(Color.black.opacity(0.25)), lineWidth: 1)
    }
}

/// フロー用の平滑化クロック。重み・周期を指数平滑し、位相を積分で進める。
private final class FloorFlowClock {
    private static let smoothingTime = 1.2
    private static let maxStep = 0.1

    private var lastTime: Double?
    private(set) var phase: Double = 0
    private(set) var weights: [Double] = []
    private(set) var period: Double = 0

    func advance(now: Double, targetWeights: [Double], targetPeriod: Double, flowing: Bool) {
        // 初回・区間数変化時はターゲットにスナップ
        guard let last = lastTime, weights.count == targetWeights.count, period > 0, period.isFinite else {
            lastTime = now
            weights = targetWeights
            period = targetPeriod
            return
        }
        let dt = min(max(now - last, 0), Self.maxStep)
        lastTime = now
        let alpha = 1 - exp(-dt / Self.smoothingTime)
        for index in weights.indices {
            weights[index] += (targetWeights[index] - weights[index]) * alpha
        }
        if targetPeriod.isFinite, targetPeriod > 0 {
            period += (targetPeriod - period) * alpha
        }
        guard flowing, period > 0 else { return }
        phase = (phase + dt / period).truncatingRemainder(dividingBy: 1)
        if phase < 0 || !phase.isFinite { phase = 0 }
    }
}

/// ポリライン上の位置計算（純粋関数）
enum FlowPathMath {
    static func segmentLengths(_ points: [CGPoint]) -> [CGFloat] {
        guard points.count > 1 else { return [] }
        return (1..<points.count).map { index -> CGFloat in
            let a = points[index - 1]
            let b = points[index]
            return hypot(b.x - a.x, b.y - a.y)
        }
    }

    static func totalLength(_ points: [CGPoint]) -> CGFloat {
        segmentLengths(points).reduce(0, +)
    }

    /// 始点から distance だけ進んだ位置（全長で割った余りで周回）
    static func point(on points: [CGPoint], at distance: CGFloat) -> CGPoint {
        guard let first = points.first else { return .zero }
        let lengths = segmentLengths(points)
        let total = lengths.reduce(0, +)
        guard total > 0 else { return first }
        var remaining = distance.truncatingRemainder(dividingBy: total)
        if remaining < 0 { remaining += total }
        var cumulative: CGFloat = 0
        for (index, length) in lengths.enumerated() {
            if remaining <= cumulative + length {
                let t = length > 0 ? (remaining - cumulative) / length : 0
                let a = points[index]
                let b = points[index + 1]
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            cumulative += length
        }
        return points[points.count - 1]
    }

    /// 各区間の時間シェア（WPH の逆数を正規化、合計1）。異常時は等重み。
    /// segmentCount を省略すると processWPH の要素数を想定数とする。
    static func segmentTimeWeights(processWPH: [Double], segmentCount: Int? = nil) -> [Double] {
        let count = segmentCount ?? processWPH.count
        guard count > 0 else { return [] }
        let uniform = Array(repeating: 1.0 / Double(count), count: count)
        guard processWPH.count == count, processWPH.contains(where: { $0.isFinite && $0 > 0 }) else {
            return uniform
        }
        let inverses = processWPH.map { wph -> Double in
            let safe = wph.isNaN ? 0 : wph
            return 1.0 / max(safe, 0.05)
        }
        let total = inverses.reduce(0, +)
        guard total.isFinite, total > 0 else { return uniform }
        let weights = inverses.map { $0 / total }
        guard weights.allSatisfy({ $0.isFinite }) else { return uniform }
        return weights
    }

    /// 時間割合（0...1）が属する区間と、区間内の時間割合
    private static func locate(timeFraction: Double, weights: [Double]) -> (index: Int, local: Double)? {
        guard !weights.isEmpty else { return nil }
        let total = weights.reduce(0) { $0 + max($1.isFinite ? $1 : 0, 0) }
        guard total > 0, total.isFinite else { return nil }
        var fraction = timeFraction.isFinite ? timeFraction.truncatingRemainder(dividingBy: 1) : 0
        if fraction < 0 { fraction += 1 }
        let target = fraction * total
        var cumulative = 0.0
        var lastPositive = 0
        for (index, raw) in weights.enumerated() {
            let weight = max(raw.isFinite ? raw : 0, 0)
            guard weight > 0 else { continue }
            lastPositive = index
            if target < cumulative + weight {
                return (index, min(max((target - cumulative) / weight, 0), 1))
            }
            cumulative += weight
        }
        return (lastPositive, 1)
    }

    /// 時間割合から位置を引く。区間内は「区間内時間割合 × 区間長」で線形補間。
    static func point(on points: [CGPoint], atTimeFraction fraction: Double, segmentWeights: [Double]) -> CGPoint {
        guard let first = points.first else { return .zero }
        let lengths = segmentLengths(points)
        let total = lengths.reduce(0, +)
        guard total > 0 else { return first }
        // 重みが区間数と合わない場合は距離等速にフォールバック
        guard segmentWeights.count == lengths.count,
              let located = locate(timeFraction: fraction, weights: segmentWeights) else {
            let safe = fraction.isFinite ? fraction : 0
            return point(on: points, at: CGFloat(safe) * total)
        }
        let a = points[located.index]
        let b = points[located.index + 1]
        let t = CGFloat(located.local)
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// 時間割合が属する区間の index
    static func segmentIndex(atTimeFraction fraction: Double, segmentWeights: [Double]) -> Int {
        locate(timeFraction: fraction, weights: segmentWeights)?.index ?? 0
    }
}

/// フロア可視化用の純粋関数（WPH→FOUP数・滞留数・速度の写像）
enum FloorVizMath {
    /// FOUP 1台の間隔（pt）
    static let queueSpacing: CGFloat = 11.5
    /// 律速工程中心から手前に空ける距離（pt）
    static let queueStandoff: CGFloat = 7
    /// 本線からサイディングへの横オフセット（pt）
    static let queueSideOffset: CGFloat = 9

    /// 滞留FOUP数。負荷 = ラインWPH ÷ 工程WPH（0...1にクランプ）の6乗×6台。
    /// 負荷1.0（ボトルネック）で6台、0.9で3台、0.8で2台、0.7で1台、それ以下は0台。
    static func queueCount(lineWPH: Double, processWPH: Double) -> Int {
        guard lineWPH > 0, processWPH > 0 else { return 0 }
        let load = min(max(lineWPH / processWPH, 0), 1)
        return min(Int((6.0 * pow(load, 6)).rounded()), 6)
    }

    /// 移動FOUP数。WPHが大きいほど多い（3〜6台）。移動+滞留の合計が12台を超えないよう制限する。
    static func movingFOUPCount(lineWPH: Double, totalQueued: Int) -> Int {
        guard lineWPH > 0 else { return 0 }
        let base = Int((2.0 + lineWPH * 0.35).rounded())
        let scaled = min(max(base, 3), 6)
        let budget = max(12 - totalQueued, 2)
        return min(scaled, budget)
    }

    /// FOUPがパスを1周する所要時間（秒）。WPHが大きいほど速い。
    static func lapPeriod(lineWPH: Double) -> Double {
        min(max(30.0 / max(lineWPH, 0.5), 4.0), 30.0)
    }

    /// targetIndex のベイ中心の手前に並ぶ滞留FOUPの位置（本線から進行方向右側へオフセットしたサイディング上）。
    static func queuePoints(pathPoints: [CGPoint], targetIndex: Int, count: Int) -> [CGPoint] {
        guard count > 0, targetIndex > 0, targetIndex < pathPoints.count else { return [] }
        let lengths = FlowPathMath.segmentLengths(pathPoints)
        guard lengths.count == pathPoints.count - 1 else { return [] }
        var distTarget: CGFloat = 0
        for i in 0..<targetIndex { distTarget += lengths[i] }
        let a = pathPoints[targetIndex - 1]
        let b = pathPoints[targetIndex]
        let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
        let dirX = (b.x - a.x) / len
        let dirY = (b.y - a.y) / len
        // 画面座標（y下向き）で進行方向の右側
        let rightX = -dirY
        let rightY = dirX
        var result: [CGPoint] = []
        for i in 0..<count {
            let d = max(distTarget - queueStandoff - queueSpacing * CGFloat(i), 2)
            let base = FlowPathMath.point(on: pathPoints, at: d)
            result.append(CGPoint(x: base.x + rightX * queueSideOffset, y: base.y + rightY * queueSideOffset))
        }
        return result
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

private struct EquipmentPainter {
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
