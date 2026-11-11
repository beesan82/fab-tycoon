import SwiftUI

// MARK: - R2 現場ノートのトースト＋展開カード
// 設計書 design/simcity-rebuild.md §4.1・§4.3。ContentView のトースト層（下部カードの上）に store.activeFieldNote の id で出す。
// 折りたたみは 8 秒で自動的に閉じる。タップで展開したら自動消去は止め、閉じるボタンまで残す。
// 既読（seenFieldNoteIds）は GameStore が表示時に入れるので、ここでは閉じるだけ。

struct FieldNoteToast: View {
    @EnvironmentObject private var store: GameStore

    let noteId: String
    let onOpenGlossary: (String) -> Void

    @State private var expanded = false

    static let autoDismissSeconds: Double = 8

    /// 自動消去タスクの識別子（ノートが替わるか展開状態が変わると張り直す）
    private struct AutoDismissKey: Hashable {
        let noteId: String
        let expanded: Bool
    }

    var body: some View {
        let spec = Catalog.fieldNote(id: noteId)
        let title = Engine.fieldNoteTitle(id: noteId, state: store.state, derived: store.derived)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("現場ノート", systemImage: "note.text")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                Spacer()
                if expanded {
                    Button {
                        store.dismissFieldNote()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("閉じる"))
                } else {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(title)
                .font(.subheadline.bold())
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            if let spec {
                Text(spec.body)
                    .font(expanded ? .callout : .caption)
                    .foregroundStyle(expanded ? Color.primary : Color.secondary)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: expanded)
                if expanded {
                    glossaryChips(spec.relatedGlossaryIds)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.35)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !expanded else { return }
            withAnimation(.easeOut(duration: 0.2)) { expanded = true }
        }
        .accessibilityAddTraits(expanded ? [] : .isButton)
        .accessibilityHint(expanded ? Text("") : Text("タップで全文を読む"))
        .onChange(of: noteId) { _, _ in
            // 次のノートに替わったら折りたたみから始める
            expanded = false
        }
        .task(id: AutoDismissKey(noteId: noteId, expanded: expanded)) {
            guard !expanded else { return }
            try? await Task.sleep(for: .seconds(Self.autoDismissSeconds))
            guard !Task.isCancelled, !expanded, store.activeFieldNote == noteId else { return }
            withAnimation { store.dismissFieldNote() }
        }
    }

    /// 関連図鑑のチップ（用語名。タップで資料室の該当エントリへ）
    private func glossaryChips(_ ids: [String]) -> some View {
        let terms = ids.compactMap { Catalog.glossaryTerm(id: $0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(terms) { term in
                    Button {
                        onOpenGlossary(term.id)
                    } label: {
                        Label(term.term, systemImage: "books.vertical")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }
            }
        }
    }
}
