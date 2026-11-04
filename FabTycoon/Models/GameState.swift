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
                running: true
            ),
            market: MarketState(),
            learningWafers: [:],
            stats: Stats(),
            lastSavedAt: now,
            createdAt: now
        )
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

    var freeSlots: Int { max(0, slots - equipment.count) }
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
}
