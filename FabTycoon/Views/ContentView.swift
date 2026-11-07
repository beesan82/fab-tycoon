import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: GameStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(state: store.state, derived: store.derived)
            Divider()
            if store.shouldShowScaleNotice {
                ScaleNoticeBanner {
                    store.dismissScaleNotice()
                }
            }
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
                GlossaryView()
                    .tabItem { Label("図鑑", systemImage: "book") }
                    .tag(AppTab.glossary)
                StatsView()
                    .tabItem { Label("統計", systemImage: "chart.bar") }
                    .tag(AppTab.stats)
            }
        }
        .sheet(item: $store.offlineReport) { report in
            OfflineReportSheet(report: report) {
                store.dismissOfflineReport()
            }
            .environmentObject(store)
        }
    }
}

// MARK: - ヘッダ

struct HeaderView: View {
    let state: GameState
    let derived: DerivedState

    @State private var showingSettings = false

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
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                }
                .accessibilityLabel("設定")
                .padding(.leading, 8)
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
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

// MARK: - 旧セーブ告知バナー

struct ScaleNoticeBanner: View {
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text("アップデートで数字のバランスが変わりました。以前のセーブはそのまま使えます。新しいバランスで始める場合は、設定（歯車アイコン）から新規開始できます。")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("閉じる")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.1))
    }
}

// MARK: - 設定

struct SettingsView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingFirstConfirm = false
    @State private var showingSecondConfirm = false

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "バージョン \(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(versionText)
                        .monospacedDigit()
                }

                Section {
                    Button(role: .destructive) {
                        showingFirstConfirm = true
                    } label: {
                        Text("新規開始")
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("セーブは自動で保存されます。新規開始すると、現在のセーブは削除されて初期状態から始まります。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .alert("新規開始しますか？", isPresented: $showingFirstConfirm) {
                Button("新規開始", role: .destructive) {
                    // 1つ目のアラートが閉じてから2つ目を出す
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showingSecondConfirm = true
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("現在の資金・装置・記録はすべて消えます。")
            }
            .alert("本当に新規開始しますか？", isPresented: $showingSecondConfirm) {
                Button("新規開始する", role: .destructive) {
                    store.resetGame()
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この操作は取り消せません。")
            }
        }
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
    @EnvironmentObject private var store: GameStore

    let report: OfflineReport
    let onClose: () -> Void

    /// 例：「効率50%・上限4時間」（Engine の定数から組み立てる）
    private var conditionText: String {
        let efficiency = Int(Engine.offlineEfficiency * 100)
        let capHours = Int(Engine.offlineCapSeconds / 3_600)
        return "効率\(efficiency)%・上限\(capHours)時間"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
            Text("おかえりなさい")
                .font(.title2.bold())
            Text("不在の \(MoneyFormat.duration(report.elapsedSeconds)) の間もファブは稼働していました（\(conditionText)）")
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

            // 次の一手アドバイザー
            Label(Engine.advisorMessage(state: store.state, derived: store.derived), systemImage: "lightbulb")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.4)))

            Button(action: onClose) {
                Text("受け取る")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        // アドバイザー行の分だけ高さが伸びることがあるので、全画面へも広げられるようにする
        .presentationDetents([.medium, .large])
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
