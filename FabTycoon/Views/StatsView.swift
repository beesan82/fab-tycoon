import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        let stats = store.state.stats
        let derived = store.derived
        let currentProduct = Engine.currentProduct(state: store.state)
        List {
            Section("国庫補助金") {
                subsidySection
            }
            Section("累計") {
                row("売上", MoneyFormat.yen(stats.totalRevenueYen))
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
                row("ライン歩留まり（検査前）", MoneyFormat.percent(derived.lineYield))
                row("検査検出率", MoneyFormat.percent(derived.detectionRate))
                row("出荷良品率", MoneyFormat.percent(derived.shippedYield))
                row("市場不良率", MoneyFormat.percent(derived.marketDefectRate))
            }
            Section("現在") {
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
                Text("工程の装置がなくなりラインが止まると、この緊急枠で立て直しに必要な分だけ審査なしで即時交付されます。通常の補助金とクールダウンを共有します（緊急交付後は通常申請も30日不可）。")
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
        if let due = subsidy.pendingGrantAtHours {
            Label("審査中：交付予定 \(MoneyFormat.yen(subsidy.pendingGrantYen))（あと\(daysLeft(until: due))日）",
                  systemImage: "hourglass")
                .foregroundStyle(.orange)
        } else if let last = subsidy.lastGrantAtHours,
                  store.state.gameHoursElapsed - last < Engine.subsidyCooldownHours {
            Label("次回申請可能まで あと\(daysLeft(until: last + Engine.subsidyCooldownHours))日",
                  systemImage: "clock")
                .foregroundStyle(.secondary)
        } else if let reason = Engine.subsidyBlockReason(state: store.state) {
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

    /// 指定時刻（gameHoursElapsed 基準）までの残り日数（ゲーム内、切り上げ）
    private func daysLeft(until hours: Double) -> Int {
        max(0, Int(ceil((hours - store.state.gameHoursElapsed) / 24)))
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
            Text("単価 \(multiplierText(product.priceMultiplier))／歩留まり \(multiplierText(product.yieldMultiplier))／ペナルティ \(multiplierText(product.marketPenaltyMultiplier))")
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
        let owned = requirement.options
            .map { Engine.ownedCount(state: store.state, modelIds: $0.modelIds) }
            .max() ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: satisfied ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(satisfied ? Color.green : Color.red)
            Text("\(requirement.label)（現在 \(owned)台）")
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
