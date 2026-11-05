import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(state: store.state, derived: store.derived)
            Divider()
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
                StatsView()
                    .tabItem { Label("統計", systemImage: "chart.bar") }
                    .tag(AppTab.stats)
            }
        }
        .sheet(item: $store.offlineReport) { report in
            OfflineReportSheet(report: report) {
                store.dismissOfflineReport()
            }
        }
    }
}

// MARK: - ヘッダ

struct HeaderView: View {
    let state: GameState
    let derived: DerivedState

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
            }
            HStack(spacing: 8) {
                BadgeView(text: node.displayName, systemImage: "cpu", color: .blue)
                BadgeView(text: product.shortName, systemImage: "shippingbox", color: .purple)
                BadgeView(text: "市況 \(condition.label)", systemImage: condition.symbolName, color: condition.color)
                Spacer()
                if let next = Catalog.nextNode(after: node.id) {
                    BadgeView(text: "\(next.displayName) 🔒", systemImage: nil, color: .gray)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
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
    let report: OfflineReport
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
            Text("おかえりなさい")
                .font(.title2.bold())
            Text("不在の \(MoneyFormat.duration(report.elapsedSeconds)) の間もファブは稼働していました（効率50%）")
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

            Button(action: onClose) {
                Text("受け取る")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .presentationDetents([.medium])
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
