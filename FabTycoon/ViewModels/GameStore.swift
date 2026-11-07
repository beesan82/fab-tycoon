import Foundation
import SwiftUI

enum AppTab: Hashable {
    case line
    case shop
    case products
    case research
    case glossary
    case stats
}

/// ゲーム状態の保持・時間進行・セーブを担う。メインスレッドからのみ使う。
final class GameStore: ObservableObject {
    @Published var state: GameState
    @Published private(set) var derived: DerivedState
    @Published var offlineReport: OfflineReport?
    @Published var selectedTab: AppTab = .line
    /// ショップの工程フィルタ（nil = 全て）
    @Published var shopProcessFilter: ProcessType?

    static let tickInterval: TimeInterval = 0.25
    static let maxTickDelta: TimeInterval = 2
    static let autosaveInterval: TimeInterval = 5
    static let offlineThreshold: TimeInterval = 60

    /// 起動時に読み込んだセーブの元の schemaVersion（新規開始・読み込み失敗時は nil）
    private(set) var loadedOriginalVersion: Int?

    private var saveManager: SaveManager
    private var timer: Timer?
    private var lastTick: Date
    private var lastSave: Date

    init(saveManager: SaveManager = SaveManager()) {
        var manager = saveManager
        let now = Date()
        var loaded: GameState
        var report: OfflineReport?
        let saved = manager.load()
        self.saveManager = manager
        loadedOriginalVersion = manager.lastLoadedOriginalVersion
        if let saved {
            loaded = saved
            // 研究・補助金の審査は実時間で進むので、不在中に期限が来た分を先に精算する
            Engine.settleResearchIfDue(state: &loaded, now: now)
            Engine.settleSubsidyIfDue(state: &loaded, now: now)
            let elapsed = now.timeIntervalSince(saved.lastSavedAt)
            if elapsed > Self.offlineThreshold {
                report = Engine.offlineProgress(state: &loaded, elapsedRealSeconds: elapsed)
            }
        } else {
            loaded = GameState.initial(now: now)
        }
        state = loaded
        derived = Engine.derived(state: loaded)
        offlineReport = report
        lastTick = now
        lastSave = now
        start()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: 時間進行

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        let now = Date()
        let dt = min(max(now.timeIntervalSince(lastTick), 0), Self.maxTickDelta)
        lastTick = now
        guard dt > 0 else { return }
        Engine.tick(state: &state, dtRealSeconds: dt)
        Engine.settleResearchIfDue(state: &state, now: now)
        refresh()
        if now.timeIntervalSince(lastSave) >= Self.autosaveInterval {
            save()
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            let now = Date()
            let gap = now.timeIntervalSince(lastTick)
            // 不在中に期限が来た研究・補助金を、オフライン進行より先に精算する
            Engine.settleResearchIfDue(state: &state, now: now)
            Engine.settleSubsidyIfDue(state: &state, now: now)
            if gap > Self.offlineThreshold {
                offlineReport = Engine.offlineProgress(state: &state, elapsedRealSeconds: gap)
            } else if gap > 0 {
                // 短い中断は通常速度でそのまま追いつく
                Engine.tick(state: &state, dtRealSeconds: gap)
            }
            lastTick = now
            refresh()
            start()
        case .background:
            stop()
            save()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func save() {
        let now = Date()
        state.lastSavedAt = now
        lastSave = now
        do {
            try saveManager.save(state)
        } catch {
            print("[GameStore] save failed: \(error)")
        }
    }

    private func refresh() {
        derived = Engine.derived(state: state)
    }

    // MARK: アクション

    @discardableResult
    func buy(_ modelId: String) -> Bool {
        let ok = Engine.buy(state: &state, modelId: modelId)
        refresh()
        return ok
    }

    @discardableResult
    func upgrade(_ instanceId: UUID) -> Bool {
        let ok = Engine.upgrade(state: &state, instanceId: instanceId)
        refresh()
        return ok
    }

    @discardableResult
    func sellEquipment(_ instanceId: UUID) -> Bool {
        let ok = Engine.sellEquipment(state: &state, instanceId: instanceId)
        refresh()
        return ok
    }

    @discardableResult
    func detachEquipment(_ instanceId: UUID) -> Bool {
        let ok = Engine.detachEquipment(state: &state, instanceId: instanceId)
        refresh()
        return ok
    }

    @discardableResult
    func attachEquipment(_ instanceId: UUID) -> Bool {
        let ok = Engine.attachEquipment(state: &state, instanceId: instanceId)
        refresh()
        return ok
    }

    @discardableResult
    func expandFab() -> Bool {
        let ok = Engine.expandFab(state: &state)
        refresh()
        return ok
    }

    func toggleAutoSell() {
        state.fab.autoSellEnabled.toggle()
        refresh()
    }

    @discardableResult
    func sellAllInventory() -> Double {
        let revenue = Engine.sellInventory(state: &state, priceYen: derived.currentPriceYen)
        refresh()
        return revenue
    }

    @discardableResult
    func switchProduct(_ productId: String) -> Bool {
        let ok = Engine.switchProduct(state: &state, productId: productId)
        refresh()
        return ok
    }

    @discardableResult
    func switchNode(_ nodeId: String) -> Bool {
        let ok = Engine.switchNode(state: &state, toNodeId: nodeId)
        refresh()
        return ok
    }

    @discardableResult
    func applySubsidy() -> Bool {
        let ok = Engine.applySubsidy(state: &state)
        refresh()
        return ok
    }

    @discardableResult
    func applyEmergencySubsidy() -> Bool {
        let ok = Engine.applyEmergencySubsidy(state: &state)
        refresh()
        return ok
    }

    @discardableResult
    func startResearch(_ researchId: String) -> Bool {
        let ok = Engine.startResearch(state: &state, researchId: researchId, now: Date())
        refresh()
        return ok
    }

    /// 研究タブを開いたら完了バッジを消す
    func markResearchCompletionSeen() {
        guard state.research.hasUnseenCompletion else { return }
        state.research.hasUnseenCompletion = false
    }

    func openShop(for process: ProcessType?) {
        shopProcessFilter = process
        selectedTab = .shop
    }

    func dismissOfflineReport() {
        offlineReport = nil
    }

    /// 図鑑エントリを既読にする（保存は通常のオートセーブに任せる）
    func markGlossaryRead(_ id: String) {
        guard !state.stats.readGlossaryIds.contains(id) else { return }
        state.stats.readGlossaryIds.insert(id)
    }

    // MARK: 旧セーブ告知・新規開始

    /// 旧バージョンのセーブを読み込み、バランス変更の告知をまだ閉じていない
    var shouldShowScaleNotice: Bool {
        (loadedOriginalVersion ?? GameState.currentSchemaVersion) < GameState.currentSchemaVersion
            && !state.didShowScaleChangeNotice
    }

    func dismissScaleNotice() {
        state.didShowScaleChangeNotice = true
        save()
    }

    /// 初期状態からやり直す（セーブとバックアップを削除して保存し直す）
    func resetGame() {
        let now = Date()
        state = GameState.initial(now: now)
        refresh()
        offlineReport = nil
        loadedOriginalVersion = nil
        do {
            try saveManager.deleteSave()
        } catch {
            print("[GameStore] delete save failed: \(error)")
        }
        lastTick = now
        lastSave = now
        save()
    }
}
