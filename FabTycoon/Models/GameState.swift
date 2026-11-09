import Foundation

struct GameState: Codable, Equatable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var cashYen: Double
    var fab: Fab
    var market: MarketState
    /// ノードID → 累計投入ウェハ枚数（歩留まり学習用）
    var learningWafers: [String: Double]
    var stats: Stats
    var lastSavedAt: Date
    var createdAt: Date
    /// 経過ゲーム内時間（hours）。オフライン時間は加算しない
    var gameHoursElapsed: Double = 0
    /// 製造中の製品ID（Catalog.products）
    var currentProductId: String = Catalog.defaultProductId
    /// 国庫補助金の申請・受給状況
    var subsidy: SubsidyState = SubsidyState()
    /// 数値バランス変更の告知を表示済みか（旧セーブ向け）
    var didShowScaleChangeNotice: Bool = false
    /// 研究の進行状況
    var research: ResearchState = ResearchState()
    /// 発生中の歩留まり異常（なければ nil）
    var activeExcursion: ActiveExcursion? = nil
    /// 次に異常が発生しうる最も早い gameHoursElapsed（新規開始の猶予と解決後のクールダウンを兼ねる）
    var nextExcursionEarliestGameHours: Double = 240

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case cashYen
        case fab
        case market
        case learningWafers
        case stats
        case lastSavedAt
        case createdAt
        case gameHoursElapsed
        case currentProductId
        case subsidy
        case didShowScaleChangeNotice
        case research
        case activeExcursion
        case nextExcursionEarliestGameHours
    }

    /// 設置済み装置の購入価格合計（改良費は含まない）
    static func equipmentPurchaseTotalYen(_ equipment: [EquipmentInstance]) -> Double {
        equipment.reduce(0.0) { $0 + (Catalog.model(id: $1.modelId)?.priceYen ?? 0) }
    }

    static func initial(now: Date = Date()) -> GameState {
        let starter: [(String, Int)] = [
            ("L1", 2), ("D1", 2), ("E1", 3), ("I1", 1), ("C1", 1), ("Q1", 1), ("P1", 1),
        ]
        var equipment: [EquipmentInstance] = []
        for (modelId, count) in starter {
            for _ in 0..<count {
                equipment.append(EquipmentInstance(modelId: modelId, level: 1, purchasedAt: now))
            }
        }
        let fab = Fab(
            id: UUID(),
            name: "第1ファブ",
            currentNodeId: Catalog.startingNodeId,
            slots: 12,
            equipment: equipment,
            wipWafers: 0,
            inventoryChips: 0,
            autoSellEnabled: true,
            running: true,
            storedEquipment: [],
            expansionCount: 0
        )
        var state = GameState(
            schemaVersion: currentSchemaVersion,
            cashYen: 3_000_000_000,
            fab: fab,
            market: MarketState(),
            learningWafers: [:],
            stats: Stats(),
            lastSavedAt: now,
            createdAt: now,
            gameHoursElapsed: 0,
            currentProductId: Catalog.defaultProductId,
            // 初期装置は累計設備投資に含めない
            subsidy: SubsidyState()
        )
        // v4：初期装備を 16×16 テンプレート（§2.6）に配置し、ロットの流れていないシミュレーションを持たせる。
        // SimCore の init は state を読むので、layout・placed を先に設定してから sim を作る
        let template = LayoutTemplate.starter16(equipment: equipment)
        state.fab.layout = template.layout
        state.fab.placed = template.placed
        state.fab.sim = SimCore.freshSnapshot(state: state, tools: template.placed, layout: template.layout)
        return state
    }
}

// 旧セーブ互換：後から追加したフィールドは欠けていてもデフォルト値で読む。
// extension に置くことで memberwise init を残す。
extension GameState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        cashYen = try container.decode(Double.self, forKey: .cashYen)
        fab = try container.decode(Fab.self, forKey: .fab)
        market = try container.decode(MarketState.self, forKey: .market)
        learningWafers = try container.decode([String: Double].self, forKey: .learningWafers)
        stats = try container.decode(Stats.self, forKey: .stats)
        lastSavedAt = try container.decode(Date.self, forKey: .lastSavedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        gameHoursElapsed = try container.decodeIfPresent(Double.self, forKey: .gameHoursElapsed) ?? 0
        currentProductId = try container.decodeIfPresent(String.self, forKey: .currentProductId) ?? Catalog.defaultProductId
        // 補助金導入前のセーブは、設置済み装置の購入価格合計を累計設備投資とみなす
        subsidy = try container.decodeIfPresent(SubsidyState.self, forKey: .subsidy)
            ?? SubsidyState(totalInvestedYen: GameState.equipmentPurchaseTotalYen(fab.equipment))
        didShowScaleChangeNotice = try container.decodeIfPresent(Bool.self, forKey: .didShowScaleChangeNotice) ?? false
        research = try container.decodeIfPresent(ResearchState.self, forKey: .research) ?? ResearchState()
        activeExcursion = try container.decodeIfPresent(ActiveExcursion.self, forKey: .activeExcursion) ?? nil
        nextExcursionEarliestGameHours = try container.decodeIfPresent(Double.self, forKey: .nextExcursionEarliestGameHours) ?? 240
    }
}

/// 発生中の歩留まり異常（エクスカーション）
struct ActiveExcursion: Codable, Equatable {
    /// Catalog.excursions の id（兆候・原因はここから引く）
    var specId: String
    /// 発生時の gameHoursElapsed
    var startedAtGameHours: Double
    /// 開示済みヒント段階（0 = 兆候のみ、最大3）
    var hintsRevealed: Int = 0
    /// 対策を外した回数
    var wrongGuesses: Int = 0
    /// 原因装置（v4 で追加。nil なら工程全体＝互換）
    var causeToolId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case specId
        case startedAtGameHours
        case hintsRevealed
        case wrongGuesses
        case causeToolId
    }
}

// 旧セーブ互換：全フィールドを欠けていてもデフォルト値で読む。
// extension に置くことで memberwise init を残す。
extension ActiveExcursion {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        specId = try container.decodeIfPresent(String.self, forKey: .specId) ?? ""
        startedAtGameHours = try container.decodeIfPresent(Double.self, forKey: .startedAtGameHours) ?? 0
        hintsRevealed = try container.decodeIfPresent(Int.self, forKey: .hintsRevealed) ?? 0
        wrongGuesses = try container.decodeIfPresent(Int.self, forKey: .wrongGuesses) ?? 0
        causeToolId = try container.decodeIfPresent(UUID.self, forKey: .causeToolId) ?? nil
    }
}

/// ノード移行の方式（v4。P4 の排出モード用）
enum NodeSwitchMode: String, Codable, Equatable {
    /// 仕掛かりを流し切ってから切り替える
    case drain
    /// 即時に切り替える
    case immediate
}

/// 予約中のノード移行（v4）
struct NodeSwitchState: Codable, Equatable {
    var pendingNodeId: String? = nil
    var mode: NodeSwitchMode = .drain
}

/// 研究の進行状況
struct ResearchState: Codable, Equatable {
    var completedIds: Set<String> = []
    var inProgressId: String? = nil
    var inProgressStartedAt: Date? = nil
    /// 完了したが研究タブでまだ確認していない（タブバッジ用）
    var hasUnseenCompletion: Bool = false

    enum CodingKeys: String, CodingKey {
        case completedIds
        case inProgressId
        case inProgressStartedAt
        case hasUnseenCompletion
    }
}

// 旧セーブ互換：全フィールドを欠けていてもデフォルト値で読む
extension ResearchState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ResearchState()
        completedIds = try container.decodeIfPresent(Set<String>.self, forKey: .completedIds) ?? defaults.completedIds
        inProgressId = try container.decodeIfPresent(String.self, forKey: .inProgressId) ?? defaults.inProgressId
        inProgressStartedAt = try container.decodeIfPresent(Date.self, forKey: .inProgressStartedAt) ?? defaults.inProgressStartedAt
        hasUnseenCompletion = try container.decodeIfPresent(Bool.self, forKey: .hasUnseenCompletion) ?? defaults.hasUnseenCompletion
    }
}

/// 国庫補助金の申請・受給状況
struct SubsidyState: Codable, Equatable {
    /// 審査中の交付予定額（0なら申請なし）
    var pendingGrantYen: Double = 0
    /// 交付予定時刻（実時間）。nil なら申請なし
    var pendingGrantAt: Date? = nil
    /// 累計設備投資額（購入＋改良）
    var totalInvestedYen: Double = 0
    /// 累計受給額
    var totalReceivedYen: Double = 0
    /// 最終交付時刻（実時間）
    var lastGrantAt: Date? = nil
    /// 移行専用。v2以前のセーブの交付予定時刻（gameHoursElapsed 基準）。新規の書き込みでは常に nil
    var pendingGrantAtHours: Double? = nil
    /// 移行専用。v2以前のセーブの最終交付時刻（gameHoursElapsed 基準）。新規の書き込みでは常に nil
    var lastGrantAtHours: Double? = nil

    enum CodingKeys: String, CodingKey {
        case pendingGrantYen
        case pendingGrantAt
        case totalInvestedYen
        case totalReceivedYen
        case lastGrantAt
        case pendingGrantAtHours
        case lastGrantAtHours
    }
}

// 旧セーブ互換：全フィールドを欠けていてもデフォルト値で読む
extension SubsidyState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SubsidyState()
        pendingGrantYen = try container.decodeIfPresent(Double.self, forKey: .pendingGrantYen) ?? defaults.pendingGrantYen
        pendingGrantAt = try container.decodeIfPresent(Date.self, forKey: .pendingGrantAt) ?? defaults.pendingGrantAt
        totalInvestedYen = try container.decodeIfPresent(Double.self, forKey: .totalInvestedYen) ?? defaults.totalInvestedYen
        totalReceivedYen = try container.decodeIfPresent(Double.self, forKey: .totalReceivedYen) ?? defaults.totalReceivedYen
        lastGrantAt = try container.decodeIfPresent(Date.self, forKey: .lastGrantAt) ?? defaults.lastGrantAt
        pendingGrantAtHours = try container.decodeIfPresent(Double.self, forKey: .pendingGrantAtHours) ?? defaults.pendingGrantAtHours
        lastGrantAtHours = try container.decodeIfPresent(Double.self, forKey: .lastGrantAtHours) ?? defaults.lastGrantAtHours
    }
}

struct Fab: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var currentNodeId: String
    var slots: Int
    var equipment: [EquipmentInstance]
    /// 仕掛かりウェハ（表示用の小数部）
    var wipWafers: Double
    var inventoryChips: Double
    var autoSellEnabled: Bool
    var running: Bool
    /// 倉庫（未設置の所有装置）。スロットを消費せず、集計にも含めない
    var storedEquipment: [EquipmentInstance]
    /// 増床回数
    var expansionCount: Int
    /// 配置済み装置（v4 で追加。equipment はこれと同じ装置を EquipmentInstance で持つ：当面の Engine 互換）
    var placed: [ToolInstance] = []
    /// 区画・レール・ストッカー・投入口・出荷口（v4 で追加）
    var layout: FloorLayout? = nil
    /// シミュレーション状態（v4 で追加）
    var sim: SimSnapshot? = nil
    /// 予約中のノード移行（v4 で追加）
    var nodeSwitch: NodeSwitchState = NodeSwitchState()

    /// 倉庫の装置は枠を消費しない
    var freeSlots: Int { max(0, slots - equipment.count) }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case currentNodeId
        case slots
        case equipment
        case wipWafers
        case inventoryChips
        case autoSellEnabled
        case running
        case storedEquipment
        case expansionCount
        case placed
        case layout
        case sim
        case nodeSwitch
    }
}

// 旧セーブ互換：倉庫・増床導入前のセーブも読めるようにする。
// extension に置くことで memberwise init を残す。
extension Fab {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        currentNodeId = try container.decode(String.self, forKey: .currentNodeId)
        slots = try container.decode(Int.self, forKey: .slots)
        equipment = try container.decode([EquipmentInstance].self, forKey: .equipment)
        wipWafers = try container.decodeIfPresent(Double.self, forKey: .wipWafers) ?? 0
        inventoryChips = try container.decodeIfPresent(Double.self, forKey: .inventoryChips) ?? 0
        autoSellEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSellEnabled) ?? true
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? true
        storedEquipment = try container.decodeIfPresent([EquipmentInstance].self, forKey: .storedEquipment) ?? []
        // 増床回数導入前のセーブは、初期12枠からの増分（1回 +4枠）で推定する
        expansionCount = try container.decodeIfPresent(Int.self, forKey: .expansionCount) ?? max(0, (slots - 12) / 4)
        // v3 以前のセーブには無い。Engine.migrateToLayout が埋める
        placed = try container.decodeIfPresent([ToolInstance].self, forKey: .placed) ?? []
        layout = try container.decodeIfPresent(FloorLayout.self, forKey: .layout) ?? nil
        sim = try container.decodeIfPresent(SimSnapshot.self, forKey: .sim) ?? nil
        nodeSwitch = try container.decodeIfPresent(NodeSwitchState.self, forKey: .nodeSwitch) ?? NodeSwitchState()
    }
}

struct EquipmentInstance: Codable, Equatable, Identifiable {
    var id: UUID
    var modelId: String
    /// 1...5
    var level: Int
    var purchasedAt: Date

    init(id: UUID = UUID(), modelId: String, level: Int = 1, purchasedAt: Date = Date()) {
        self.id = id
        self.modelId = modelId
        self.level = level
        self.purchasedAt = purchasedAt
    }
}

struct MarketState: Codable, Equatable {
    var gameTimeMinutes: Double = 0
    var walkFactor: Double = 1.0
    var recentAvgPriceYen: Double = 1_200
}

struct Stats: Codable, Equatable {
    /// 粗利（売上 − 原価 − 市場不良ペナルティの累計）
    var totalRevenueYen: Double = 0
    var totalWafersInput: Double = 0
    var totalGoodChips: Double = 0
    var totalDefectChips: Double = 0
    var defectLossYen: Double = 0
    var playSeconds: Double = 0
    /// 出荷（販売）したチップ数（良品＋見逃した不良）
    var totalShippedChips: Double = 0
    /// 検査をすり抜けて客先に届いた不良チップ数
    var totalMarketDefectChips: Double = 0
    /// 市場不良による返品・対応コストの累計（円）
    var totalMarketPenaltyYen: Double = 0
    /// 総売上（原価・ペナルティ控除前）
    var totalGrossSalesYen: Double = 0
    /// 売上原価の累計
    var totalCogsYen: Double = 0
    /// マイルストーンid → 達成時の gameHoursElapsed
    var achievedMilestones: [String: Double] = [:]
    /// 図鑑で閲覧済みのエントリid
    var readGlossaryIds: Set<String> = []
    /// 解決した歩留まり異常の件数
    var excursionsResolved: Int = 0
    /// 出荷したロット数（v4 で追加）
    var completedLots: Int = 0
    /// 廃棄したロット数（v4 で追加）
    var scrappedLots: Int = 0
    /// 敷設したレールの累計セル数（v4 で追加）
    var railCellsBuilt: Int = 0
    /// 購入した区画数（v4 で追加）
    var parcelsBought: Int = 0

    enum CodingKeys: String, CodingKey {
        case totalRevenueYen
        case totalWafersInput
        case totalGoodChips
        case totalDefectChips
        case defectLossYen
        case playSeconds
        case totalShippedChips
        case totalMarketDefectChips
        case totalMarketPenaltyYen
        case totalGrossSalesYen
        case totalCogsYen
        case achievedMilestones
        case readGlossaryIds
        case excursionsResolved
        case completedLots
        case scrappedLots
        case railCellsBuilt
        case parcelsBought
    }
}

// 旧セーブ互換：全フィールドを欠けていてもデフォルト値で読む
extension Stats {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Stats()
        totalRevenueYen = try container.decodeIfPresent(Double.self, forKey: .totalRevenueYen) ?? defaults.totalRevenueYen
        totalWafersInput = try container.decodeIfPresent(Double.self, forKey: .totalWafersInput) ?? defaults.totalWafersInput
        totalGoodChips = try container.decodeIfPresent(Double.self, forKey: .totalGoodChips) ?? defaults.totalGoodChips
        totalDefectChips = try container.decodeIfPresent(Double.self, forKey: .totalDefectChips) ?? defaults.totalDefectChips
        defectLossYen = try container.decodeIfPresent(Double.self, forKey: .defectLossYen) ?? defaults.defectLossYen
        playSeconds = try container.decodeIfPresent(Double.self, forKey: .playSeconds) ?? defaults.playSeconds
        totalShippedChips = try container.decodeIfPresent(Double.self, forKey: .totalShippedChips) ?? defaults.totalShippedChips
        totalMarketDefectChips = try container.decodeIfPresent(Double.self, forKey: .totalMarketDefectChips) ?? defaults.totalMarketDefectChips
        totalMarketPenaltyYen = try container.decodeIfPresent(Double.self, forKey: .totalMarketPenaltyYen) ?? defaults.totalMarketPenaltyYen
        totalGrossSalesYen = try container.decodeIfPresent(Double.self, forKey: .totalGrossSalesYen) ?? defaults.totalGrossSalesYen
        totalCogsYen = try container.decodeIfPresent(Double.self, forKey: .totalCogsYen) ?? defaults.totalCogsYen
        achievedMilestones = try container.decodeIfPresent([String: Double].self, forKey: .achievedMilestones) ?? defaults.achievedMilestones
        readGlossaryIds = try container.decodeIfPresent(Set<String>.self, forKey: .readGlossaryIds) ?? defaults.readGlossaryIds
        excursionsResolved = try container.decodeIfPresent(Int.self, forKey: .excursionsResolved) ?? defaults.excursionsResolved
        completedLots = try container.decodeIfPresent(Int.self, forKey: .completedLots) ?? defaults.completedLots
        scrappedLots = try container.decodeIfPresent(Int.self, forKey: .scrappedLots) ?? defaults.scrappedLots
        railCellsBuilt = try container.decodeIfPresent(Int.self, forKey: .railCellsBuilt) ?? defaults.railCellsBuilt
        parcelsBought = try container.decodeIfPresent(Int.self, forKey: .parcelsBought) ?? defaults.parcelsBought
    }
}
