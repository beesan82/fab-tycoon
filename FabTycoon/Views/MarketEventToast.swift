import SwiftUI

// MARK: - 市場イベント（特需）の開始・終了トースト
// ContentView のトースト層に store.marketEventNotice で出す。見た目は FieldNoteToast に揃える。
// 8 秒で自動的に閉じる（閉じるボタンでも閉じられる）。

struct MarketEventToast: View {
    @EnvironmentObject private var store: GameStore

    let notice: MarketEventNotice

    static let autoDismissSeconds: Double = 8

    var body: some View {
        let spec = Catalog.marketEvent(id: notice.specId)
        let tint: Color = notice.isStart ? .accentColor : .secondary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(notice.isStart ? "市場イベント発生" : "市場イベント終了",
                      systemImage: notice.isStart ? "megaphone.fill" : "megaphone")
                    .font(.caption2.bold())
                    .foregroundStyle(tint)
                Spacer()
                Button {
                    store.dismissMarketEventNotice()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("閉じる"))
            }
            Text(spec?.name ?? notice.specId)
                .font(.subheadline.bold())
                .fixedSize(horizontal: false, vertical: true)
            if notice.isStart, let spec {
                Text(spec.effectText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.35)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(Self.autoDismissSeconds))
            guard !Task.isCancelled, store.marketEventNotice?.id == notice.id else { return }
            withAnimation { store.dismissMarketEventNotice() }
        }
    }
}
