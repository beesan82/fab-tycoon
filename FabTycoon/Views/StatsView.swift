import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        let stats = store.state.stats
        let derived = store.derived
        List {
            Section("累計") {
                row("売上", MoneyFormat.yen(stats.totalRevenueYen))
                row("投入ウェハ", "\(MoneyFormat.decimal(stats.totalWafersInput, digits: 1)) 枚")
                row("良品チップ", "\(MoneyFormat.count(stats.totalGoodChips)) 個")
                row("欠陥チップ", "\(MoneyFormat.count(stats.totalDefectChips)) 個")
                row("欠陥による損失", MoneyFormat.yen(stats.defectLossYen))
                row("プレイ時間", MoneyFormat.duration(stats.playSeconds))
            }
            Section("現在") {
                row("ラインWPH", MoneyFormat.decimal(derived.lineWPH, digits: 2))
                row("歩留まり", MoneyFormat.percent(derived.currentYield))
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
}
