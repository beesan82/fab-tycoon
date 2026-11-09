import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(state: store.state, derived: store.derived)
            Divider()
            if store.shouldShowScaleNotice {
                ScaleNoticeBanner {
                    store.dismissScaleNotice()
                }
            }
            TabView(selection: $store.selectedTab) {
                LineView()
                    .tabItem { Label("フロア", systemImage: "square.grid.3x3.fill") }
                    .tag(AppTab.line)
                ShopView()
                    .tabItem { Label("装置", systemImage: "cart") }
                    .tag(AppTab.shop)
                ProductsView()
                    .tabItem { Label("製品", systemImage: "shippingbox") }
                    .tag(AppTab.products)
                ResearchView()
                    .tabItem { Label("研究", systemImage: "flask") }
                    .tag(AppTab.research)
                    .badge(store.state.research.hasUnseenCompletion ? Text("!") : nil)
                GlossaryView()
                    .tabItem { Label("図鑑", systemImage: "book") }
                    .tag(AppTab.glossary)
                StatsView()
                    .tabItem { Label("統計", systemImage: "chart.bar") }
                    .tag(AppTab.stats)
            }
        }
        .sheet(item: $store.offlineReport) { report in
            OfflineReportSheet(report: report) {
                store.dismissOfflineReport()
            }
            .environmentObject(store)
        }
    }
}

// MARK: - ヘッダ

struct HeaderView: View {
    let state: GameState
    let derived: DerivedState

    @State private var showingSettings = false

    var body: some View {
        let node = Engine.currentNode(state: state)
        let product = Catalog.product(id: state.currentProductId) ?? Catalog.defaultProduct
        let condition = derived.marketCondition
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("資金")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MoneyFormat.yen(state.cashYen))
                        .font(.title2.bold())
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("収入/分")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(MoneyFormat.signedYen(derived.incomePerMinuteYen))
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(derived.incomePerMinuteYen >= 0 ? Color.green : Color.red)
                }
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                }
                .accessibilityLabel("設定")
                .padding(.leading, 8)
            }
            HStack(spacing: 8) {
                BadgeView(text: node.displayName, systemImage: "cpu", color: .blue)
                BadgeView(text: product.shortName, systemImage: "shippingbox", color: .purple)
                BadgeView(text: "市況 \(condition.label)", systemImage: condition.symbolName, color: condition.color)
                Spacer()
                if let next = Catalog.nextNode(after: node.id) {
                    let canSwitch = Engine.canSwitchNode(state: state, toNodeId: next.id)
                    BadgeView(text: canSwitch ? next.displayName : "\(next.displayName) 🔒",
                              systemImage: canSwitch ? "arrow.up.forward" : nil,
                              color: canSwitch ? .blue : .gray)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

// MARK: - 研究

struct ResearchView: View {
    @EnvironmentObject private var store: GameStore

    @State private var branch: ResearchBranch = .production

    var body: some View {
        // body は store の更新（tick）ごとに再評価されるので、残り時間は Date() で求めてよい
        let now = Date()
        List {
            Section {
                Picker("系統", selection: $branch) {
                    ForEach(ResearchBranch.allCases) { branch in
                        Text(branch.displayName).tag(branch)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("研究は同時に1件まで。実時間で進み、アプリを閉じている間も進みます。")
            }
            Section {
                ForEach(Catalog.research.filter { $0.branch == branch }) { spec in
                    researchRow(spec, now: now)
                }
            }
        }
        .onAppear {
            store.markResearchCompletionSeen()
        }
    }

    private func researchRow(_ spec: ResearchSpec, now: Date) -> some View {
        let research = store.state.research
        let isCompleted = research.completedIds.contains(spec.id)
        let isInProgress = research.inProgressId == spec.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.name)
                    .font(.headline)
                Spacer()
                statusLabel(isCompleted: isCompleted, isInProgress: isInProgress)
            }
            if isInProgress {
                let remaining = Engine.researchRemainingSeconds(state: store.state, now: now) ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: spec.durationSeconds > 0
                                 ? min(max(1 - remaining / spec.durationSeconds, 0), 1) : 1)
                    Text("あと \(MoneyFormat.duration(remaining))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
            Text(spec.effectText)
                .font(.subheadline.weight(.semibold))
            if let prerequisiteId = spec.prerequisiteId {
                Text("前提: \(Catalog.research(id: prerequisiteId)?.name ?? prerequisiteId)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("費用 \(MoneyFormat.yen(spec.costYen))・約 \(MoneyFormat.duration(spec.durationSeconds))")
                .font(.caption)
                .monospacedDigit()
            Text(spec.learningText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !isCompleted && !isInProgress {
                startArea(spec)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusLabel(isCompleted: Bool, isInProgress: Bool) -> some View {
        if isCompleted {
            Label("完了", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
        } else if isInProgress {
            Label("研究中", systemImage: "hourglass")
                .font(.caption.bold())
                .foregroundStyle(.orange)
        } else {
            Text("未着手")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func startArea(_ spec: ResearchSpec) -> some View {
        let canStart = Engine.canStartResearch(state: store.state, researchId: spec.id)
        Button {
            _ = store.startResearch(spec.id)
        } label: {
            Text("研究を開始する")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canStart)
        if !canStart, let reason = Engine.researchBlockReason(state: store.state, researchId: spec.id) {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 旧セーブ告知バナー

struct ScaleNoticeBanner: View {
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text("1.0アップデートでフロアが自由配置になりました。以前のセーブはそのまま使え、装置は自動で配置されています。フロアの「編集」から並べ替えやレールの引き直しができます。")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("閉じる")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.1))
    }
}

// MARK: - 設定

struct SettingsView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingFirstConfirm = false
    @State private var showingSecondConfirm = false

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "バージョン \(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(versionText)
                        .monospacedDigit()
                }

                Section {
                    Button(role: .destructive) {
                        showingFirstConfirm = true
                    } label: {
                        Text("新規開始")
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("セーブは自動で保存されます。新規開始すると、現在のセーブは削除されて初期状態から始まります。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .alert("新規開始しますか？", isPresented: $showingFirstConfirm) {
                Button("新規開始", role: .destructive) {
                    // 1つ目のアラートが閉じてから2つ目を出す
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showingSecondConfirm = true
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("現在の資金・装置・記録はすべて消えます。")
            }
            .alert("本当に新規開始しますか？", isPresented: $showingSecondConfirm) {
                Button("新規開始する", role: .destructive) {
                    store.resetGame()
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この操作は取り消せません。")
            }
        }
    }
}

struct BadgeView: View {
    let text: String
    let systemImage: String?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

extension MarketCondition {
    var color: Color {
        switch self {
        case .boom: return .green
        case .normal: return .secondary
        case .slump: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .boom: return "arrow.up.right"
        case .normal: return "arrow.right"
        case .slump: return "arrow.down.right"
        }
    }
}

// MARK: - おかえりシート（簡易版）

struct OfflineReportSheet: View {
    @EnvironmentObject private var store: GameStore

    let report: OfflineReport
    let onClose: () -> Void

    /// 例：「効率50%・上限4時間」（研究の効果を含めて Engine から組み立てる）
    private var conditionText: String {
        let efficiency = Int((Engine.offlineEfficiency(state: store.state) * 100).rounded())
        let capHours = Int(Engine.offlineCapSeconds(state: store.state) / 3_600)
        return "効率\(efficiency)%・上限\(capHours)時間"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
            Text("おかえりなさい")
                .font(.title2.bold())
            Text("不在の \(MoneyFormat.duration(report.elapsedSeconds)) の間もファブは稼働していました（\(conditionText)）")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                reportRow("投入ウェハ", "\(MoneyFormat.decimal(report.producedWafers, digits: 1)) 枚")
                reportRow("良品チップ", "\(MoneyFormat.count(report.goodChips)) 個")
                reportRow("売上", MoneyFormat.yen(report.revenueYen))
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

            // 次の一手アドバイザー
            Label(Engine.advisorMessage(state: store.state, derived: store.derived), systemImage: "lightbulb")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.4)))

            Button(action: onClose) {
                Text("受け取る")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        // アドバイザー行の分だけ高さが伸びることがあるので、全画面へも広げられるようにする
        .presentationDetents([.medium, .large])
    }

    private func reportRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .bold()
        }
    }
}
