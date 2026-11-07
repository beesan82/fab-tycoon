import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        let stats = store.state.stats
        let derived = store.derived
        let currentProduct = Engine.currentProduct(state: store.state)
        List {
            Section("目標") {
                ForEach(Catalog.milestones) { spec in
                    milestoneRow(spec, derived: derived)
                }
            }
            Section("国庫補助金") {
                subsidySection
            }
            Section("累計") {
                row("図鑑の解放", "\(Engine.glossaryUnlockedCount(state: store.state))/\(Catalog.glossaryEntryCount)")
                row("売上", MoneyFormat.yen(stats.totalGrossSalesYen))
                row("売上原価", MoneyFormat.yen(stats.totalCogsYen))
                row("粗利", MoneyFormat.yen(stats.totalRevenueYen))
                row("投入ウェハ", "\(MoneyFormat.decimal(stats.totalWafersInput, digits: 1)) 枚")
                row("良品チップ", "\(MoneyFormat.count(stats.totalGoodChips)) 個")
                row("欠陥チップ（検査で廃棄）", "\(MoneyFormat.count(stats.totalDefectChips)) 個")
                row("欠陥による損失", MoneyFormat.yen(stats.defectLossYen))
                row("出荷チップ", "\(MoneyFormat.count(stats.totalShippedChips)) 個")
                row("市場不良チップ", "\(MoneyFormat.count(stats.totalMarketDefectChips)) 個")
                row("市場不良ペナルティ", MoneyFormat.yen(stats.totalMarketPenaltyYen))
                row("総稼働", "\(MoneyFormat.decimal(store.state.gameHoursElapsed / 24, digits: 0))日（ゲーム内）")
                row("プレイ時間", MoneyFormat.duration(stats.playSeconds))
            }
            Section("歩留まり") {
                ForEach(ProcessType.allCases) { process in
                    row(process.displayName, MoneyFormat.percent(derived.processYields[process] ?? 0))
                }
                // ライン歩留まりの内訳 = 1 − (1 − 工程歩留まりの積) × 欠陥の残存率 → 製品倍率を欠陥側に適用
                breakdownHeader("ライン歩留まりの内訳")
                breakdownRow("工程歩留まりの積", MoneyFormat.percent(derived.processYieldProduct))
                breakdownRow("学習による欠陥縮小", "欠陥の残存率 \(MoneyFormat.percent(derived.learningDefectScale))")
                breakdownRow("製品の歩留まり倍率", multiplierText(currentProduct.yieldMultiplier))
                row("＝ ライン歩留まり（検査前）", MoneyFormat.percent(derived.lineYield))
                // 検出率の内訳 = 基礎検出率 ＋ 余裕度ボーナス（上限あり）
                breakdownHeader("検査検出率の内訳")
                breakdownRow("基礎検出率", MoneyFormat.percent(derived.detectionBase))
                breakdownRow("検査能力の余裕度", "×" + MoneyFormat.decimal(derived.detectionHeadroom, digits: 1))
                breakdownRow("余裕度ボーナス", "+" + MoneyFormat.percent(derived.detectionHeadroomBonus))
                if derived.detectionBase + derived.detectionHeadroomBonus > Engine.maxDetectionRate {
                    Text("上限\(MoneyFormat.percent(Engine.maxDetectionRate, digits: 0))で頭打ち")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                row("＝ 検査検出率", MoneyFormat.percent(derived.detectionRate))
                row("出荷良品率", MoneyFormat.percent(derived.shippedYield))
                row("市場不良率", MoneyFormat.percent(derived.marketDefectRate))
            }
            Section("現在") {
                row("ノード", Engine.currentNode(state: store.state).displayName)
                row("製造製品", currentProduct.name)
                row("ラインWPH", MoneyFormat.decimal(derived.lineWPH, digits: 2))
                row("チップ単価", MoneyFormat.yen(derived.currentPriceYen))
                row("収入/分", MoneyFormat.signedYen(derived.incomePerMinuteYen))
                row("ボトルネック", derived.bottleneck?.displayName ?? "—")
                row("市況指数", "\(MoneyFormat.decimal(derived.marketIndex, digits: 2))（\(derived.marketCondition.label)）")
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

    // MARK: 内訳

    private func breakdownHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }

    /// 内訳の1行（字下げして小さく表示）
    private func breakdownRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(.leading, 12)
    }

    /// 倍率表示（例：×2.8、×1）。ProductsView と同じ形式
    private func multiplierText(_ value: Double) -> String {
        String(format: "×%g", value)
    }

    // MARK: 目標

    @ViewBuilder
    private func milestoneRow(_ spec: MilestoneSpec, derived: DerivedState) -> some View {
        if let hours = store.state.stats.achievedMilestones[spec.id] {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(spec.title)
                        .font(.subheadline.bold())
                    Spacer()
                    // 達成時の gameHoursElapsed をゲーム内時計と同じ「Day N」に換算する
                    Text("Day \(Int(max(hours, 0) / 24) + 1) 達成")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(spec.learningNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } else {
            let texts = Engine.milestoneProgressTexts(state: store.state, derived: derived, spec: spec)
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.title)
                    .font(.subheadline)
                ProgressView(value: Engine.milestoneProgress(state: store.state, derived: derived, spec: spec))
                Text("現在 \(texts.current) ／ 目標 \(texts.target)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 国庫補助金

    @ViewBuilder
    private var subsidySection: some View {
        let subsidy = store.state.subsidy
        Text("資金繰りに詰まったときの救済措置。実際の半導体産業でも、国がファブ建設を支援するのは珍しくない。TSMCの熊本工場（JASM）やRapidusなどには国から巨額の補助金が交付されており、補助率は設備投資のおおむね1/3程度が目安とされることが多いようだ。このゲームでも、交付上限は累計設備投資の1/3としている。")
            .font(.callout)
        emergencySubsidy
        row("累計設備投資", MoneyFormat.yen(subsidy.totalInvestedYen))
        row("補助金 受給累計", MoneyFormat.yen(subsidy.totalReceivedYen))
        row("申請可能額の目安", MoneyFormat.yen(Engine.subsidyCapYen(state: store.state)))
        subsidyStatus
    }

    /// 緊急救済枠（ラインが停止し、買い戻す資金もないときだけ表示）
    @ViewBuilder
    private var emergencySubsidy: some View {
        if let amount = Engine.emergencyGrantYen(state: store.state) {
            VStack(alignment: .leading, spacing: 8) {
                Label("ラインが停止しています", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("工程の装置がなくなりラインが止まると、この緊急枠で立て直しに必要な分だけ審査なしで即時交付されます。通常の補助金とクールダウンを共有します（緊急交付後は通常申請も72分不可）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    _ = store.applyEmergencySubsidy()
                } label: {
                    Text("緊急補助金を受け取る（\(MoneyFormat.yen(amount))）")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var subsidyStatus: some View {
        let subsidy = store.state.subsidy
        // body は store の更新（tick）ごとに再評価されるので、残り時間は Date() で求めてよい
        let now = Date()
        if let remaining = Engine.subsidyReviewRemainingSeconds(state: store.state, now: now) {
            Label("審査中：交付予定 \(MoneyFormat.yen(subsidy.pendingGrantYen))（あと \(MoneyFormat.duration(remaining))）",
                  systemImage: "hourglass")
                .foregroundStyle(.orange)
        } else if let remaining = Engine.subsidyCooldownRemainingSeconds(state: store.state, now: now) {
            Label("次回申請可能まで あと \(MoneyFormat.duration(remaining))",
                  systemImage: "clock")
                .foregroundStyle(.secondary)
        } else if let reason = Engine.subsidyBlockReason(state: store.state, now: now) {
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Button {
                _ = store.applySubsidy()
            } label: {
                Text("補助金を申請する（交付予定 \(MoneyFormat.yen(Engine.subsidyCapYen(state: store.state)))）")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct ProductsView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        let currentProduct = Engine.currentProduct(state: store.state)
        List {
            Section("製造製品") {
                row("製造中", currentProduct.name)
                ForEach(Catalog.products) { product in
                    productCard(product)
                }
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

    // MARK: 製造製品

    private func productCard(_ product: ProductSpec) -> some View {
        let isCurrent = product.id == store.state.currentProductId
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(product.name)
                    .font(.headline)
                if isCurrent {
                    BadgeView(text: "製造中", systemImage: "checkmark", color: .purple)
                }
            }
            Text(product.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            // 単価・原価率は現在ノードの倍率・加算を反映した値
            Text("ダイ単価 \(MoneyFormat.yen(Engine.diePriceYen(state: store.state, productId: product.id))) × \(product.diesPerWafer)個/ウェハ／歩留まり \(multiplierText(product.yieldMultiplier))／ペナルティ \(multiplierText(product.marketPenaltyMultiplier))／原価率 \(MoneyFormat.percent(Engine.cogsRate(state: store.state, productId: product.id)))")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            ForEach(product.requirements, id: \.label) { requirement in
                requirementRow(requirement)
            }
            if !isCurrent {
                productSwitchArea(product)
            }
        }
        .padding(.vertical, 4)
    }

    private func requirementRow(_ requirement: ProductRequirement) -> some View {
        let satisfied = Engine.isSatisfied(state: store.state, requirement: requirement)
        let active = requirement.options
            .map { Engine.activeCount(state: store.state, modelIds: $0.modelIds) }
            .max() ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: satisfied ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(satisfied ? Color.green : Color.red)
            Text("\(requirement.label)（稼働 \(active)台）")
        }
        .font(.caption)
    }

    private func productSwitchArea(_ product: ProductSpec) -> some View {
        let current = store.derived
        let preview = Engine.derived(state: store.state, asProduct: product.id)
        let reasons = Engine.productBlockReasons(state: store.state, productId: product.id)
        return VStack(alignment: .leading, spacing: 6) {
            fromToRow("単価",
                      from: MoneyFormat.yen(current.currentPriceYen),
                      to: MoneyFormat.yen(preview.currentPriceYen),
                      improved: preview.currentPriceYen > current.currentPriceYen + 1e-9)
            fromToRow("ライン歩留まり",
                      from: MoneyFormat.percent(current.lineYield),
                      to: MoneyFormat.percent(preview.lineYield),
                      improved: preview.lineYield > current.lineYield + 1e-9)
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

    /// 倍率表示（例：×2.8、×1）
    private func multiplierText(_ value: Double) -> String {
        String(format: "×%g", value)
    }
}

// MARK: - 図鑑

struct GlossaryView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        let entries = Engine.glossaryEntries(state: store.state)
        let unlockedCount = entries.filter { $0.unlocked }.count
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("解放")
                        Spacer()
                        Text("\(unlockedCount)/\(entries.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("装置は所有すると、用語は目標の達成や出来事で解放されます。")
                }
                entrySection("装置", entries.filter { $0.kind == .equipment })
                entrySection("工程", entries.filter { $0.kind == .process })
                entrySection("用語", entries.filter { $0.kind == .term })
            }
            .navigationTitle("図鑑")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { entryId in
                GlossaryDetailView(entryId: entryId)
            }
        }
    }

    private func entrySection(_ title: String, _ entries: [GlossaryEntryInfo]) -> some View {
        Section(title) {
            ForEach(entries) { entry in
                entryRow(entry)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: GlossaryEntryInfo) -> some View {
        if entry.unlocked {
            NavigationLink(value: entry.id) {
                HStack(spacing: 8) {
                    Text(entry.title)
                    if !entry.isRead {
                        BadgeView(text: "NEW", systemImage: nil, color: .orange)
                    }
                    Spacer()
                    if let term = Catalog.glossaryTerm(id: entry.id) {
                        Text(term.category)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            // 未解放は本文を見せない（リンクにしない）
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("未解放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct GlossaryDetailView: View {
    @EnvironmentObject private var store: GameStore

    let entryId: String

    private var model: EquipmentModel? {
        Catalog.equipment.first { Catalog.equipmentGlossaryId($0.id) == entryId }
    }

    private var process: ProcessType? {
        ProcessType.allCases.first { Catalog.processGlossaryId($0) == entryId }
    }

    private var term: GlossaryTerm? {
        Catalog.glossaryTerm(id: entryId)
    }

    private var title: String {
        model?.name ?? process?.displayName ?? term?.term ?? "図鑑"
    }

    var body: some View {
        List {
            if let model {
                equipmentContent(model)
            } else if let process {
                processContent(process)
            } else if let term {
                termContent(term)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.markGlossaryRead(entryId)
        }
    }

    @ViewBuilder
    private func equipmentContent(_ model: EquipmentModel) -> some View {
        Section("装置") {
            row("モデル名", model.name)
            row("価格", MoneyFormat.yen(model.priceYen))
            row("公称WPH", "\(MoneyFormat.decimal(model.nominalWPH, digits: 0)) WPH")
            row("対応工程", model.process.displayName)
        }
        if let education = Catalog.education(for: model.id) {
            Section("概要") {
                bodyText(education.summary)
            }
            Section("しくみ") {
                bodyText(education.mechanism)
            }
            Section("豆知識") {
                bodyText(education.trivia)
            }
            Section("主なメーカー") {
                bodyText(education.makers.joined(separator: "、"))
            }
        }
    }

    @ViewBuilder
    private func processContent(_ process: ProcessType) -> some View {
        Section("工程について") {
            bodyText(process.educationText)
        }
        Section("前後の工程とのつながり") {
            bodyText(process.connectionNote)
        }
        Section("現実の所要時間") {
            bodyText(process.realDurationText)
        }
    }

    @ViewBuilder
    private func termContent(_ term: GlossaryTerm) -> some View {
        Section {
            BadgeView(text: term.category, systemImage: "book", color: .blue)
            bodyText(term.body)
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
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
