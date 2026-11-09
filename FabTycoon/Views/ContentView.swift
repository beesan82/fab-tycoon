import SwiftUI

// MARK: - ルート（R1 マップ中心）
// 設計書 design/simcity-rebuild.md §1.1・§1.4・§1.5。MapScene を全面に敷き、HUD とドックを重ねる。
// フロア上のカード（ToolCard・BuildDrawer・ProblemsPopover）はシートにせず自前のオーバーレイで出す。
// シートは施設（建物に入る）・オフライン報告・ようこそカードだけ。

struct ContentView: View {
    @EnvironmentObject private var store: GameStore

    @State private var placement: PlacementRequest?
    @State private var focusRequest: MapFocusRequest?
    @State private var moveRequest: UUID?
    @State private var buildDrawerPresented = false
    @State private var problemsPresented = false
    @State private var facilityRowPresented = false
    @State private var activeFacilitySheet: FacilitySheetKind?
    @State private var glossaryTargetId: String?
    /// 123 オーバーレイ（UserDefaults に保存、セーブには入れない。§1.5）
    @AppStorage("showNumbersOverlay") private var showNumbers = false
    @State private var advisorVisible = false
    @State private var welcomePresented = false
    @State private var focusNonce = 0
    @State private var toastText: String?
    @State private var toastNonce = 0

    /// アドバイザー吹き出しを出しておく秒数（§1.4）
    static let advisorDisplaySeconds: Double = 12
    static let toastDisplaySeconds: Double = 4

    var body: some View {
        let state = store.state
        let derived = store.derived
        let problems = Self.problemSummary(store: store)
        let advisorText = currentAdvisorText(state: state, derived: derived)
        ZStack {
            MapScene(selectedToolId: $store.selectedToolId,
                     placement: $placement,
                     focusRequest: $focusRequest,
                     moveRequest: $moveRequest,
                     onOpenFacility: { kind in openFacilitySheet(kind) },
                     onOpenEntry: { activeFacilitySheet = .entry },
                     onOpenShipping: { activeFacilitySheet = .shipping })
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HUDView(state: state, derived: derived, showNumbers: $showNumbers) {
                    showThroughputToast(state: state, derived: derived)
                }
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    bubbleArea(advisorText: advisorText)
                    if facilityRowPresented {
                        facilityRow
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    bottomCard
                }
                .padding(.bottom, 8)
                DockView(problemsCount: problems.count,
                         problemsCritical: problems.critical,
                         buildBadgeCount: state.fab.storedEquipment.count,
                         facilityBadgeCount: facilityBadgeCount(state: state),
                         onBuild: openBuildDrawer,
                         onProblems: openProblems,
                         onFacilities: {
                             withAnimation(.easeOut(duration: 0.2)) { facilityRowPresented.toggle() }
                         })
            }
        }
        .task(id: advisorText) {
            // 同じ文言の間は 12 秒で畳み、文言が変わったら（id が変わってタスクが再起動して）再表示する
            guard advisorText != nil else {
                advisorVisible = false
                return
            }
            withAnimation { advisorVisible = true }
            try? await Task.sleep(for: .seconds(Self.advisorDisplaySeconds))
            guard !Task.isCancelled else { return }
            withAnimation { advisorVisible = false }
        }
        .task(id: toastNonce) {
            guard toastText != nil else { return }
            try? await Task.sleep(for: .seconds(Self.toastDisplaySeconds))
            guard !Task.isCancelled else { return }
            withAnimation { toastText = nil }
        }
        .sheet(item: $activeFacilitySheet) { kind in
            FacilitySheetView(kind: kind, glossaryTargetId: glossaryTargetId)
                .environmentObject(store)
        }
        .sheet(item: $store.offlineReport, onDismiss: presentWelcomeIfNeeded) { report in
            OfflineReportSheet(report: report) {
                store.dismissOfflineReport()
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $welcomePresented) {
            WelcomeCardView {
                store.dismissWelcomeCard()
                welcomePresented = false
            }
            .environmentObject(store)
        }
        .onChange(of: activeFacilitySheet) { _, newValue in
            // 図鑑の該当エントリ指定は 1 回限り（次に資料室を開いたときは一覧から）
            if newValue == nil { glossaryTargetId = nil }
        }
        .onAppear {
            // オフライン報告と同時には出せないので、報告がある場合は閉じたあとに出す
            if store.offlineReport == nil { presentWelcomeIfNeeded() }
        }
    }

    // MARK: 下部オーバーレイ

    /// ドロワー・問題・装置カードは同じ場所を使うので、同時には 1 枚だけ出す
    @ViewBuilder
    private var bottomCard: some View {
        if problemsPresented {
            ProblemsPopover(
                onClose: { problemsPresented = false },
                onFocusTool: { toolId in
                    focus(toolId: toolId)
                    problemsPresented = false
                },
                onFocusPoint: { point in
                    focus(point: point)
                    problemsPresented = false
                },
                onOpenBuild: { process in
                    problemsPresented = false
                    openBuild(process: process)
                },
                onResolveDeadlock: {
                    let result = store.resolveDeadlock()
                    problemsPresented = false
                    showToast(result.scrapped > 0
                              ? "詰まりを解消：\(result.moved)ロットをストッカーへ、\(result.scrapped)ロットを廃棄"
                              : "詰まりを解消：\(result.moved)ロットをストッカーへ移しました")
                })
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if buildDrawerPresented {
            BuildDrawer(placement: $placement,
                        onClose: { buildDrawerPresented = false },
                        onEnterRailMode: {
                            buildDrawerPresented = false
                            store.railMode = true
                        })
            .transition(.move(edge: .bottom))
        } else if let toolId = store.selectedToolId, placement == nil {
            ToolCard(toolId: toolId,
                     onClose: { store.selectedToolId = nil },
                     onMove: { toolId in moveRequest = toolId },
                     onOpenGlossary: { entryId in
                         glossaryTargetId = entryId
                         activeFacilitySheet = .library
                     },
                     onOpenBuild: { process in openBuild(process: process) })
            .transition(.move(edge: .bottom))
        }
    }

    /// トースト（優先）かアドバイザー吹き出しの 1 行。問題ポップオーバー表示中は最上段に同じ文が出るので隠す
    @ViewBuilder
    private func bubbleArea(advisorText: String?) -> some View {
        if let toastText {
            Text(toastText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(.horizontal, 12)
                .onTapGesture { withAnimation { self.toastText = nil } }
                .transition(.opacity)
        } else if advisorVisible, let advisorText, !problemsPresented {
            Button {
                openProblems()
            } label: {
                Label(advisorText, systemImage: "lightbulb")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .transition(.opacity)
        }
    }

    // MARK: 施設ショートカット列（§1.4）

    private var facilityRow: some View {
        HStack(spacing: 6) {
            facilityShortcut("事務所", systemImage: "building.2") { openFacilityShortcut(.office) }
            facilityShortcut("研究棟", systemImage: "flask") { openFacilityShortcut(.research) }
            facilityShortcut("資料室", systemImage: "books.vertical") { openFacilityShortcut(.library) }
            facilityShortcut("投入口", systemImage: "tray.and.arrow.down") { openEntryShortcut() }
            facilityShortcut("出荷口", systemImage: "shippingbox") { openShippingShortcut() }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .padding(.horizontal, 12)
    }

    private func facilityShortcut(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openFacilityShortcut(_ kind: FacilityKind) {
        if let layout = store.state.fab.layout {
            focus(point: MapScene.facilityCenter(kind, layout: layout))
        }
        facilityRowPresented = false
        openFacilitySheet(kind)
    }

    private func openEntryShortcut() {
        if let layout = store.state.fab.layout, let center = Self.centroid(layout.entryCells()) {
            focus(point: center)
        }
        facilityRowPresented = false
        activeFacilitySheet = .entry
    }

    private func openShippingShortcut() {
        if let layout = store.state.fab.layout, let center = Self.centroid(layout.shippingCells()) {
            focus(point: center)
        }
        facilityRowPresented = false
        activeFacilitySheet = .shipping
    }

    private func openFacilitySheet(_ kind: FacilityKind) {
        switch kind {
        case .office: activeFacilitySheet = .office
        case .research: activeFacilitySheet = .research
        case .library: activeFacilitySheet = .library
        }
    }

    // MARK: ドック・カメラ

    private func openBuildDrawer() {
        withAnimation(.easeOut(duration: 0.2)) {
            problemsPresented = false
            facilityRowPresented = false
            buildDrawerPresented = true
        }
    }

    private func openProblems() {
        withAnimation(.easeOut(duration: 0.2)) {
            buildDrawerPresented = false
            facilityRowPresented = false
            problemsPresented = true
        }
    }

    /// 工程を絞って建設ドロワーの「購入」を開く（ToolCard・問題ポップオーバーから）
    private func openBuild(process: ProcessType?) {
        store.openBuild(process: process)
        openBuildDrawer()
    }

    private func focus(point: GridPoint) {
        focusNonce += 1
        focusRequest = MapFocusRequest(point: point, nonce: focusNonce)
    }

    private func focus(toolId: UUID) {
        focusNonce += 1
        focusRequest = MapFocusRequest(toolId: toolId, nonce: focusNonce)
    }

    private static func centroid(_ cells: [GridPoint]) -> GridPoint? {
        guard !cells.isEmpty else { return nil }
        let x = Double(cells.reduce(0) { $0 + $1.x }) / Double(cells.count)
        let y = Double(cells.reduce(0) { $0 + $1.y }) / Double(cells.count)
        return GridPoint(x: Int(x.rounded(.down)), y: Int(y.rounded(.down)))
    }

    // MARK: トースト・アドバイザー・ようこそ

    private func currentAdvisorText(state: GameState, derived: DerivedState) -> String? {
        let message = Engine.advisorMessage(state: state, derived: derived)
        return message.isEmpty ? nil : message
    }

    /// HUD の WPH タップ：「実測 8.3 WPH／理論上限 8.5 WPH（律速：成膜）」（§3.5）
    private func showThroughputToast(state: GameState, derived: DerivedState) {
        let measured = MoneyFormat.decimal(state.fab.sim?.throughputEMA ?? 0, digits: 1)
        let theoretical = MoneyFormat.decimal(derived.lineWPH, digits: 1)
        var text = "実測 \(measured) WPH／理論上限 \(theoretical) WPH"
        if let bottleneck = derived.bottleneck {
            text += "（律速：\(bottleneck.displayName)）"
        }
        showToast(text)
    }

    private func showToast(_ text: String) {
        withAnimation { toastText = text }
        toastNonce += 1
    }

    private func presentWelcomeIfNeeded() {
        guard store.shouldShowWelcomeCard else { return }
        // 直前のシートが閉じ切ってから出す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if store.shouldShowWelcomeCard { welcomePresented = true }
        }
    }

    // MARK: バッジ

    /// 研究完了未読＋補助金申請可＋図鑑未読（図鑑は MapScene の資料室バッジと同じ数え方）
    private func facilityBadgeCount(state: GameState) -> Int {
        let unreadGlossary = Engine.glossaryEntries(state: state).filter { $0.unlocked && !$0.isRead }.count
        return (state.research.hasUnseenCompletion ? 1 : 0)
            + (Engine.canApplySubsidy(state: state) ? 1 : 0)
            + unreadGlossary
    }

    /// ドック「問題」の件数と赤バッジ判定（§1.4・§3.4）。
    /// layoutProblems ＋ 詰まり ＋ ライン停止 ＋ 歩留まり異常 ＋ ストッカー満杯。ProblemsPopover の行と揃えること
    static func problemSummary(store: GameStore) -> (count: Int, critical: Bool) {
        let state = store.state
        let deadlocked = store.simDeadlocked
        let lineStopped = store.derived.lineWPH <= 0 && !state.fab.placed.isEmpty
        let excursion = state.activeExcursion != nil
        let stockerFull = state.fab.sim.map { $0.stocker.capacity > 0 && $0.stocker.lotIds.count >= $0.stocker.capacity } ?? false
        let count = store.layoutProblems.count
            + (deadlocked ? 1 : 0)
            + (lineStopped ? 1 : 0)
            + (excursion ? 1 : 0)
            + (stockerFull ? 1 : 0)
        return (count, deadlocked || lineStopped)
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
