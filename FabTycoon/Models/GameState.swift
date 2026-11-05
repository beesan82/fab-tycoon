import Foundation

struct GameState: Codable, Equatable {
    static let currentSchemaVersion = 1

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
    }

    /// 設置済み装置の購入価格合計（改良費は含まない）
    static func equipmentPurchaseTotalYen(_ equipment: [EquipmentInstance]) -> Double {
        equipment.reduce(0.0) { $0 + (Catalog.model(id: $1.modelId)?.priceYen ?? 0) }
    }

    static func initial(now: Date = Date()) -> GameState {
        let starter: [(String, Int)] = [
            ("L1", 1), ("D1", 2), ("E1", 3), ("I1", 1), ("C1", 1), ("Q1", 1), ("P1", 1),
        ]
        var equipment: [EquipmentInstance] = []
        for (modelId, count) in starter {
            for _ in 0..<count {
                equipment.append(EquipmentInstance(modelId: modelId, level: 1, purchasedAt: now))
            }
        }
        return GameState(
            schemaVersion: currentSchemaVersion,
            cashYen: 600_000_000,
            fab: Fab(
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
            ),
            market: MarketState(),
            learningWafers: [:],
            stats: Stats(),
            lastSavedAt: now,
            createdAt: now,
            gameHoursElapsed: 0,
            currentProductId: Catalog.defaultProductId,
            subsidy: SubsidyState(totalInvestedYen: equipmentPurchaseTotalYen(equipment))
        )
    }
}

// 旧セーブ互換：後から追加したフィールドは欠けていてもデフォルト値で読む。
// extension に置くことで memberwise init を残す。
extension GameState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
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
    }
}

/// 国庫補助金の申請・受給状況
struct SubsidyState: Codable, Equatable {
    /// 審査中の交付予定額（0なら申請なし）
    var pendingGrantYen: Double = 0
    /// 交付予定時刻（gameHoursElapsed 基準）。nil なら申請なし
    var pendingGrantAtHours: Double? = nil
    /// 累計設備投資額（購入＋改良）
    var totalInvestedYen: Double = 0
    /// 累計受給額
    var totalReceivedYen: Double = 0
    /// 最終交付時刻（gameHoursElapsed 基準）
    var lastGrantAtHours: Double? = nil

    enum CodingKeys: String, CodingKey {
        case pendingGrantYen
        case pendingGrantAtHours
        case totalInvestedYen
        case totalReceivedYen
        case lastGrantAtHours
    }
}

// 旧セーブ互換：全フィールドを欠けていてもデフォルト値で読む
extension SubsidyState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SubsidyState()
        pendingGrantYen = try container.decodeIfPresent(Double.self, forKey: .pendingGrantYen) ?? defaults.pendingGrantYen
        pendingGrantAtHours = try container.decodeIfPresent(Double.self, forKey: .pendingGrantAtHours) ?? defaults.pendingGrantAtHours
        totalInvestedYen = try container.decodeIfPresent(Double.self, forKey: .totalInvestedYen) ?? defaults.totalInvestedYen
        totalReceivedYen = try container.decodeIfPresent(Double.self, forKey: .totalReceivedYen) ?? defaults.totalReceivedYen
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
    var recentAvgPriceYen: Double = 120_000
}

struct Stats: Codable, Equatable {
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
    }
}
