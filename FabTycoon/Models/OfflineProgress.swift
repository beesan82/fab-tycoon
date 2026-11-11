import Foundation

// MARK: - 1.0 オフライン進行（ハイブリッド方式）
// 設計書 design/redesign-1.0.md §1.8 の方式 C。
// (1) 上限・効率は現行どおり（Engine.offlineCapSeconds / offlineEfficiency）。
// (2) 実効ゲーム分のうち min(予算 120,000 ステップ, 実効ゲーム分) を SimCore で本シミュレーションする
//     （価格は market.recentAvgPriceYen で固定、異常は発生しない、研究・補助金は実時間精算のまま）。
// (3) 残りは、シミュレート区間の後半 50%（最低 6 ゲーム時間）の実測レートで外挿し、資金・統計・学習枚数 W にのみ加える。
//     ロット位置・装置状態はシミュレート終了時のもの（定常ならそれが正しい末状態）。外挿のロットは実在しないので
//     Fab.sim には入れない。
// (4) ゲーム内時計・市況位相・プレイ秒は進めない（従来のオフラインと同扱い）。ただし市場イベントの残り時間だけは実時間基準のため、不在時間ぶん減らす（P6）。
// 安全弁：ライン寸断（LayoutAnalysis）・デッドロック・計測窓のスループット 0 のいずれかなら外挿しない
// （詰まったまま稼がない）。SimCore は乱数を使わないので、同じセーブ・同じ経過秒なら結果は再現する。
// 根拠：全時間の本シミュレーション（方式 A）は上限拡大で起動が重くなり、集計のみ（方式 B）は詰まりや立ち上げで外れる。
// 予算 12 万ステップで計算量を抑えつつ、シミュレート区間は完全、外挿区間は定常前提で ±3% 以内を狙う。

struct SimOfflineReport: Equatable {
    /// 上限適用後
    var elapsedRealSeconds: Double
    /// 効率適用後
    var effectiveRealSeconds: Double
    /// 本シミュレーションで前進したゲーム分
    var simulatedGameMinutes: Double
    /// 外挿したゲーム分
    var extrapolatedGameMinutes: Double
    /// シミュレーション区間で完了したロット数
    var completedLots: Int
    /// 投入ウェハ（シミュレーション＋外挿）
    var releasedWafers: Double
    /// 純収入の増分（シミュレーション＋外挿）
    var netYen: Double
    /// うち外挿分
    var extrapolatedNetYen: Double
    /// 良品チップの増分（シミュレーション＋外挿）
    var goodChips: Double
    /// 寸断・デッドロック・スループット0 で外挿を止めた
    var lineJammed: Bool
}

enum OfflineProgress {
    /// オフラインで本シミュレーションを回す上限ステップ（ゲーム分）。§1.8
    static let stepBudget = 120_000
    /// 外挿レートの計測窓の最短（ゲーム分）。§1.8「後半 50%（最低 6 ゲーム時間）」
    static let minWindowGameMin: Double = 360

    /// SimStats のうち、オフライン精算で Stats へ反映する流量の集計
    private struct Flow {
        var releasedWafers = 0.0
        var completedWafers = 0.0
        var netYen = 0.0
        var grossYen = 0.0
        var cogsYen = 0.0
        var penaltyYen = 0.0
        var goodChips = 0.0
        var detectedDefectChips = 0.0
        var shippedDefectChips = 0.0

        init() {}

        /// a → b の増分
        init(from a: SimStats, to b: SimStats) {
            releasedWafers = b.releasedWafers - a.releasedWafers
            completedWafers = b.completedWafers - a.completedWafers
            netYen = b.sumNetYen - a.sumNetYen
            grossYen = b.sumGrossYen - a.sumGrossYen
            cogsYen = b.sumCogsYen - a.sumCogsYen
            penaltyYen = b.sumPenaltyYen - a.sumPenaltyYen
            goodChips = b.sumGoodChips - a.sumGoodChips
            detectedDefectChips = b.sumDetectedDefectChips - a.sumDetectedDefectChips
            shippedDefectChips = b.sumShippedDefectChips - a.sumShippedDefectChips
        }

        func scaled(_ k: Double) -> Flow {
            var r = Flow()
            r.releasedWafers = releasedWafers * k
            r.completedWafers = completedWafers * k
            r.netYen = netYen * k
            r.grossYen = grossYen * k
            r.cogsYen = cogsYen * k
            r.penaltyYen = penaltyYen * k
            r.goodChips = goodChips * k
            r.detectedDefectChips = detectedDefectChips * k
            r.shippedDefectChips = shippedDefectChips * k
            return r
        }

        static func + (a: Flow, b: Flow) -> Flow {
            var r = Flow()
            r.releasedWafers = a.releasedWafers + b.releasedWafers
            r.completedWafers = a.completedWafers + b.completedWafers
            r.netYen = a.netYen + b.netYen
            r.grossYen = a.grossYen + b.grossYen
            r.cogsYen = a.cogsYen + b.cogsYen
            r.penaltyYen = a.penaltyYen + b.penaltyYen
            r.goodChips = a.goodChips + b.goodChips
            r.detectedDefectChips = a.detectedDefectChips + b.detectedDefectChips
            r.shippedDefectChips = a.shippedDefectChips + b.shippedDefectChips
            return r
        }
    }

    @discardableResult
    static func advance(state: inout GameState, elapsedRealSeconds: Double,
                        stepBudget: Int = OfflineProgress.stepBudget) -> SimOfflineReport {
        // 1. 上限・効率（現行どおり）
        // 時計の異常（NaN）は不在 0 として扱う（Int への変換で落ちないように）
        let elapsed = elapsedRealSeconds.isNaN ? 0 : elapsedRealSeconds
        let capped = min(max(elapsed, 0), Engine.offlineCapSeconds(state: state))
        let effective = capped * Engine.offlineEfficiency(state: state)
        let effectiveGameMin = effective * Engine.gameMinutesPerRealSecond

        // 2. SimCore の用意（価格は直近平均で固定）
        var sim: SimCore
        if let snapshot = state.fab.sim {
            sim = SimCore(state: state, snapshot: snapshot)
        } else {
            // 装置の読み方は Engine.installedTools と同じ（レイアウトがあれば placed が空でも equipment を読まない）
            sim = SimCore(state: state, tools: Engine.installedTools(state: state), layout: state.fab.layout)
        }
        // 学習 W の起点を state.learningWafers から引き直す（Engine.reconciledSim と同じ自己修復）
        Engine.resyncLearningWafersBase(&sim, state: state)
        // WIP 上限は運転点に強制する（付録 C.5。テンプレートはレール 48 セルで 53、旧リング型は 45、蛇行型は 59）
        sim.wipCap = SimCore.operatingWipCap(layout: state.fab.layout)
        let frozenPrice = state.market.recentAvgPriceYen
        sim.settlementPriceYen = frozenPrice
        // 汚染事故中なら歩留まり倍率を掛ける。開始時点の状態でオフライン区間全体に倍率が効く近似
        // （区間の途中でイベントが終わっても倍率は外さない）
        sim.eventYieldMultiplier = Engine.contaminationActive(state: state) ? Engine.eventYieldPenaltyFactor : 1

        // 3. 本シミュレーション（整数分だけ）。計測窓は後半 50%（最低 6 ゲーム時間、区間全体が上限）
        let simSteps = max(0, Int(min(Double(max(stepBudget, 0)), effectiveGameMin)))
        let simMinutes = Double(simSteps)
        let nominalWindow = min(simMinutes, max(simMinutes / 2, minWindowGameMin))
        // 窓の開始はステップ境界に切り上げ、実際の窓長はそこから数える
        let windowStartStep = min(simSteps, Int((simMinutes - nominalWindow).rounded(.up)))
        let windowLen = Double(simSteps - windowStartStep)
        let s0 = sim.stats
        var s1 = sim.stats
        for i in 0..<simSteps {
            if i == windowStartStep { s1 = sim.stats }
            sim.step()
        }
        if windowStartStep >= simSteps { s1 = sim.stats }
        let s2 = sim.stats

        // 4. 詰まり判定（寸断はレイアウトがある場合のみ。仮想搬送では行わない）
        var jammed = sim.isDeadlocked
        if let layout = state.fab.layout {
            let analysis = LayoutAnalysis.analyze(layout: layout, tools: sim.tools, nodeId: state.fab.currentNodeId,
                                                  lithoClass: Engine.topLithoClass(state: state) ?? .duvDry)
            if !analysis.lineConnected { jammed = true }
        }
        let window = Flow(from: s1, to: s2)
        if windowLen > 0 && window.completedWafers / windowLen == 0 { jammed = true }

        // 5. 外挿（計測窓の分あたりレート × 残りゲーム分）
        let remaining = max(0, effectiveGameMin - simMinutes)
        var extrapolated = Flow()
        if remaining > 0 && !jammed && windowLen > 0 {
            extrapolated = window.scaled(remaining / windowLen)
        }
        let simulated = Flow(from: s0, to: s2)
        let total = simulated + extrapolated
        let completedLots = s2.completedLots - s0.completedLots

        // 6. state への反映（生産系は全額）
        // 市場イベントの継続時間は実時間基準なので、不在時間（上限適用後）だけ残り時間を減らし期限切れを外す。新規発生はしない
        if !state.market.activeEvents.isEmpty {
            for index in state.market.activeEvents.indices {
                state.market.activeEvents[index].remainingRealSeconds -= capped
            }
            state.market.activeEvents.removeAll { $0.remainingRealSeconds <= 0 }
        }
        state.learningWafers[sim.releaseNodeId, default: 0] += total.releasedWafers
        state.stats.totalWafersInput += total.releasedWafers
        state.stats.totalGoodChips += total.goodChips
        state.stats.totalDefectChips += total.detectedDefectChips
        state.stats.defectLossYen += total.detectedDefectChips * frozenPrice
        let shippedChips = total.goodChips + total.shippedDefectChips
        // 外挿のロット数は数えない（実在しないため）
        state.stats.completedLots += completedLots

        // 売上として計上する割合（自動販売は全量、手動販売は在庫上限を超えて現金化した分だけ。Engine.tick と同じ）
        var soldFraction = 1.0
        if state.fab.autoSellEnabled {
            // 不良が多すぎると純収入がマイナスになりうるため、現金は0で下げ止める（Engine.tick と同じ）
            state.cashYen = max(0, state.cashYen + total.netYen)
        } else {
            // 在庫に積み、上限を超えた分は平均純益/チップで現金化する
            state.fab.inventoryChips += shippedChips
            var overflow = 0.0
            if state.fab.inventoryChips > Engine.inventoryCap {
                overflow = state.fab.inventoryChips - Engine.inventoryCap
                state.fab.inventoryChips = Engine.inventoryCap
                let netPerChip = shippedChips > 0 ? total.netYen / shippedChips : 0
                state.cashYen = max(0, state.cashYen + overflow * netPerChip)
            }
            soldFraction = shippedChips > 0 ? overflow / shippedChips : 0
        }
        // 売上系は売れた割合で按分する（在庫に残った分は sellInventory で計上するので二重にしない。§7.1）
        let sold = total.scaled(soldFraction)
        state.stats.totalShippedChips += shippedChips * soldFraction
        state.stats.totalMarketDefectChips += sold.shippedDefectChips
        state.stats.totalMarketPenaltyYen += sold.penaltyYen
        state.stats.totalGrossSalesYen += sold.grossYen
        state.stats.totalCogsYen += sold.cogsYen
        state.stats.totalRevenueYen += sold.netYen
        Engine.accruePeriodPL(state: &state, grossYen: sold.grossYen, cogsYen: sold.cogsYen,
                              penaltyYen: sold.penaltyYen, netYen: sold.netYen)

        state.fab.running = total.completedWafers + total.releasedWafers > 0
        // 末状態はシミュレーション終了時のもの（外挿分のロットは実在しない）
        state.fab.placed = sim.tools
        state.fab.sim = sim.snapshot()
        // gameHoursElapsed・market（activeEvents の残り時間を除く）・stats.playSeconds は進めない。異常も発生させない
        Engine.evaluateMilestones(state: &state)

        // 7. レポート
        return SimOfflineReport(
            elapsedRealSeconds: capped,
            effectiveRealSeconds: effective,
            simulatedGameMinutes: simMinutes,
            extrapolatedGameMinutes: remaining,
            completedLots: completedLots,
            releasedWafers: total.releasedWafers,
            netYen: total.netYen,
            extrapolatedNetYen: extrapolated.netYen,
            goodChips: total.goodChips,
            lineJammed: jammed
        )
    }
}
