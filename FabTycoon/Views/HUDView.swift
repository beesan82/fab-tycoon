import SwiftUI

// MARK: - HUD（上端 1 行バー）
// 設計書 design/simcity-rebuild.md §1.1・§1.2。資金／収入/分／時計／WPH ＋ [123] [⚙]。
// 表示専用（例外は WPH のトースト・123・歯車）。狭幅でも WPH 以外は省略させない。

struct HUDView: View {
    let state: GameState
    let derived: DerivedState
    @Binding var showNumbers: Bool
    var onTapThroughput: () -> Void

    @State private var showingSettings = false

    var body: some View {
        let income = derived.incomePerMinuteYen
        let wph = state.fab.sim?.throughputEMA ?? 0
        HStack(spacing: 8) {
            Text(MoneyFormat.yen(state.cashYen))
                .font(.subheadline.bold())
                .fixedSize()
            Text("\(MoneyFormat.signedYen(income))/分")
                .font(.caption.weight(.semibold))
                .foregroundStyle(income >= 0 ? Color.green : Color.red)
                .fixedSize()
            Text(Self.clockText(gameHours: state.gameHoursElapsed))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button(action: onTapThroughput) {
                Text("\(MoneyFormat.decimal(wph, digits: 1)) WPH")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("スループット \(MoneyFormat.decimal(wph, digits: 1)) WPH")
            Spacer(minLength: 0)
            Button {
                showNumbers.toggle()
            } label: {
                Text("123")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .foregroundStyle(showNumbers ? Color.white : Color.accentColor)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(showNumbers ? Color.accentColor : Color.accentColor.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(showNumbers ? "数字表示をオフ" : "数字表示をオン")
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline)
            }
            .fixedSize()
            .accessibilityLabel("設定")
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    /// 「Day 3 07:30」形式のゲーム内時計（LineView.clockText と同じ計算）
    static func clockText(gameHours: Double) -> String {
        let totalMinutes = Int(max(gameHours, 0) * 60)
        let day = totalMinutes / 1440 + 1
        let hour = (totalMinutes / 60) % 24
        let minute = totalMinutes % 60
        return "Day \(day) \(String(format: "%02d", hour)):\(String(format: "%02d", minute))"
    }
}
