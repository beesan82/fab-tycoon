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
}
