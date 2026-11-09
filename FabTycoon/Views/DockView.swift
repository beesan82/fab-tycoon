import SwiftUI

// MARK: - ドック（下端 3 ボタン）
// 設計書 design/simcity-rebuild.md §1.4。問題が 0 件でもボタンは常時表示する（決定 #21）。

struct DockView: View {
    let problemsCount: Int
    /// デッドロック／ライン停止なら赤、それ以外は橙バッジ
    let problemsCritical: Bool
    /// 倉庫の台数
    let buildBadgeCount: Int
    /// 研究完了＋補助金可＋図鑑未読の合計
    let facilityBadgeCount: Int
    var onBuild: () -> Void
    var onProblems: () -> Void
    var onFacilities: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            dockButton("建設", systemImage: "plus", badge: buildBadgeCount, badgeColor: .orange, action: onBuild)
            dockButton("問題", systemImage: "exclamationmark", badge: problemsCount,
                       badgeColor: problemsCritical ? .red : .orange, action: onProblems)
            dockButton("施設", systemImage: "square.grid.2x2", badge: facilityBadgeCount, badgeColor: .orange,
                       action: onFacilities)
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func dockButton(_ title: String, systemImage: String, badge: Int, badgeColor: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.caption2.bold())
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(badgeColor))
                                .fixedSize()
                                .offset(x: 14, y: -6)
                        }
                    }
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title) \(badge)件" : title)
    }
}
