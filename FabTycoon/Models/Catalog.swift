import Foundation

// MARK: - 工程

/// 製造工程。順序は固定（ラインの上流→下流）。
enum ProcessType: String, Codable, CaseIterable, Identifiable, Hashable {
    case lithography
    case deposition
    case etching
    case implant
    case cmp
    case inspection
    case packaging

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lithography: return "露光"
        case .deposition: return "成膜"
        case .etching: return "エッチング"
        case .implant: return "イオン注入・熱処理"
        case .cmp: return "CMP"
        case .inspection: return "検査"
        case .packaging: return "ダイシング/パッケージング"
        }
    }

    /// カードやチップ用の短い名前
    var shortName: String {
        switch self {
        case .lithography: return "露光"
        case .deposition: return "成膜"
        case .etching: return "エッチング"
        case .implant: return "注入・熱処理"
        case .cmp: return "CMP"
        case .inspection: return "検査"
        case .packaging: return "PKG"
        }
    }

    /// allCases 上の並び順
    var order: Int { ProcessType.allCases.firstIndex(of: self) ?? 0 }
}

// MARK: - 露光クラス

/// 露光機の世代。duv_dry < duv_imm < euv < high_na の順位を持つ。
enum LithoClass: String, Codable, CaseIterable, Comparable {
    case duvDry = "duv_dry"
    case duvImm = "duv_imm"
    case euv = "euv"
    case highNA = "high_na"

    var rank: Int {
        switch self {
        case .duvDry: return 0
        case .duvImm: return 1
        case .euv: return 2
        case .highNA: return 3
        }
    }

    static func < (lhs: LithoClass, rhs: LithoClass) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - ノード

struct NodeSpec: Identifiable, Equatable {
    let id: String
    let displayName: String
    let diesPerWafer: Int
    let yieldInit: Double
    let yieldMax: Double
    /// 学習の時定数（累計投入ウェハ枚数）
    let learnWafers: Double
    /// チップ1個あたりの基準価格（円）
    let chipBasePriceYen: Double
    /// ウェハ1枚あたりの材料費（円）
    let waferCostYen: Double
    let passes: [ProcessType: Int]
    let lithoPassOverrides: [LithoClass: Int]
}

// MARK: - 装置モデル

struct EquipmentModel: Identifiable, Equatable {
    let id: String
    let name: String
    let process: ProcessType
    let priceYen: Double
    let nominalWPH: Double
    let supportedNodeIds: [String]
    let lithoClass: LithoClass?
    let yieldBonus: Double
    /// 解放条件（nil なら最初から購入可能）
    let unlockNote: String?

    init(
        id: String,
        name: String,
        process: ProcessType,
        priceYen: Double,
        nominalWPH: Double,
        supportedNodeIds: [String],
        lithoClass: LithoClass? = nil,
        yieldBonus: Double = 0,
        unlockNote: String? = nil
    ) {
        self.id = id
        self.name = name
        self.process = process
        self.priceYen = priceYen
        self.nominalWPH = nominalWPH
        self.supportedNodeIds = supportedNodeIds
        self.lithoClass = lithoClass
        self.yieldBonus = yieldBonus
        self.unlockNote = unlockNote
    }

    func supports(nodeId: String) -> Bool {
        supportedNodeIds.contains(nodeId)
    }
}

// MARK: - カタログ

enum Catalog {
    static let startingNodeId = "n28"
    /// スライス1で稼働できるノード
    static let playableNodeIds: Set<String> = ["n28"]

    static let nodes: [NodeSpec] = [
        NodeSpec(
            id: "n28", displayName: "28nm", diesPerWafer: 100,
            yieldInit: 0.70, yieldMax: 0.95, learnWafers: 500,
            chipBasePriceYen: 120_000, waferCostYen: 500_000,
            passes: passTable([30, 40, 40, 15, 10, 5, 1]),
            lithoPassOverrides: [:]
        ),
        NodeSpec(
            id: "n14", displayName: "14nm", diesPerWafer: 120,
            yieldInit: 0.55, yieldMax: 0.92, learnWafers: 1_000,
            chipBasePriceYen: 400_000, waferCostYen: 1_000_000,
            passes: passTable([45, 55, 55, 18, 14, 8, 1]),
            lithoPassOverrides: [:]
        ),
        NodeSpec(
            id: "n7", displayName: "7nm", diesPerWafer: 150,
            yieldInit: 0.40, yieldMax: 0.90, learnWafers: 2_000,
            chipBasePriceYen: 1_200_000, waferCostYen: 2_500_000,
            passes: passTable([70, 80, 80, 20, 18, 10, 1]),
            lithoPassOverrides: [.euv: 35]
        ),
        NodeSpec(
            id: "n5", displayName: "5nm", diesPerWafer: 170,
            yieldInit: 0.32, yieldMax: 0.88, learnWafers: 3_000,
            chipBasePriceYen: 2_500_000, waferCostYen: 4_000_000,
            passes: passTable([40, 90, 90, 22, 20, 12, 1]),
            lithoPassOverrides: [:]
        ),
        NodeSpec(
            id: "n3", displayName: "3nm", diesPerWafer: 200,
            yieldInit: 0.25, yieldMax: 0.85, learnWafers: 4_000,
            chipBasePriceYen: 5_000_000, waferCostYen: 6_000_000,
            passes: passTable([45, 100, 100, 25, 22, 14, 1]),
            lithoPassOverrides: [:]
        ),
        NodeSpec(
            id: "n2", displayName: "2nm", diesPerWafer: 220,
            yieldInit: 0.20, yieldMax: 0.80, learnWafers: 6_000,
            chipBasePriceYen: 10_000_000, waferCostYen: 9_000_000,
            passes: passTable([60, 110, 110, 28, 25, 16, 1]),
            lithoPassOverrides: [.highNA: 40]
        ),
    ]

    static let equipment: [EquipmentModel] = [
        // 露光
        EquipmentModel(id: "L1", name: "ArFドライ露光機", process: .lithography,
                       priceYen: 1_500_000_000, nominalWPH: 150, supportedNodeIds: ["n28"],
                       lithoClass: .duvDry),
        EquipmentModel(id: "L2", name: "ArF液浸露光機", process: .lithography,
                       priceYen: 5_000_000_000, nominalWPH: 170, supportedNodeIds: ["n14", "n7"],
                       lithoClass: .duvImm, unlockNote: "研究「液浸露光機」"),
        EquipmentModel(id: "L3", name: "EUV露光機", process: .lithography,
                       priceYen: 20_000_000_000, nominalWPH: 120, supportedNodeIds: ["n7", "n5", "n3", "n2"],
                       lithoClass: .euv, unlockNote: "研究「EUV露光」"),
        EquipmentModel(id: "L4", name: "High-NA EUV露光機", process: .lithography,
                       priceYen: 40_000_000_000, nominalWPH: 100, supportedNodeIds: ["n3", "n2"],
                       lithoClass: .highNA, unlockNote: "研究「High-NA EUV」"),
        // 成膜
        EquipmentModel(id: "D1", name: "PECVD装置", process: .deposition,
                       priceYen: 300_000_000, nominalWPH: 80, supportedNodeIds: ["n28", "n14"]),
        EquipmentModel(id: "D2", name: "ALD/CVDクラスタ", process: .deposition,
                       priceYen: 1_200_000_000, nominalWPH: 100, supportedNodeIds: ["n14", "n7", "n5"]),
        EquipmentModel(id: "D3", name: "先端ALD装置", process: .deposition,
                       priceYen: 3_500_000_000, nominalWPH: 110, supportedNodeIds: ["n5", "n3", "n2"]),
        // エッチング
        EquipmentModel(id: "E1", name: "プラズマエッチャ", process: .etching,
                       priceYen: 300_000_000, nominalWPH: 60, supportedNodeIds: ["n28", "n14"]),
        EquipmentModel(id: "E2", name: "高選択比エッチャ", process: .etching,
                       priceYen: 1_500_000_000, nominalWPH: 75, supportedNodeIds: ["n14", "n7", "n5"]),
        EquipmentModel(id: "E3", name: "原子層エッチャ（ALE）", process: .etching,
                       priceYen: 4_500_000_000, nominalWPH: 85, supportedNodeIds: ["n5", "n3", "n2"]),
        // イオン注入・熱処理
        EquipmentModel(id: "I1", name: "イオン注入機", process: .implant,
                       priceYen: 400_000_000, nominalWPH: 200, supportedNodeIds: ["n28", "n14", "n7"]),
        EquipmentModel(id: "I2", name: "高エネルギー注入＋レーザーアニール", process: .implant,
                       priceYen: 1_500_000_000, nominalWPH: 220, supportedNodeIds: ["n7", "n5", "n3", "n2"]),
        // CMP
        EquipmentModel(id: "C1", name: "CMP装置", process: .cmp,
                       priceYen: 200_000_000, nominalWPH: 60, supportedNodeIds: ["n28", "n14", "n7"]),
        EquipmentModel(id: "C2", name: "先端CMP装置", process: .cmp,
                       priceYen: 1_000_000_000, nominalWPH: 70, supportedNodeIds: ["n7", "n5", "n3", "n2"]),
        // 検査
        EquipmentModel(id: "Q1", name: "光学検査装置", process: .inspection,
                       priceYen: 250_000_000, nominalWPH: 50, supportedNodeIds: ["n28", "n14"],
                       yieldBonus: 0),
        EquipmentModel(id: "Q2", name: "電子ビーム検査装置", process: .inspection,
                       priceYen: 1_500_000_000, nominalWPH: 45, supportedNodeIds: ["n14", "n7", "n5"],
                       yieldBonus: 0.02, unlockNote: "研究「EB検査装置」"),
        EquipmentModel(id: "Q3", name: "AI欠陥分類検査装置", process: .inspection,
                       priceYen: 5_000_000_000, nominalWPH: 60, supportedNodeIds: ["n5", "n3", "n2"],
                       yieldBonus: 0.04),
        // ダイシング/パッケージング
        EquipmentModel(id: "P1", name: "ブレードダイシング＋ワイヤボンド", process: .packaging,
                       priceYen: 150_000_000, nominalWPH: 30, supportedNodeIds: ["n28", "n14"]),
        EquipmentModel(id: "P2", name: "レーザーダイシング＋フリップチップ", process: .packaging,
                       priceYen: 800_000_000, nominalWPH: 35, supportedNodeIds: ["n14", "n7", "n5"]),
        EquipmentModel(id: "P3", name: "先端パッケージ（2.5D/チップレット）", process: .packaging,
                       priceYen: 3_000_000_000, nominalWPH: 40, supportedNodeIds: ["n5", "n3", "n2"],
                       unlockNote: "研究「先端パッケージ」"),
    ]

    private static let nodeIndex: [String: NodeSpec] =
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    private static let modelIndex: [String: EquipmentModel] =
        Dictionary(uniqueKeysWithValues: equipment.map { ($0.id, $0) })

    static var defaultNode: NodeSpec { nodes[0] }

    static func node(id: String) -> NodeSpec? { nodeIndex[id] }

    static func model(id: String) -> EquipmentModel? { modelIndex[id] }

    static func models(for process: ProcessType) -> [EquipmentModel] {
        equipment.filter { $0.process == process }
    }

    /// 指定ノードの次のノード（なければ nil）
    static func nextNode(after id: String) -> NodeSpec? {
        guard let index = nodes.firstIndex(where: { $0.id == id }), index + 1 < nodes.count else { return nil }
        return nodes[index + 1]
    }

    static func isPlayable(nodeId: String) -> Bool {
        playableNodeIds.contains(nodeId)
    }

    /// ProcessType.allCases の順に並んだパス数配列を辞書にする
    private static func passTable(_ values: [Int]) -> [ProcessType: Int] {
        precondition(values.count == ProcessType.allCases.count, "passes must have 7 entries")
        return Dictionary(uniqueKeysWithValues: zip(ProcessType.allCases, values))
    }
}
