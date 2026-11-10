import SwiftUI

// MARK: - R1 ToolCard（装置をタップしたときの下部カード）
// 設計書 design/simcity-rebuild.md §2.3・§2.4。シートにせず ContentView の自前オーバーレイで出す。
// 3 段の高さ（コンパクト 176pt／展開 56%／全画面）を上端グラバーのドラッグで切り替える。
// 状態ラベルは MapScene の FloorDrawData のランプ判定（異常の原因 → 未接続・非対応 → 行き先なし → 処理中 → 待ち）と同じ順で決める。
// 旧 ProcessDetailView の infoRow 群・EquipmentRow の改良表示・sellMessage・EquipmentEducationBlock をここへ移植した
// （ProcessDetailView には依存しない）。

/// ToolCard の高さの段
enum ToolCardDetent: Int {
    case compact
    case expanded
    case full
}

struct ToolCard: View {
    @EnvironmentObject private var store: GameStore

    let toolId: UUID
    var onClose: () -> Void
    var onMove: (UUID) -> Void
    var onOpenGlossary: (String) -> Void
    var onOpenBuild: (ProcessType?) -> Void

    @State private var detent: ToolCardDetent = .compact
    @State private var showsLearnPage = false
    @State private var confirmsSell = false
    /// 回転・倉庫へが失敗したときの理由（数秒で消す）
    @State private var actionMessage: String?
    @State private var actionMessageNonce = 0

    static let compactHeight: CGFloat = 176
    static let expandedFraction: CGFloat = 0.56
    static let actionMessageSeconds: Double = 3

    var body: some View {
        if let info = ToolCardInfo(state: store.state, derived: store.derived, toolId: toolId) {
            card(info)
        } else {
            EmptyView()
        }
    }

    // MARK: カード本体

    private func card(_ info: ToolCardInfo) -> some View {
        VStack(spacing: 0) {
            grabber
            if showsLearnPage {
                learnPage(info)
            } else {
                header(info)
                    .padding(.horizontal, 12)
                if detent != .compact {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            processSection(info)
                            toolSection(info)
                            upgradeSection(info)
                            sellSection(info)
                            if detent == .full {
                                siblingSection(info)
                            }
                        }
                        .padding(12)
                    }
                } else {
                    Spacer(minLength: 0)
                }
                actionRow(info)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .toolCardHeight(detent)
        .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .top) {
            if let actionMessage {
                Text(actionMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.red.opacity(0.9)))
                    .padding(.top, 18)
                    .padding(.horizontal, 12)
                    .onTapGesture { withAnimation { self.actionMessage = nil } }
                    .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        .padding(.horizontal, 8)
        .task(id: actionMessageNonce) {
            guard actionMessage != nil else { return }
            try? await Task.sleep(for: .seconds(Self.actionMessageSeconds))
            guard !Task.isCancelled else { return }
            withAnimation { actionMessage = nil }
        }
        .onChange(of: toolId) { _, _ in
            // 同工程リストから別の装置へ移ったら、本体ページに戻す（高さは保つ）
            showsLearnPage = false
            actionMessage = nil
        }
        .confirmationDialog(
            "装置を売却しますか？",
            isPresented: $confirmsSell,
            titleVisibility: .visible
        ) {
            Button("売却する（+\(MoneyFormat.yen(Engine.sellRefundYen(instance: info.instance)))）", role: .destructive) {
                if store.sellEquipment(info.tool.id) {
                    onClose()
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(Self.sellMessage(for: info, state: store.state, derived: store.derived))
        }
    }

    /// 上端のグラバー（上へドラッグで 1 段広げ、下へで 1 段縮める。コンパクトで下へなら閉じる）と閉じるボタン
    private var grabber: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("閉じる"))
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    let dy = value.translation.height
                    if dy < -40 {
                        stepDetent(by: 1)
                    } else if dy > 40 {
                        if detent == .compact {
                            onClose()
                        } else {
                            stepDetent(by: -1)
                        }
                    }
                }
        )
        .onTapGesture {
            // タップでも段を回せる（ドラッグに気づかない人向け）
            withAnimation(.easeOut(duration: 0.2)) {
                detent = detent == .full ? .compact : ToolCardDetent(rawValue: detent.rawValue + 1) ?? .full
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("カードの高さを切り替える"))
    }

    private func stepDetent(by delta: Int) {
        let next = min(max(detent.rawValue + delta, ToolCardDetent.compact.rawValue), ToolCardDetent.full.rawValue)
        withAnimation(.easeOut(duration: 0.2)) {
            detent = ToolCardDetent(rawValue: next) ?? .compact
        }
    }

    // MARK: コンパクト面

    private func header(_ info: ToolCardInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            EquipmentThumbnail(model: info.model)
                .frame(width: 56, height: 56)
                .grayscale(info.status == .standby ? 1 : 0)
                .opacity(info.status == .standby ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(info.model.id) \(info.model.name) #\(info.serial)")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("Lv\(info.tool.level)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    Spacer(minLength: 4)
                    statusLabel(info.status)
                }
                HStack(spacing: 6) {
                    if info.isBottleneck {
                        chip("律速", color: .red)
                    }
                    if let text = info.unconnectedText {
                        chip(text, color: .gray)
                    }
                    Text("待ち \(info.waitingLots) FOUP ／ 稼働率 \(MoneyFormat.percent(info.utilization, digits: 0))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                HStack(spacing: 6) {
                    if let rank = info.stepRank {
                        stepBadge(rank, color: info.model.process.accent)
                    }
                    Text("\(info.model.process.displayName)（\(info.passes) パス）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func statusLabel(_ status: ToolCardStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.lampColor)
                .overlay(Circle().stroke(Color.gray.opacity(status == .idle ? 0.8 : 0), lineWidth: 1))
                .frame(width: 9, height: 9)
            Text(status.label)
                .font(.caption.bold())
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
            .fixedSize()
    }

    /// 工程順バッジ（フロアの ①② と同じ番号）
    private func stepBadge(_ rank: Int, color: Color) -> some View {
        Text("\(rank)")
            .font(.caption2.bold())
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(color))
    }

    /// 最下段のボタン列（改良／移動／回転／倉庫へ／売却／学ぶ）
    private func actionRow(_ info: ToolCardInfo) -> some View {
        let state = store.state
        let cost = info.upgradeCostYen
        let canUpgrade = cost.map { state.cashYen >= $0 } ?? false
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    store.upgrade(info.tool.id)
                } label: {
                    actionLabel(
                        cost.map { "改良 \(MoneyFormat.yen($0))" } ?? "改良（最大Lv）",
                        sub: upgradeSubtitle(info, cost: cost, canUpgrade: canUpgrade))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUpgrade)

                Button {
                    onMove(info.tool.id)
                } label: {
                    actionLabel("移動", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                .buttonStyle(.bordered)

                Button {
                    rotate(info)
                } label: {
                    actionLabel("回転", systemImage: "rotate.right")
                }
                .buttonStyle(.bordered)

                Button {
                    if store.removePlacedToolToStorage(toolId: info.tool.id) {
                        onClose()
                    } else {
                        showActionMessage("倉庫へ戻せません：ポートのロットを移すストッカーに空きがありません")
                    }
                } label: {
                    actionLabel("倉庫へ", systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)
                .tint(info.status == .standby ? .orange : nil)

                Button(role: .destructive) {
                    confirmsSell = true
                } label: {
                    actionLabel("売却", sub: "+\(MoneyFormat.yen(Engine.sellRefundYen(instance: info.instance)))")
                }
                .buttonStyle(.bordered)

                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showsLearnPage = true }
                } label: {
                    actionLabel("学ぶ", systemImage: "book")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func upgradeSubtitle(_ info: ToolCardInfo, cost: Double?, canUpgrade: Bool) -> String {
        guard let cost else { return "これ以上改良できません" }
        if !canUpgrade {
            return "資金不足（あと\(MoneyFormat.yen(cost - store.state.cashYen))）"
        }
        let after = Engine.lineWPHAfterUpgrading(state: store.state, instanceId: info.tool.id)
        return "ライン \(MoneyFormat.decimal(store.derived.lineWPH)) → \(MoneyFormat.decimal(after))"
    }

    private func actionLabel(_ title: String, sub: String? = nil, systemImage: String? = nil) -> some View {
        VStack(spacing: 2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
            }
            Text(title)
                .font(.caption.bold())
                .lineLimit(1)
            if let sub {
                Text(sub)
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 44, minHeight: 36)
    }

    private func rotate(_ info: ToolCardInfo) {
        guard !store.rotatePlacedTool(toolId: info.tool.id) else { return }
        showActionMessage(Self.rotateFailureReason(state: store.state, toolId: info.tool.id))
    }

    private func showActionMessage(_ text: String) {
        withAnimation { actionMessage = text }
        actionMessageNonce += 1
    }

    /// rotatePlacedTool は Bool しか返さないので、失敗理由は同じ検証（配置エラー → ロット退避）をなぞって作る
    static func rotateFailureReason(state: GameState, toolId: UUID) -> String {
        guard let layout = state.fab.layout,
              let tool = state.fab.placed.first(where: { $0.id == toolId })
        else { return "回転できません" }
        let rotation = (((tool.rotation % 360) + 360) % 360 + 90) % 360
        let others = state.fab.placed.filter { $0.id != toolId }
        if let error = layout.toolPlacementError(tool, origin: tool.origin, rotation: rotation, among: others) {
            return "回転できません：\(error)"
        }
        return "回転できません：ポートのロットを移すストッカーに空きがありません"
    }

    // MARK: 展開面

    private func processSection(_ info: ToolCardInfo) -> some View {
        let state = store.state
        let derived = store.derived
        let process = info.model.process
        return sectionBox("\(process.displayName)工程") {
            infoRow("工程の実効WPH", "\(MoneyFormat.decimal(derived.wph(process), digits: 2)) WPH")
            infoRow("稼働台数", "\(derived.units(process))台")
            let standby = Engine.standbyCount(state: state, process: process)
            if standby > 0 {
                infoRow("待機台数", "\(standby)台")
            }
            infoRow("パス数（\(Engine.currentNode(state: state).displayName)）", "\(info.passes)")
            infoRow("工程歩留まり", MoneyFormat.percent(derived.processYields[process] ?? 0))
            if process == .inspection {
                infoRow("検査検出率", MoneyFormat.percent(derived.detectionRate))
            }
            if derived.bottleneck == process {
                Label("この工程がボトルネックです", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else if derived.secondBottleneck == process {
                Label("次のボトルネック候補です", systemImage: "exclamationmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Button {
                onOpenBuild(process)
            } label: {
                Label("この工程の装置を買う", systemImage: "plus.circle.fill")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
        }
    }

    private func toolSection(_ info: ToolCardInfo) -> some View {
        let state = store.state
        let unit = Engine.unitWPH(model: info.model, level: info.tool.level, state: state)
        return sectionBox("この装置") {
            infoRow("状態", info.status.label)
            infoRow("1台あたり実効WPH", info.status == .standby
                    ? "0.00（待機中）"
                    : "\(MoneyFormat.decimal(unit, digits: 2))（稼働率適用前）")
            infoRow("稼働率（直近24時間）", MoneyFormat.percent(info.utilization))
            infoRow("ポートのFOUP", "\(info.portLots) ／ \(info.tool.ports.count)")
            infoRow("配置", "(\(info.tool.origin.x), \(info.tool.origin.y)) ／ \(info.tool.rotation)°")
            if info.status == .standby {
                Text("待機中：現在のノード（\(Engine.currentNode(state: state).displayName)）では稼働しません。フロアを空けるなら倉庫へ外しましょう。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let text = info.unconnectedText {
                Text("\(text)：レールにつながっていないため、FOUP が届きません（建設 → レール）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func upgradeSection(_ info: ToolCardInfo) -> some View {
        let state = store.state
        let derived = store.derived
        let process = info.model.process
        return sectionBox("改良（Lv\(info.tool.level) → Lv\(info.tool.level + 1)）") {
            if let cost = info.upgradeCostYen {
                infoRow("費用", MoneyFormat.yen(cost))
                let after = Engine.lineWPHAfterUpgrading(state: state, instanceId: info.tool.id)
                fromToRow("ラインWPH", from: MoneyFormat.decimal(derived.lineWPH), to: MoneyFormat.decimal(after),
                          improved: after > derived.lineWPH + 1e-9)
                let yieldNow = derived.processYields[process] ?? 0
                let yieldAfter = Engine.processYieldAfterUpgrading(state: state, instanceId: info.tool.id)
                fromToRow("工程歩留まり", from: MoneyFormat.percent(yieldNow), to: MoneyFormat.percent(yieldAfter),
                          improved: yieldAfter > yieldNow + 1e-9)
                if process == .inspection {
                    let detectionAfter = Engine.detectionRateAfterUpgrading(state: state, instanceId: info.tool.id)
                    fromToRow("検出率", from: MoneyFormat.percent(derived.detectionRate), to: MoneyFormat.percent(detectionAfter),
                              improved: detectionAfter > derived.detectionRate + 1e-9)
                }
                if state.cashYen < cost {
                    Text("資金不足（あと\(MoneyFormat.yen(cost - state.cashYen))）")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text("最大レベルです")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sellSection(_ info: ToolCardInfo) -> some View {
        let state = store.state
        let derived = store.derived
        let process = info.model.process
        let after = Engine.lineWPHAfterSelling(state: state, instanceId: info.tool.id)
        let yieldNow = derived.processYields[process] ?? 0
        let yieldAfter = Engine.processYieldAfterSelling(state: state, instanceId: info.tool.id)
        let unitsAfter = Engine.activeUnitsAfterSelling(state: state, instanceId: info.tool.id)
        return sectionBox("売却（モデル価格の50%）") {
            infoRow("返金", "+\(MoneyFormat.yen(Engine.sellRefundYen(instance: info.instance)))")
            fromToRow("ラインWPH", from: MoneyFormat.decimal(derived.lineWPH), to: MoneyFormat.decimal(after),
                      improved: false)
            fromToRow("工程歩留まり", from: MoneyFormat.percent(yieldNow), to: MoneyFormat.percent(yieldAfter),
                      improved: yieldAfter > yieldNow + 1e-9)
            if process == .inspection {
                let detectionAfter = Engine.detectionRateAfterSelling(state: state, instanceId: info.tool.id)
                fromToRow("検出率", from: MoneyFormat.percent(derived.detectionRate), to: MoneyFormat.percent(detectionAfter),
                          improved: false)
            }
            fromToRow("稼働台数", from: "\(derived.units(process))台", to: "\(unitsAfter)台", improved: false)
            if derived.units(process) > 0 && unitsAfter == 0 {
                Label("売ると\(process.displayName)の装置が0台になり、ラインが停止します", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 全画面段のみ：同じ工程の他の装置（タップで選択を移す）
    private func siblingSection(_ info: ToolCardInfo) -> some View {
        let state = store.state
        let siblings = Engine.installedTools(state: state).filter {
            $0.id != info.tool.id && Catalog.model(id: $0.modelId)?.process == info.model.process
        }
        return sectionBox("同じ工程の他の装置（\(siblings.count)台）") {
            if siblings.isEmpty {
                Text("この工程の装置はこれ 1 台だけです。止まるとライン全体が停止します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(siblings) { sibling in
                if let siblingInfo = ToolCardInfo(state: state, derived: store.derived, toolId: sibling.id) {
                    Button {
                        store.selectedToolId = sibling.id
                    } label: {
                        HStack(spacing: 8) {
                            EquipmentThumbnail(model: siblingInfo.model)
                                .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(siblingInfo.model.name) #\(siblingInfo.serial)")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text("Lv\(siblingInfo.tool.level) ・ 待ち \(siblingInfo.waitingLots) FOUP ・ 稼働率 \(MoneyFormat.percent(siblingInfo.utilization, digits: 0))")
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            statusLabel(siblingInfo.status)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 学ぶページ

    private func learnPage(_ info: ToolCardInfo) -> some View {
        let glossaryId = Self.glossaryEntryId(for: info.model, state: store.state)
        return VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showsLearnPage = false }
                } label: {
                    Label("戻る", systemImage: "chevron.left")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(info.model.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                if let glossaryId {
                    Button {
                        onOpenGlossary(glossaryId)
                    } label: {
                        Label("図鑑で読む", systemImage: "books.vertical")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            ScrollView {
                Group {
                    if let education = Catalog.education(for: info.model.id) {
                        ToolEducationBlock(education: education)
                    } else {
                        Text("この装置の解説はまだありません")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    /// 装置の図鑑エントリ（Catalog.equipmentGlossaryId、Engine.glossaryEntries に解放済みで載っているときだけ）
    static func glossaryEntryId(for model: EquipmentModel, state: GameState) -> String? {
        let id = Catalog.equipmentGlossaryId(model.id)
        let entry = Engine.glossaryEntries(state: state).first { $0.id == id && $0.kind == .equipment }
        return entry?.unlocked == true ? id : nil
    }

    // MARK: 売却確認の文言（旧 ProcessDetailView.sellMessage と同じ）

    static func sellMessage(for info: ToolCardInfo, state: GameState, derived: DerivedState) -> String {
        let instance = info.instance
        let process = info.model.process
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

    // MARK: 表示部品

    private func sectionBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill)))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
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

// MARK: - 状態ラベル

/// 装置の状態（MapScene のランプ色と対応：緑＝稼働中、黄＝待機、青＝行き先なし、灰＝未接続／非対応、赤＝異常の原因）
enum ToolCardStatus: Equatable {
    /// 歩留まり異常（activeExcursion）の原因装置
    case excursion
    /// 入口・出口のどちらかがレールにつながっていない
    case unconnected
    /// 現在ノード非対応で稼働しない
    case standby
    /// 処理済みロットの行き先が無い
    case noDestination
    /// 処理中のポートがある
    case running
    /// 処理待ち・払い出し待ちのロットだけ
    case waiting
    /// ポートが空
    case idle

    var label: String {
        switch self {
        case .excursion: return "異常"
        case .unconnected: return "未接続"
        case .standby: return "待機（ノード非対応）"
        case .noDestination: return "行き先なし"
        case .running: return "稼働中"
        case .waiting: return "待機"
        case .idle: return "待機（ロットなし）"
        }
    }

    var lampColor: Color {
        switch self {
        case .excursion: return .red
        case .unconnected, .standby: return .gray
        case .noDestination: return .blue
        case .running: return .green
        case .waiting: return .yellow
        case .idle: return .white
        }
    }
}

/// カード 1 枚分の表示データ。配置は fab.placed、ポート・稼働率は fab.sim の装置を正とする（FloorDrawData と同じ）
struct ToolCardInfo {
    let tool: ToolInstance
    let model: EquipmentModel
    let instance: EquipmentInstance
    /// 同モデルの通し番号（購入順、1 始まり）
    let serial: Int
    let status: ToolCardStatus
    /// 処理待ち（.waiting）のポート数
    let waitingLots: Int
    /// ロットが載っているポート数
    let portLots: Int
    /// 直近24ゲーム時間の稼働率（busyEMA、0〜1）
    let utilization: Double
    let unconnectedInput: Bool
    let unconnectedOutput: Bool
    /// ルートで工程が最初に現れる順位（工程順バッジ）
    let stepRank: Int?
    /// 現在ノードでのパス数
    let passes: Int
    /// 律速：工程が derived.bottleneck と一致し、待ちがある
    let isBottleneck: Bool
    let upgradeCostYen: Double?

    init?(state: GameState, derived: DerivedState, toolId: UUID) {
        let installed = Engine.installedTools(state: state)
        guard var tool = installed.first(where: { $0.id == toolId }),
              let model = Catalog.model(id: tool.modelId)
        else { return nil }
        let sim = state.fab.sim
        if let simTool = sim?.tools.first(where: { $0.id == toolId }) {
            tool.ports = simTool.ports
            tool.busyEMA = simTool.busyEMA
        }
        let instance = Engine.equipmentInstance(tool)
        self.tool = tool
        self.model = model
        self.instance = instance

        let sameModel = installed
            .filter { $0.modelId == tool.modelId }
            .sorted { ($0.purchasedAt, $0.id.uuidString) < ($1.purchasedAt, $1.id.uuidString) }
        serial = (sameModel.firstIndex(where: { $0.id == toolId }) ?? 0) + 1

        var input = false
        var output = false
        for problem in Engine.layoutProblems(state: state) {
            switch problem {
            case .unconnectedInput(let id, _) where id == toolId:
                input = true
            case .unconnectedOutput(let id, _) where id == toolId:
                output = true
            default:
                break
            }
        }
        unconnectedInput = input
        unconnectedOutput = output

        let nodeId = state.fab.currentNodeId
        let isStandby = !Engine.isActive(model, nodeId: nodeId)
        let states = tool.ports.map { $0.state }
        let stuckDone = tool.ports.contains { port in
            guard port.state == .done, let lotId = port.lotId else { return false }
            return sim?.lots.first(where: { $0.id == lotId })?.destination == nil
        }
        // 原因装置の判定は FloorDrawData の赤ランプと条件を揃える（R2、設計書 §3.1・§7-13、案 A）：
        // ヒント 3 段階目まで進み、かつ現ノードで稼働する Q3 があるときだけ。満たさなければ通常の判定へ
        let hasActiveQ3 = installed.contains { placed in
            guard placed.modelId == "Q3", let q3 = Catalog.model(id: placed.modelId) else { return false }
            return Engine.isActive(q3, nodeId: nodeId)
        }
        let causeToolId = (state.activeExcursion?.hintsRevealed ?? 0) >= 3 && hasActiveQ3
            ? state.activeExcursion?.causeToolId
            : nil
        // 判定順は FloorDrawData のランプと同じ
        if let causeToolId, causeToolId == toolId {
            status = .excursion
        } else if input || output {
            status = .unconnected
        } else if isStandby {
            status = .standby
        } else if stuckDone {
            status = .noDestination
        } else if states.contains(.processing) {
            status = .running
        } else if states.contains(.waiting) || states.contains(.done) {
            status = .waiting
        } else {
            status = .idle
        }

        let waiting = tool.ports.filter { $0.state == .waiting }.count
        waitingLots = waiting
        portLots = tool.ports.filter { $0.lotId != nil }.count
        utilization = min(max(tool.busyEMA, 0), 1)

        let node = Engine.currentNode(state: state)
        let lithoClass = Engine.topLithoClass(state: state)
        stepRank = RouteStepOrder.ranks(node: node, lithoClass: lithoClass)[model.process]
        passes = Engine.passCount(for: model.process, node: node, topLitho: lithoClass)
        isBottleneck = derived.bottleneck == model.process && waiting > 0
        upgradeCostYen = Engine.upgradeCostYen(state: state, instance: instance)
    }

    /// 「未接続（入口）」等のチップ文言。接続済みなら nil
    var unconnectedText: String? {
        switch (unconnectedInput, unconnectedOutput) {
        case (true, true): return "未接続（入口・出口）"
        case (true, false): return "未接続（入口）"
        case (false, true): return "未接続（出口）"
        case (false, false): return nil
        }
    }
}

// MARK: - この装置について（旧 EquipmentEducationBlock 相当）

private struct ToolEducationBlock: View {
    let education: EquipmentEducation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("概要")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(education.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("しくみ")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(education.mechanism)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("豆知識", systemImage: "lightbulb.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                Text(education.trivia)
                    .font(.subheadline)
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

// MARK: - 高さの段

private extension View {
    /// コンパクト＝固定 176pt、展開＝画面の 56%、全画面＝ HUD とドックの間を使い切る
    @ViewBuilder
    func toolCardHeight(_ detent: ToolCardDetent) -> some View {
        switch detent {
        case .compact:
            frame(height: ToolCard.compactHeight)
        case .expanded:
            containerRelativeFrame(.vertical, alignment: .bottom) { length, _ in
                length * ToolCard.expandedFraction
            }
        case .full:
            frame(maxHeight: .infinity)
                .layoutPriority(1)
        }
    }
}
