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

// diesPerWafer / chipBasePriceYen / waferCostYen は現状では不使用（データとして保持）。
// 単価・ダイ数は製品側（ProductSpec）、ランニングコストは製品別のCOGS率に統合している。
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
    /// ダイ単価へのノード倍率（製品のダイ単価に乗算）
    let priceMultiplier: Double
    /// 製品の売上原価率への加算（微細化で工程数・材料費が増える分）
    let cogsAddition: Double
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
    /// 歩留まり寄与：この装置で処理したウェハの良品率係数（改良で欠陥寄与が減る）
    let yieldFactor: Double
    /// 検出率の基礎値（検査装置のみ意味を持つ）
    let detectionBase: Double
    /// 解放条件（nil なら最初から購入可能）
    let unlockNote: String?
    /// 解放する研究のid（nil なら研究未実装。unlockNote があれば「準備中」扱い）
    let unlockResearchId: String?

    init(
        id: String,
        name: String,
        process: ProcessType,
        priceYen: Double,
        nominalWPH: Double,
        supportedNodeIds: [String],
        lithoClass: LithoClass? = nil,
        yieldFactor: Double = 0.95,
        detectionBase: Double = 0,
        unlockNote: String? = nil,
        unlockResearchId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.process = process
        self.priceYen = priceYen
        self.nominalWPH = nominalWPH
        self.supportedNodeIds = supportedNodeIds
        self.lithoClass = lithoClass
        self.yieldFactor = yieldFactor
        self.detectionBase = detectionBase
        self.unlockNote = unlockNote
        self.unlockResearchId = unlockResearchId
    }

    func supports(nodeId: String) -> Bool {
        supportedNodeIds.contains(nodeId)
    }
}

// MARK: - 製品

/// 製品の装置要求の選択肢（modelIds のいずれかを合計 count 台以上設置）
struct ProductRequirementOption: Equatable {
    let modelIds: [String]
    let count: Int
}

struct ProductRequirement: Equatable {
    let label: String
    /// OR条件：いずれか1つを満たせばよい
    let options: [ProductRequirementOption]
}

struct ProductSpec: Identifiable, Equatable {
    let id: String
    let name: String
    /// ヘッダーバッジ用の短い名前
    let shortName: String
    /// 学習用の説明文（なぜ単価・歩留まり・ペナルティがそうなるか）
    let description: String
    /// ウェハ1枚から取れるダイ数
    let diesPerWafer: Int
    /// ダイ1個の基準単価（円）
    let diePriceYen: Double
    /// 売上原価率
    let cogsRate: Double
    let yieldMultiplier: Double
    let marketPenaltyMultiplier: Double
    let requirements: [ProductRequirement]
}

// MARK: - カタログ

enum Catalog {
    static let startingNodeId = "n28"
    /// 現在稼働できるノード
    static let playableNodeIds: Set<String> = ["n28", "n14"]

    // priceMultiplier / cogsAddition は n7 以降は将来用のデータ
    static let nodes: [NodeSpec] = [
        NodeSpec(
            id: "n28", displayName: "28nm", diesPerWafer: 100,
            yieldInit: 0.70, yieldMax: 0.95, learnWafers: 6_000,
            chipBasePriceYen: 120_000, waferCostYen: 500_000,
            passes: passTable([15, 20, 20, 8, 5, 3, 1]),
            lithoPassOverrides: [:],
            priceMultiplier: 1.0, cogsAddition: 0.0
        ),
        NodeSpec(
            id: "n14", displayName: "14nm", diesPerWafer: 120,
            yieldInit: 0.55, yieldMax: 0.92, learnWafers: 2_000,
            chipBasePriceYen: 400_000, waferCostYen: 1_000_000,
            passes: passTable([45, 55, 55, 18, 14, 8, 1]),
            lithoPassOverrides: [:],
            priceMultiplier: 3.5, cogsAddition: 0.03
        ),
        NodeSpec(
            id: "n7", displayName: "7nm", diesPerWafer: 150,
            yieldInit: 0.40, yieldMax: 0.90, learnWafers: 2_000,
            chipBasePriceYen: 1_200_000, waferCostYen: 2_500_000,
            passes: passTable([70, 80, 80, 20, 18, 10, 1]),
            lithoPassOverrides: [.euv: 35],
            priceMultiplier: 10.0, cogsAddition: 0.06
        ),
        NodeSpec(
            id: "n5", displayName: "5nm", diesPerWafer: 170,
            yieldInit: 0.32, yieldMax: 0.88, learnWafers: 3_000,
            chipBasePriceYen: 2_500_000, waferCostYen: 4_000_000,
            passes: passTable([40, 90, 90, 22, 20, 12, 1]),
            lithoPassOverrides: [:],
            priceMultiplier: 20.0, cogsAddition: 0.08
        ),
        NodeSpec(
            id: "n3", displayName: "3nm", diesPerWafer: 200,
            yieldInit: 0.25, yieldMax: 0.85, learnWafers: 4_000,
            chipBasePriceYen: 5_000_000, waferCostYen: 6_000_000,
            passes: passTable([45, 100, 100, 25, 22, 14, 1]),
            lithoPassOverrides: [:],
            priceMultiplier: 35.0, cogsAddition: 0.10
        ),
        NodeSpec(
            id: "n2", displayName: "2nm", diesPerWafer: 220,
            yieldInit: 0.20, yieldMax: 0.80, learnWafers: 6_000,
            chipBasePriceYen: 10_000_000, waferCostYen: 9_000_000,
            passes: passTable([60, 110, 110, 28, 25, 16, 1]),
            lithoPassOverrides: [.highNA: 40],
            priceMultiplier: 55.0, cogsAddition: 0.12
        ),
    ]

    static let equipment: [EquipmentModel] = [
        // 露光
        EquipmentModel(id: "L1", name: "ArFドライ露光機", process: .lithography,
                       priceYen: 4_000_000_000, nominalWPH: 150, supportedNodeIds: ["n28"],
                       lithoClass: .duvDry, yieldFactor: 0.950),
        EquipmentModel(id: "L2", name: "ArF液浸露光機", process: .lithography,
                       priceYen: 11_000_000_000, nominalWPH: 275, supportedNodeIds: ["n14", "n7"],
                       lithoClass: .duvImm, yieldFactor: 0.955, unlockNote: "研究「液浸露光機」",
                       unlockResearchId: "unlock_immersion"),
        EquipmentModel(id: "L3", name: "EUV露光機", process: .lithography,
                       priceYen: 26_000_000_000, nominalWPH: 160, supportedNodeIds: ["n7", "n5", "n3", "n2"],
                       lithoClass: .euv, yieldFactor: 0.965, unlockNote: "研究「EUV露光」"),
        EquipmentModel(id: "L4", name: "High-NA EUV露光機", process: .lithography,
                       priceYen: 55_000_000_000, nominalWPH: 180, supportedNodeIds: ["n3", "n2"],
                       lithoClass: .highNA, yieldFactor: 0.970, unlockNote: "研究「High-NA EUV」"),
        // 成膜
        EquipmentModel(id: "D1", name: "PECVD装置", process: .deposition,
                       priceYen: 800_000_000, nominalWPH: 100, supportedNodeIds: ["n28", "n14"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "D2", name: "ALD/CVDクラスタ", process: .deposition,
                       priceYen: 1_500_000_000, nominalWPH: 150, supportedNodeIds: ["n14", "n7", "n5"],
                       yieldFactor: 0.960),
        EquipmentModel(id: "D3", name: "先端ALD装置", process: .deposition,
                       priceYen: 2_500_000_000, nominalWPH: 120, supportedNodeIds: ["n5", "n3", "n2"],
                       yieldFactor: 0.968),
        // エッチング
        EquipmentModel(id: "E1", name: "プラズマエッチャ", process: .etching,
                       priceYen: 800_000_000, nominalWPH: 80, supportedNodeIds: ["n28", "n14"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "E2", name: "高選択比エッチャ", process: .etching,
                       priceYen: 1_500_000_000, nominalWPH: 120, supportedNodeIds: ["n14", "n7", "n5"],
                       yieldFactor: 0.958),
        EquipmentModel(id: "E3", name: "原子層エッチャ（ALE）", process: .etching,
                       priceYen: 2_000_000_000, nominalWPH: 40, supportedNodeIds: ["n5", "n3", "n2"],
                       yieldFactor: 0.970),
        // イオン注入・熱処理
        EquipmentModel(id: "I1", name: "イオン注入機", process: .implant,
                       priceYen: 1_000_000_000, nominalWPH: 100, supportedNodeIds: ["n28", "n14", "n7"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "I2", name: "高エネルギー注入＋レーザーアニール", process: .implant,
                       priceYen: 2_000_000_000, nominalWPH: 150, supportedNodeIds: ["n7", "n5", "n3", "n2"],
                       yieldFactor: 0.955),
        // CMP
        EquipmentModel(id: "C1", name: "CMP装置", process: .cmp,
                       priceYen: 600_000_000, nominalWPH: 60, supportedNodeIds: ["n28", "n14", "n7"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "C2", name: "先端CMP装置", process: .cmp,
                       priceYen: 1_200_000_000, nominalWPH: 90, supportedNodeIds: ["n7", "n5", "n3", "n2"],
                       yieldFactor: 0.960),
        // 検査
        EquipmentModel(id: "Q1", name: "光学検査装置", process: .inspection,
                       priceYen: 1_500_000_000, nominalWPH: 120, supportedNodeIds: ["n28", "n14"],
                       yieldFactor: 0.950, detectionBase: 0.55),
        EquipmentModel(id: "Q2", name: "電子ビーム検査装置", process: .inspection,
                       priceYen: 4_000_000_000, nominalWPH: 15, supportedNodeIds: ["n14", "n7", "n5"],
                       yieldFactor: 0.955, detectionBase: 0.70, unlockNote: "研究「EB検査装置」",
                       unlockResearchId: "unlock_eb"),
        EquipmentModel(id: "Q3", name: "AI欠陥分類検査装置", process: .inspection,
                       priceYen: 6_000_000_000, nominalWPH: 100, supportedNodeIds: ["n5", "n3", "n2"],
                       yieldFactor: 0.960, detectionBase: 0.82),
        // ダイシング/パッケージング
        EquipmentModel(id: "P1", name: "ブレードダイシング＋ワイヤボンド", process: .packaging,
                       priceYen: 300_000_000, nominalWPH: 60, supportedNodeIds: ["n28", "n14"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "P2", name: "レーザーダイシング＋フリップチップ", process: .packaging,
                       priceYen: 800_000_000, nominalWPH: 100, supportedNodeIds: ["n14", "n7", "n5"],
                       yieldFactor: 0.958),
        EquipmentModel(id: "P3", name: "先端パッケージ（2.5D/チップレット）", process: .packaging,
                       priceYen: 3_000_000_000, nominalWPH: 40, supportedNodeIds: ["n5", "n3", "n2"],
                       yieldFactor: 0.962, unlockNote: "研究「先端パッケージ」"),
    ]

    static let defaultProductId = "logic"

    static let products: [ProductSpec] = [
        ProductSpec(
            id: "logic", name: "汎用ロジック", shortName: "汎用ロジック",
            description: "スマホや家電に載る標準的なロジックチップ。需要が安定しており、標準的な設備構成でバランスよく作れる。単価・歩留まり・不良の代償のすべてが基準となる製品。",
            diesPerWafer: 600, diePriceYen: 1_200, cogsRate: 0.45,
            yieldMultiplier: 1.0, marketPenaltyMultiplier: 1.0,
            requirements: []
        ),
        ProductSpec(
            id: "power", name: "パワー／アナログ系", shortName: "パワー・アナログ",
            description: "電源制御やセンサー向けの成熟製品。微細化の限界を攻めない設計なので欠陥が出にくく、歩留まりが高い。その代わりダイが大きく取れる数が少なく、ウェハ1枚あたりの売上は控えめ。",
            diesPerWafer: 250, diePriceYen: 2_000, cogsRate: 0.42,
            yieldMultiplier: 1.25, marketPenaltyMultiplier: 1.0,
            requirements: []
        ),
        ProductSpec(
            id: "highperf", name: "高性能チップ（AI・サーバー向け）", shortName: "高性能チップ",
            description: "AIサーバー向けの最先端チップ。ダイが大きいほど欠陥を含む確率が上がるため歩留まりは下がるが、単価は跳ね上がる。EUV露光と高度な検査が前提で、不良を出したときの代償も大きい。",
            diesPerWafer: 45, diePriceYen: 90_000, cogsRate: 0.55,
            yieldMultiplier: 0.85, marketPenaltyMultiplier: 1.5,
            requirements: [
                ProductRequirement(label: "EUV露光機（L3）以上 1台",
                                   options: [ProductRequirementOption(modelIds: ["L3", "L4"], count: 1)]),
                ProductRequirement(label: "電子ビーム検査（Q2）以上 1台",
                                   options: [ProductRequirementOption(modelIds: ["Q2", "Q3"], count: 1)]),
            ]
        ),
        ProductSpec(
            id: "automotive", name: "車載チップ", shortName: "車載チップ",
            description: "自動車向けのチップ。単価は高めだが、人命に関わるため不良の代償が段違いに重い。返品・リコール対応のコストが大きく、高度な検査体制が実質的に必須となる。",
            diesPerWafer: 500, diePriceYen: 2_000, cogsRate: 0.48,
            yieldMultiplier: 1.0, marketPenaltyMultiplier: 3.0,
            requirements: [
                ProductRequirement(label: "AI検査装置（Q3）1台、または電子ビーム検査（Q2）2台",
                                   options: [
                                       ProductRequirementOption(modelIds: ["Q3"], count: 1),
                                       ProductRequirementOption(modelIds: ["Q2"], count: 2),
                                   ]),
            ]
        ),
    ]

    private static let nodeIndex: [String: NodeSpec] =
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    private static let modelIndex: [String: EquipmentModel] =
        Dictionary(uniqueKeysWithValues: equipment.map { ($0.id, $0) })
    private static let productIndex: [String: ProductSpec] =
        Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })

    static var defaultNode: NodeSpec { nodes[0] }

    static var defaultProduct: ProductSpec { productIndex[defaultProductId] ?? products[0] }

    static func node(id: String) -> NodeSpec? { nodeIndex[id] }

    static func model(id: String) -> EquipmentModel? { modelIndex[id] }

    static func product(id: String) -> ProductSpec? { productIndex[id] }

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

// MARK: - 教育データ

struct EquipmentEducation {
    let summary: String
    let mechanism: String
    let trivia: String
    let makers: [String]
}

extension Catalog {
    static func education(for modelId: String) -> EquipmentEducation? {
        equipmentEducation[modelId]
    }

    static let equipmentEducation: [String: EquipmentEducation] = [
        // 露光
        "L1": EquipmentEducation(
            summary: "ArFエキシマレーザー（波長193nm）で回路パターンを焼く、28nm世代の主力露光機。",
            mechanism: "原版（レチクル）に描かれた回路パターンをレンズで1/4に縮小し、ウェハ上のレジストへ投影する。ウェハを少しずつ動かしながら全面に転写していく（ステップ＆スキャン方式）。",
            trivia: "波長193nmの光で、それよりずっと細かい数十nmのパターンを描く。多重露光などの工夫を重ねた職人芸の賜物。",
            makers: ["ASML", "ニコン", "キヤノン"]
        ),
        "L2": EquipmentEducation(
            summary: "レンズとウェハの間に純水を満たして解像度を高めた、液浸方式の露光機。",
            mechanism: "水の屈折率（約1.44）を利用してレンズの開口数（NA）を1以上に引き上げ、ドライ方式より細かいパターンを描ける。14nm〜7nm世代の主力として長く使われた。",
            trivia: "液浸はもともと顕微鏡の技術。高速で動くウェハの上で水を漏らさず・泡も入れずに保つ制御が最大の難所だった。",
            makers: ["ASML", "ニコン"]
        ),
        "L3": EquipmentEducation(
            summary: "波長13.5nmの極端紫外線（EUV）で最先端パターンを描く、半導体製造の王様。",
            mechanism: "スズの液滴にレーザーを当てて生じるプラズマからEUV光を取り出し、多層膜ミラーで反射させて投影する。EUVは空気に吸収されるため装置内は真空で、レンズではなくミラーを使う。",
            trivia: "価格は1台200億円超。実質的にASMLの独占供給で、輸送には大型貨物機が何機も必要になる。",
            makers: ["ASML"]
        ),
        "L4": EquipmentEducation(
            summary: "EUVの開口数を0.33から0.55へ高め、2nm世代以降を狙う次世代露光機。",
            mechanism: "より大きなミラーと、縦横で拡大率の異なるアナモルフィック光学系で解像度をさらに引き上げた。その代わり一度に露光できる範囲（フィールド）は半分になる。",
            trivia: "価格は約550億円とも言われ、人類史上もっとも高価な製造装置のひとつ。",
            makers: ["ASML"]
        ),
        // 成膜
        "D1": EquipmentEducation(
            summary: "プラズマの力で原料ガスを分解し、絶縁膜などを積む化学気相成長（CVD）装置。",
            mechanism: "真空チャンバー内で原料ガスに高周波をかけてプラズマ化し、化学反応でウェハ表面に薄膜を堆積させる。比較的低い温度で成膜できるため用途が広い。",
            trivia: "CVDは「化学気相成長」の略。温度・圧力・ガス流量のレシピ調整ひとつで膜質が大きく変わる。",
            makers: ["アプライド マテリアルズ", "Lam Research", "東京エレクトロン"]
        ),
        "D2": EquipmentEducation(
            summary: "複数のチャンバーを搬送ロボットで結び、ALDとCVDを連続処理できるクラスタ装置。",
            mechanism: "ウェハを大気に触れさせずにチャンバー間を移動できる。ALD（原子層堆積）は2種類のガスを交互に流し、原子1層ずつ膜を積む究極の薄膜技術。",
            trivia: "ALDの膜厚制御は原子層単位。数十層重ねても誤差は原子数個分という世界。",
            makers: ["ASM", "アプライド マテリアルズ", "Lam Research", "東京エレクトロン"]
        ),
        "D3": EquipmentEducation(
            summary: "立体構造の奥まで均一に膜を届けられる、最先端の原子層堆積（ALD）装置。",
            mechanism: "トランジスタがFinFETからGAAへ立体化すると、複雑な凹凸の隅々まで膜を行き渡らせる段差被覆性が必須になる。ガス分子が回り込むALDはこの要求に応えられる。",
            trivia: "ALDの基礎を作ったのはフィンランドの研究者。2000年代に半導体の主役技術へ躍り出た。",
            makers: ["ASM", "東京エレクトロン", "アプライド マテリアルズ"]
        ),
        // エッチング
        "E1": EquipmentEducation(
            summary: "プラズマ化したガスで膜を削る、標準的なドライエッチング装置。",
            mechanism: "反応性ガスをプラズマにし、イオンをウェハへ垂直に叩きつけて、物理的・化学的に膜を除去する。露光で描いたパターンの通りに掘れるかが勝負。",
            trivia: "液体で溶かすウェットエッチングと違い、ドライ方式は真下へまっすぐ掘れる「異方性」が強み。",
            makers: ["Lam Research", "東京エレクトロン", "アプライド マテリアルズ"]
        ),
        "E2": EquipmentEducation(
            summary: "削りたい膜だけを選んで削る「選択比」を高めたエッチング装置。",
            mechanism: "ガス組成やプラズマのエネルギーを精密に制御し、下地の膜をほぼ傷つけず目的の膜だけを除去する。3D NANDのような深い穴や溝の加工にも使われる。",
            trivia: "3D NANDのメモリ穴は、アスペクト比（深さ÷幅）が50:1を超えることもある。髪の毛より細く、はるかに深い穴を掘る技術。",
            makers: ["Lam Research", "東京エレクトロン"]
        ),
        "E3": EquipmentEducation(
            summary: "原子1層ずつ削る、エッチングの究極形（ALE: 原子層エッチング）。",
            mechanism: "表面を改質するガスと、改質した層だけを除去するプラズマを交互に繰り返し、原子層単位で膜を取り除く。積むALDの「削る版」で、材料へのダメージが極めて小さい。",
            trivia: "積むALDと削るALEを組み合わせると、原子スケールで構造を彫刻できる。",
            makers: ["Lam Research", "東京エレクトロン"]
        ),
        // イオン注入・熱処理
        "I1": EquipmentEducation(
            summary: "不純物イオンを加速してシリコンに撃ち込む、ドーピングの主役。",
            mechanism: "ホウ素やリンなどをイオン化し、電場で加速してウェハに衝突させる。加速電圧で深さを、イオンの量で濃さを精密に制御し、トランジスタの電気特性を作り込む。",
            trivia: "撃ち込まれたイオンは結晶を傷つけるため、この後の熱処理（アニール）で修復・活性化するのがセットになっている。",
            makers: ["アプライド マテリアルズ", "Axcelis", "日新イオン機器"]
        ),
        "I2": EquipmentEducation(
            summary: "深い注入と、表面だけを瞬間加熱するレーザーアニールを組み合わせた先端装置。",
            mechanism: "数MeV級の高エネルギーで深い層まで不純物を届け、レーザーで表面だけをミリ秒単位で加熱して拡散させずに活性化する。",
            trivia: "レーザーアニールは表面の数十nmだけを一瞬で1000℃超に上げる。他の部分はほぼ無傷という離れ業。",
            makers: ["アプライド マテリアルズ", "SCREEN"]
        ),
        // CMP
        "C1": EquipmentEducation(
            summary: "ウェハ表面を磨いて平らにする、化学機械研磨（CMP）装置。",
            mechanism: "回転する研磨パッドにウェハを押し付け、スラリー（微粒子入りの薬液）を流しながら、化学作用と機械研磨で凹凸を削り取る。層を重ねるたびに平坦化するのが現代プロセスの前提。",
            trivia: "CMPの実用化で多層配線が可能になり、今のチップの配線層は10層を超える。",
            makers: ["荏原製作所", "アプライド マテリアルズ"]
        ),
        "C2": EquipmentEducation(
            summary: "研磨の均一性と欠陥管理を究めた、最先端向けCMP装置。",
            mechanism: "パッドやスラリーの状態をリアルタイムに測り、研磨量をその場で補正する。原子数層レベルの平坦さと、傷や残渣の極小化を両立させる。",
            trivia: "研磨しすぎても足りなくても不良になる。「いつ止めるか」の終点検出の精度が歩留まりを左右する。",
            makers: ["荏原製作所", "アプライド マテリアルズ"]
        ),
        // 検査
        "Q1": EquipmentEducation(
            summary: "光を当てて欠陥やパターンの異常を見つけ出す検査装置。",
            mechanism: "ウェハ全面を高速にスキャンし、隣のダイと画像を比べる（ダイ比較）ことで、ゴミ・傷・パターンの欠けなどを早期に発見する。",
            trivia: "欠陥1個でチップ1個が死ぬこともある。早く気づくほど被害は小さくて済む。",
            makers: ["KLA", "日立ハイテク"]
        ),
        "Q2": EquipmentEducation(
            summary: "電子ビームで、光では見えない微細欠陥や電気的な不良まで検出する検査装置。",
            mechanism: "電子線を走査して得られる信号から、数nm級の欠陥や、配線の断線・短絡といった電圧コントラストを捉える。光学検査より時間はかかるが分解能が高い。",
            trivia: "見た目では分からない「電気的に死んでいる」箇所まで見抜けるのが電子ビームの真骨頂。",
            makers: ["KLA", "日立ハイテク", "アプライド マテリアルズ"]
        ),
        "Q3": EquipmentEducation(
            summary: "検出した欠陥をAIが自動で種類分けし、原因究明を高速化する検査装置。",
            mechanism: "膨大な欠陥画像を学習したAIが、「ゴミ」「傷」「パターン異常」などへ自動分類（ADC）する。どの工程で何が起きたかを素早く特定し、歩留まり改善のサイクルを回す。",
            trivia: "熟練エンジニアの「目」をAIが肩代わり。人手不足のファブでは欠かせない存在になっている。",
            makers: ["KLA", "日立ハイテク"]
        ),
        // ダイシング/パッケージング
        "P1": EquipmentEducation(
            summary: "ダイヤモンドブレードでウェハを切り分け、金線で端子をつなぐ後工程装置。",
            mechanism: "高速回転する薄いブレードでウェハをダイごとに切断（ダイシング）し、切り出したチップを基板に載せて金や銅のワイヤで配線する（ワイヤボンディング）。",
            trivia: "切断幅（カーフ）を狭めるほど、1枚のウェハから取れるチップの数が増える。",
            makers: ["ディスコ", "東京精密"]
        ),
        "P2": EquipmentEducation(
            summary: "レーザーで切り屑なく切り分け、チップを裏返して直接つなぐ先端の後工程。",
            mechanism: "ウェハ内部にレーザーで改質層を作り、割るように分離するステルスダイシングは切り屑が出ない。フリップチップはチップ全面の突起（バンプ）で基板と接続するため配線が短く高速。",
            trivia: "ステルスダイシングは日本のディスコが得意とする技術。薄いウェハでも割れにくい。",
            makers: ["ディスコ", "芝浦メカトロニクス"]
        ),
        "P3": EquipmentEducation(
            summary: "複数のチップをひとかたまりに接続する、チップレット時代の先端パッケージ装置群。",
            mechanism: "シリコンインターポーザや再配線層の上に複数のダイを高密度に載せ、微細なバンプで接続する。巨大な1チップを作るより歩留まり・コストで有利な場合がある（TSMCのCoWoSなどが代表例）。",
            trivia: "AIアクセラレータの多くがこの方式。HBMメモリとGPUを隣り合わせに載せるのが定番構成。",
            makers: ["芝浦メカトロニクス", "TOWA", "東京エレクトロン"]
        ),
    ]
}

extension ProcessType {
    /// 学習用の工程説明
    var educationText: String {
        switch self {
        case .lithography:
            return "ウェハに塗った感光膜（フォトレジスト）へ、回路パターンを光で焼き付ける工程。全工程で最も精度が求められ、世代（ノード）の細かさは実質この露光で決まる。何十層もの回路を重ねるため、ウェハはこの工程を何十回も行き来する。"
        case .deposition:
            return "ウェハの表面に、絶縁膜・金属膜・半導体膜といった薄膜を原子レベルで積み上げる工程。トランジスタのゲートや配線の材料はここで作られる。数ナノメートルの膜厚の均一さが、そのまま性能と歩留まりを左右する。"
        case .etching:
            return "露光で描かれたパターンに沿って、不要な膜を削り取る工程。プラズマ化したガスとの化学反応で真下にまっすぐ掘り進める。深さと側壁の垂直さの制御が難しく、歩留まりを大きく左右する職人技の工程。"
        case .implant:
            return "シリコンにホウ素やリンなどの不純物イオンを撃ち込み、電気の流れやすさを変える工程。これでトランジスタの特性が決まる。注入で傷ついた結晶は、続く熱処理（アニール）で修復され、不純物が活性化する。"
        case .cmp:
            return "化学機械研磨。研磨液（スラリー）を流しながらウェハ表面を磨き、成膜やエッチングで生じた凹凸を平らにする工程。表面が平坦でないと次の露光でピントが合わず、パターンがぼやけてしまう。多層配線を可能にした立役者。"
        case .inspection:
            return "欠陥や寸法のズレを、光や電子ビームで見つけ出す工程。途中で問題に早く気づけば、無駄な後工程を進めずに済み、歩留まり改善の手がかりも得られる。ものは作らないが、利益を守る要の工程。不良は各工程で生まれ、検査で初めて見つかる。検査が弱いと不良はそのまま客先に届き、返品や信用問題につながる。"
        case .packaging:
            return "完成したウェハをチップ（ダイ）ごとに切り分け、基板に載せて樹脂で封止する後工程。外部端子とつながって、初めて電子部品として使えるようになる。近年は複数のチップを組み合わせる先端パッケージが性能を大きく左右する。"
        }
    }
}

extension ProcessType {
    /// 現実の所要時間の目安（学習用）
    var realDurationText: String {
        switch self {
        case .lithography:
            return "目安：露光そのものは1枚あたり数十秒〜数分。ただし28nmでは約15回繰り返すため、露光だけで何時間も積み上がる"
        case .deposition:
            return "目安：1回あたり数分〜数十分。膜の種類や、複数枚をまとめるバッチ処理かどうかで大きく変わる"
        case .etching:
            return "目安：1回あたり数分程度。3D NANDのような深い穴を掘る工程では、十数分以上かかることもある"
        case .implant:
            return "目安：イオン注入は1回あたり数分。一方、酸化・拡散・アニールなどの熱処理は数時間単位のバッチ処理になる"
        case .cmp:
            return "目安：1回あたり数分程度。ただし層を重ねるたびに繰り返し登場する"
        case .inspection:
            return "目安：1回あたり数分〜。ウェハ全面を細かくスキャンする検査では、1枚に数十分かかることもある"
        case .packaging:
            return "目安：ダイシングは1枚あたり数分。組立・封止・最終テストまで含めると、日単位の時間がかかる工程もある"
        }
    }
}

extension ProcessType {
    /// 前後の工程とのつながり（学習用）
    var connectionNote: String {
        switch self {
        case .lithography: return "成膜→露光→エッチングの繰り返しの中心。層を重ねるたびに戻ってくる、ラインの心臓部。"
        case .deposition: return "露光の前に膜を用意し、エッチングの後にもまた積む。露光・エッチングと組になって何度も繰り返す。"
        case .etching: return "露光で描かれたパターンを実際に掘る工程。終わるとまた成膜→露光へ戻って、次の層を作り始める。"
        case .implant: return "トランジスタを作る前半戦の要所。成膜・エッチングで形を作った直後に電気特性を決め、熱処理で仕上げる。"
        case .cmp: return "各層の仕上げ役。表面を平らにしてから、次の層の成膜・露光へウェハを渡す。層が増えるほど出番が増える。"
        case .inspection: return "各工程の合間に何度も入る番人。問題を早期に見つけて、後工程の無駄な作業を止める。"
        case .packaging: return "前工程の出口。完成したウェハを受け取り、チップとして世の中へ送り出す最終工程。"
        }
    }
}

// MARK: - 研究

/// 研究の系統（研究タブのセグメント）
enum ResearchBranch: String, CaseIterable, Identifiable {
    case production, quality, operations, platform

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .production: return "生産"
        case .quality: return "品質"
        case .operations: return "運用"
        case .platform: return "基盤"
        }
    }
}

/// 研究完了で得られる効果
enum ResearchEffect: Equatable {
    /// 全工程の実効WPHに乗算
    case throughput(multiplier: Double)
    /// 稼働率に加算
    case uptime(addition: Double)
    /// 各装置の欠陥寄与 (1 − yieldFactor) に乗算。1未満で改善
    case yieldDefect(multiplier: Double)
    /// 学習時定数に乗算。1未満で学習が速い
    case learnWafers(multiplier: Double)
    /// オフライン効率に加算
    case offlineEfficiency(addition: Double)
    /// オフライン上限に加算
    case offlineCap(additionalSeconds: Double)
    /// 解放キー（装置モデルID、または "node14"）
    case unlock(String)
}

struct ResearchSpec: Identifiable, Equatable {
    let id: String
    let name: String
    let branch: ResearchBranch
    let costYen: Double
    /// 実時間（秒）
    let durationSeconds: Double
    let prerequisiteId: String?
    let effect: ResearchEffect
    /// 効果の表示文（例「全工程の処理速度 +5%」）
    let effectText: String
    /// 学習テキスト（2〜3文）
    let learningText: String
}

extension Catalog {
    /// 研究ツリー。並びは研究タブでの表示順
    static let research: [ResearchSpec] = [
        // 生産
        ResearchSpec(
            id: "throughput_1", name: "スループット改善Ⅰ", branch: .production,
            costYen: 300_000_000, durationSeconds: 300, prerequisiteId: nil,
            effect: .throughput(multiplier: 1.05),
            effectText: "全工程の処理速度 +5%",
            learningText: "装置の処理能力は、カタログ値だけでなく段取り替えやレシピの組み方で大きく変わる。品種切り替え時の待ち時間を減らし、処理条件を最適化して1枚あたりの時間を詰めるのが、現場のスループット改善の基本。"
        ),
        ResearchSpec(
            id: "throughput_2", name: "スループット改善Ⅱ", branch: .production,
            costYen: 1_800_000_000, durationSeconds: 1_500, prerequisiteId: "throughput_1",
            effect: .throughput(multiplier: 1.05),
            effectText: "全工程の処理速度 +5%",
            learningText: "次の段階では、複数のウェハをまとめて流すバッチ構成や、チャンバーの並列処理を見直してレシピ自体を短縮する。工程ごとの待ち時間を数秒ずつ削る地道な積み重ねが、ライン全体の生産量を押し上げる。"
        ),
        ResearchSpec(
            id: "uptime_1", name: "稼働率向上Ⅰ", branch: .production,
            costYen: 800_000_000, durationSeconds: 720, prerequisiteId: nil,
            effect: .uptime(addition: 0.02),
            effectText: "稼働率 +2%",
            learningText: "装置が止まる原因には、計画的な保守のほかに「チョコ停」と呼ばれる短時間の停止の積み重ねがある。部品の摩耗を見越した予防保全と、チョコ停の原因をひとつずつ潰す改善活動で、装置が実際に動いている時間を増やせる。"
        ),
        // 品質
        ResearchSpec(
            id: "cleanroom", name: "クリーン度向上", branch: .quality,
            costYen: 1_200_000_000, durationSeconds: 1_080, prerequisiteId: nil,
            effect: .yieldDefect(multiplier: 0.95),
            effectText: "各装置の欠陥寄与 −5%",
            learningText: "微細な回路では、目に見えないパーティクル1個が断線や短絡を起こしてチップを不良にする。空調フィルタや気流の設計、作業者の動線管理でパーティクルを減らすことが、そのまま歩留まりの向上につながる。"
        ),
        ResearchSpec(
            id: "cleaning", name: "洗浄工程改善", branch: .quality,
            costYen: 500_000_000, durationSeconds: 480, prerequisiteId: nil,
            effect: .learnWafers(multiplier: 0.8),
            effectText: "歩留まりの学習速度 +25%",
            learningText: "ウェハ洗浄は全工程の2〜3割を占めるほど頻繁に行われ、薬液や純水で微粒子・金属汚染・有機物を取り除く。洗浄条件を見直すと欠陥の原因を早く断てるため、量産立ち上げ時の歩留まり改善が速くなる。"
        ),
        // 運用
        ResearchSpec(
            id: "transport", name: "搬送自動化", branch: .operations,
            costYen: 1_500_000_000, durationSeconds: 1_200, prerequisiteId: nil,
            effect: .offlineEfficiency(addition: 0.10),
            effectText: "オフライン効率 +10%",
            learningText: "先端ファブでは、ウェハを収めた容器（FOUP）を天井の走行レールで装置間に運ぶAMHS（自動搬送システム）が使われる。人手を介さずに搬送できるため、作業者が少ない時間帯でもラインを止めずに回せる。"
        ),
        ResearchSpec(
            id: "offline_cap_1", name: "オフライン上限Ⅰ", branch: .operations,
            costYen: 700_000_000, durationSeconds: 600, prerequisiteId: nil,
            effect: .offlineCap(additionalSeconds: 7_200),
            effectText: "オフライン上限 +2時間",
            learningText: "装置の異常検知や搬送、ロット投入を自動化すると、夜間や休日も少人数でラインを回せる。人がいない時間にどれだけ安定して動かせるかが、無人運転の時間を延ばす鍵になる。"
        ),
        // 基盤
        ResearchSpec(
            id: "unlock_immersion", name: "液浸露光機", branch: .platform,
            costYen: 2_000_000_000, durationSeconds: 1_800, prerequisiteId: nil,
            effect: .unlock("L2"),
            effectText: "ArF液浸露光機（L2）を解放",
            learningText: "レンズとウェハの間を純水で満たすと、水の屈折率（約1.44）の分だけ開口数を大きくでき、同じ193nmの光でより細かいパターンを描ける。液浸と多重露光の組み合わせが、14nm〜7nm世代を支えた。"
        ),
        ResearchSpec(
            id: "unlock_eb", name: "EB検査装置", branch: .platform,
            costYen: 2_500_000_000, durationSeconds: 1_800, prerequisiteId: nil,
            effect: .unlock("Q2"),
            effectText: "電子ビーム検査装置（Q2）を解放",
            learningText: "電子ビームは光より波長がはるかに短いため、光学検査では見えない数nm級の微小欠陥まで捉えられる。配線の断線や短絡を電位の明暗として浮かび上がらせることもでき、処理は遅いが見逃しが少ない。"
        ),
        ResearchSpec(
            id: "unlock_14nm", name: "14nmプロセス", branch: .platform,
            costYen: 4_000_000_000, durationSeconds: 3_600, prerequisiteId: "unlock_immersion",
            effect: .unlock("node14"),
            effectText: "14nmプロセスを解放",
            learningText: "14nm世代では、平面トランジスタからチャネルを立体的なひれ状にしたFinFETへ移行した。ゲートがチャネルを三方から囲むため漏れ電流を抑えられる一方、工程数は大きく増え、製造の難度も一段上がる。"
        ),
    ]

    private static let researchIndex: [String: ResearchSpec] =
        Dictionary(uniqueKeysWithValues: research.map { ($0.id, $0) })

    static func research(id: String) -> ResearchSpec? { researchIndex[id] }
}

// MARK: - マイルストーン

/// マイルストーンの達成条件
enum MilestoneCondition: Equatable {
    /// subsidy.totalInvestedYen > 0
    case firstInvestment
    case lineWPHAtLeast(Double)
    case lineYieldAtLeast(Double)
    case detectionRateAtLeast(Double)
    /// stats.totalWafersInput
    case cumulativeWafersAtLeast(Double)
    /// stats.totalGrossSalesYen
    case cumulativeGrossSalesAtLeast(Double)
    /// fab.expansionCount
    case expansionCountAtLeast(Int)
    /// 設置＋倉庫の全装置の最大レベル
    case maxLevelAtLeast(Int)
    /// subsidy.totalReceivedYen > 0
    case subsidyReceived
    /// currentProductId != Catalog.defaultProductId
    case nonDefaultProduct
    /// fab.currentNodeId が指定ノード
    case currentNodeIs(String)
    /// 指定ノードで稼働中かつライン歩留まりが target 以上
    case lineYieldAtLeastOnNode(nodeId: String, target: Double)
}

struct MilestoneSpec: Identifiable, Equatable {
    let id: String
    let title: String
    let condition: MilestoneCondition
    /// 達成時に読む学習ノート
    let learningNote: String
}

extension Catalog {
    /// 経営目標。並びは達成想定順
    static let milestones: [MilestoneSpec] = [
        MilestoneSpec(
            id: "first_investment", title: "初めての設備投資", condition: .firstInvestment,
            learningNote: "装置を買う・改良するのがファブ経営の第一歩。現実のファブでは設備投資（CAPEX）が資金繰りの中心で、1台100億円を超える装置も珍しくない。"
        ),
        MilestoneSpec(
            id: "wph_10", title: "ラインWPH 10到達", condition: .lineWPHAtLeast(10),
            learningNote: "WPHは1時間に処理できるウェハの枚数。ライン全体の速度は一番遅い工程（ボトルネック）で決まるため、速い工程だけを増やしても全体は速くならない。"
        ),
        MilestoneSpec(
            id: "product_switch", title: "製品を切り替える", condition: .nonDefaultProduct,
            learningNote: "ファブが作るのは1種類の製品だけではない。需要や単価に合わせて製品ミックスを変えるのも、ファウンドリ経営の重要な判断になる。"
        ),
        MilestoneSpec(
            id: "detection_80", title: "検出率80%", condition: .detectionRateAtLeast(0.80),
            learningNote: "検出率は『検査装置の基礎性能』と『ラインに対する検査能力の余裕』で決まる。検査に余裕があるほど見逃しが減り、不良が客先に届く事故も減る。"
        ),
        MilestoneSpec(
            id: "yield_80", title: "ライン歩留まり80%", condition: .lineYieldAtLeast(0.80),
            learningNote: "歩留まりは工程ごとの良品率の掛け算。7工程すべて95%でも全体では約70%にしかならない。だから各工程の小さな改善が効いてくる。"
        ),
        MilestoneSpec(
            id: "wafers_5000", title: "累計ウェハ5,000枚", condition: .cumulativeWafersAtLeast(5_000),
            learningNote: "ウェハを流し続けることで現場の知恵が蓄積し、歩留まりが上がっていく（学習曲線）。量産の立ち上げは『ランプ』と呼ばれる。"
        ),
        MilestoneSpec(
            id: "upgrade_lv5", title: "改良レベル5到達", condition: .maxLevelAtLeast(5),
            learningNote: "装置の改良は買い替えより安く性能を伸ばす手段。ただし効果は少しずつ弱まるので、改良と新規購入のバランスが経営の腕の見せどころ。"
        ),
        MilestoneSpec(
            id: "subsidy_received", title: "補助金の初受給", condition: .subsidyReceived,
            learningNote: "半導体は国家戦略産業。各国が巨額の補助金でファブを誘致していて、日本でもTSMC熊本工場（JASM）やRapidusに国費が投じられている。"
        ),
        MilestoneSpec(
            id: "first_expansion", title: "初の増床", condition: .expansionCountAtLeast(1),
            learningNote: "クリーンルームの拡張はファブの大きな節目。床面積がそのまま生産能力の上限になるため、将来の需要を見越した投資判断が求められる。"
        ),
        MilestoneSpec(
            id: "sales_100oku", title: "累計売上100億円", condition: .cumulativeGrossSalesAtLeast(10_000_000_000),
            learningNote: "売上100億円は小規模ファブの年商規模。現実の大規模ファブは年商1兆円を超え、TSMC全体では10兆円規模になる。"
        ),
        MilestoneSpec(
            id: "wph_17", title: "ラインWPH 17（露光均衡ライン）", condition: .lineWPHAtLeast(17),
            learningNote: "露光機2台がフル稼働する均衡ライン。最も高価な露光機を遊ばせないよう他工程を揃えるのが、ライン設計の基本とされる。"
        ),
        MilestoneSpec(
            id: "yield_90", title: "ライン歩留まり90%", condition: .lineYieldAtLeast(0.90),
            learningNote: "歩留まり90%は量産ラインとして一流の水準。ここからは欠陥密度の低減と学習の積み重ねがものを言う領域になる。"
        ),
        MilestoneSpec(
            id: "node_14", title: "14nm到達", condition: .currentNodeIs("n14"),
            learningNote: "14nmではトランジスタが平面型から立体的なFinFETに変わる。液浸露光に加えて1層を複数回に分けて描く多重露光が必要になり、工程数は28nmの2〜3倍に膨らむ。"
        ),
        MilestoneSpec(
            id: "yield_80_n14", title: "14nm歩留まり80%", condition: .lineYieldAtLeastOnNode(nodeId: "n14", target: 0.80),
            learningNote: "新しいノードの歩留まりは、旧ノードで積み上げた学習がそのまま使えず、低い値からランプし直しになる。量産を流しながら欠陥の原因を一つずつ潰していくことで、ようやく旧ノード並みの水準に追いつく。"
        ),
    ]

    private static let milestoneIndex: [String: MilestoneSpec] =
        Dictionary(uniqueKeysWithValues: milestones.map { ($0.id, $0) })

    static func milestone(id: String) -> MilestoneSpec? { milestoneIndex[id] }
}

// MARK: - 図鑑（用語集）

/// 図鑑エントリの解放条件
enum GlossaryUnlock: Equatable {
    case always
    /// そのモデルを設置中または倉庫に所有
    case ownModel(String)
    /// マイルストーン達成
    case milestone(String)
    /// stats.totalGrossSalesYen
    case grossSalesAtLeast(Double)
    /// stats.totalDefectChips > 0
    case defectDetected
    /// stats.totalMarketDefectChips > 0
    case marketDefectOccurred
}

struct GlossaryTerm: Identifiable, Equatable {
    let id: String
    let term: String
    /// "基礎" / "製造" / "品質" / "経営"
    let category: String
    /// 2〜3文の平易な解説（ゲーム内の意味と現実の意味の両方に触れる）
    let body: String
    let unlock: GlossaryUnlock
}

extension Catalog {
    /// 図鑑の装置エントリid（"eq." + modelId）
    static func equipmentGlossaryId(_ modelId: String) -> String { "eq." + modelId }

    /// 図鑑の工程エントリid（"proc." + rawValue）
    static func processGlossaryId(_ process: ProcessType) -> String { "proc." + process.rawValue }

    /// 図鑑の全エントリ数（装置＋工程＋用語）
    static var glossaryEntryCount: Int {
        equipment.count + ProcessType.allCases.count + glossaryTerms.count
    }

    static let glossaryTerms: [GlossaryTerm] = [
        // 最初から読める用語
        GlossaryTerm(
            id: "term.wafer", term: "ウェハ", category: "基礎",
            body: "半導体チップの土台になる、シリコンの円い薄板。現実の先端ファブでは直径300mmが標準で、1枚の上に数百〜数千個のチップを同時に作り込む。このゲームでは汎用ロジックなら1枚から600個のダイが取れる。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.die", term: "ダイ", category: "基礎",
            body: "ウェハ上に碁盤の目のように並ぶ、チップ1個分の区画。完成後にダイシングで切り分けられ、パッケージに収められて製品になる。ダイが大きいほど1枚から取れる数が減り欠陥も含みやすくなるため、このゲームの高性能チップは1枚45個・歩留まり倍率×0.85になっている。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.node", term: "ノード", category: "基礎",
            body: "28nm・14nm・7nmのように呼ばれる製造プロセスの世代で、数字が小さいほど微細で先端になる。現在の数字は実際の寸法とは一致しない「世代名」で、微細化するほど工程の繰り返し（パス数）が増えて製造は難しくなる。このゲームは28nmから始まり、ノードごとに歩留まりの初期値・上限と学習の速さが違う。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.wph", term: "WPH", category: "基礎",
            body: "Wafers Per Hour（1時間あたりの処理ウェハ枚数）の略で、装置やラインの速さを表す。このゲームでは装置の公称WPHをパス数で割り、稼働率85%を掛けたものが工程の実効WPHになる。例えば28nmで20パスの成膜に公称100WPHのPECVDを2台置くと、2×100÷20×0.85＝8.5WPH。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.bottleneck", term: "ボトルネック／律速", category: "基礎",
            body: "ラインの中で一番遅い工程のこと。ウェハは全工程を順に通るので、ライン全体のWPHはボトルネック工程のWPHで頭打ちになる（律速）。このゲームで装置を足すならまずボトルネックの工程に。それ以外の工程を増やしてもラインWPHは増えない。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.yield", term: "歩留まり", category: "品質",
            body: "作ったチップのうち良品になる割合。このゲームのライン歩留まりは、7工程の工程歩留まりの積に、学習による欠陥の縮小と製品の歩留まり倍率を反映して決まる。現実でも歩留まりはファブの利益を最も大きく左右する指標で、数%の違いが収益を大きく変える。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.resist", term: "フォトレジスト", category: "製造",
            body: "光が当たった部分だけ性質が変わる感光性の樹脂。ウェハに薄く塗って露光すると、回路パターンが化学的な「潜像」として焼き付く。JSR・東京応化工業・信越化学などが世界シェアの大半を握る、日本が強い材料分野。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.develop", term: "現像", category: "製造",
            body: "露光後のウェハに現像液をかけ、レジストの不要な部分を溶かしてパターンを浮かび上がらせる工程。残ったレジストがマスクになり、続くエッチングやイオン注入で「ここだけ加工する」範囲を決める。塗布と現像は露光機とつながったコータ／デベロッパが担い、このゲームでは露光工程に含めて扱っている。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.dryetch", term: "ドライエッチング", category: "製造",
            body: "プラズマ化したガスで膜を削る加工法。イオンを真下へ打ち込むため、液体で溶かすウェットエッチングと違って垂直にまっすぐ掘れる（異方性）。このゲームの28nmではエッチング工程を20回通り、成膜と並んで最もパス数の多い工程になっている。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.cmp", term: "CMP", category: "製造",
            body: "Chemical Mechanical Polishing（化学機械研磨）の略。スラリーと呼ぶ研磨液を流しながらウェハを磨き、表面を平らにする。表面が平らでないと次の露光でピントが合わないため層ごとに欠かせず、このゲームの28nmでは5回通る。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.doping", term: "ドーピング", category: "製造",
            body: "シリコンにホウ素やリンなどの不純物をわずかに加え、電気の流れやすさを変えること。加える元素によって電子が運ぶn型と正孔が運ぶp型の領域ができ、その組み合わせでトランジスタが働く。このゲームではイオン注入・熱処理工程がこれを担う。",
            unlock: .always
        ),
        GlossaryTerm(
            id: "term.thinfilm", term: "薄膜", category: "製造",
            body: "ウェハ上に積む、厚さ数nm〜数μmの膜。絶縁膜・配線用の金属膜・半導体膜などを、CVD・ALD・スパッタなどで目的に応じて作り分ける。チップは膜を積んでは削るを何十回も繰り返してできており、このゲームでも成膜工程は28nmで20回通る。",
            unlock: .always
        ),
        // 出来事で解放
        GlossaryTerm(
            id: "term.defect", term: "欠陥とパーティクル", category: "品質",
            body: "パーティクル（微小なゴミ）、傷、パターンの欠けなど、チップを不良にする原因の総称。ナノメートル単位の回路では、目に見えない微粒子1個で配線が断線・短絡することがある。このゲームでは工程歩留まりの低さが欠陥として現れ、検査で見つかったものは廃棄されて「欠陥チップ」に数えられる。",
            unlock: .defectDetected
        ),
        GlossaryTerm(
            id: "term.market_defect", term: "市場不良", category: "品質",
            body: "検査をすり抜けて客先に届いてしまった不良品。返品・交換・原因調査の費用に加え、信用の低下という目に見えないコストも生む。このゲームでは見逃した不良1個ごとに販売額の150%（車載チップは3倍の450%）がペナルティとして差し引かれる。",
            unlock: .marketDefectOccurred
        ),
        GlossaryTerm(
            id: "term.cogs", term: "原価率", category: "経営",
            body: "売上のうち、材料・薬液・電力・人件費など製造にかかった費用（売上原価）の割合。このゲームでは汎用ロジックの原価率が45%で、売上から原価と市場不良ペナルティを引いた残りが粗利として資金に入る。現実のTSMCは売上総利益率（1−原価率）が50%台と、製造業としては際立って高い。",
            unlock: .grossSalesAtLeast(10_000_000)
        ),
        GlossaryTerm(
            id: "term.market", term: "市況", category: "経営",
            body: "半導体の需要と価格の波のこと。半導体業界は数年周期で好況と不況を繰り返す「シリコンサイクル」で知られる。このゲームでも単価は周期的な波とランダムな揺れで上下するので、自動販売を止めて在庫をため、好況で売るという判断もできる。",
            unlock: .grossSalesAtLeast(100_000_000)
        ),
        // マイルストーンで解放
        GlossaryTerm(
            id: "term.duv", term: "DUV", category: "製造",
            body: "Deep Ultraviolet（深紫外線）の略で、波長248nmのKrFや193nmのArFのレーザー光を使う露光技術。このゲームの最初の露光機L1はArFドライ方式で、28nm世代の主力。レンズとウェハの間を水で満たす液浸（L2）と多重露光を組み合わせ、7nm世代まで使われてきた。",
            unlock: .milestone("first_investment")
        ),
        GlossaryTerm(
            id: "term.subsidy", term: "補助金", category: "経営",
            body: "国や自治体が企業の投資の一部を負担する制度。半導体は経済安全保障の要とされ、日本・米国・欧州などが巨額の補助金でファブを誘致している。このゲームでは累計設備投資の1/3を上限に申請でき、審査に12分、交付後は72分のクールダウンがある。",
            unlock: .milestone("first_investment")
        ),
        GlossaryTerm(
            id: "term.uptime", term: "稼働率とOEE", category: "基礎",
            body: "稼働率は装置が実際に動いている時間の割合で、このゲームでは全装置一律85%としている。OEE（総合設備効率）は、稼働率に速度のロスと不良のロスまで掛け合わせた、設備の実力を表す指標。保守・段取り替え・故障があるため、現実の装置も100%は動けない。",
            unlock: .milestone("wph_10")
        ),
        GlossaryTerm(
            id: "term.power_device", term: "パワーデバイス", category: "製造",
            body: "電力の変換や制御を担う半導体で、電気自動車・鉄道・家電の電源などに使われる。微細さより高い電圧や大電流に耐える構造が大切で、成熟したプロセスでも作れる。このゲームのパワー／アナログ系は欠陥が出にくく歩留まり倍率×1.25だが、1枚から取れるダイは250個と少ない。",
            unlock: .milestone("product_switch")
        ),
        GlossaryTerm(
            id: "term.automotive_grade", term: "車載グレード", category: "品質",
            body: "自動車向けの半導体に求められる、高温や振動に耐える信頼性と極めて低い不良率の基準。AEC-Q100などの規格があり、不良率はppm（百万分の1）単位で管理され「ゼロ・ディフェクト」が目標とされる。このゲームの車載チップは市場不良のペナルティが3倍で、高度な検査装置が必須になっている。",
            unlock: .milestone("product_switch")
        ),
        GlossaryTerm(
            id: "term.defect_density", term: "欠陥密度", category: "品質",
            body: "ウェハの単位面積あたりに含まれる、チップを不良にする欠陥の数（D0とも呼ぶ）。欠陥がランダムに散らばると考えると、歩留まりはおおよそ exp(−ダイ面積×欠陥密度) で決まり、ダイが大きいほど急に下がる。このゲームで高性能チップの歩留まりが低いのも、大きなダイほど欠陥を含みやすいから。",
            unlock: .milestone("yield_80")
        ),
        GlossaryTerm(
            id: "term.screening", term: "スクリーニング", category: "品質",
            body: "検査やテストで不良品をふるい落とし、良品だけを出荷すること。不良を作らない（歩留まり）ことと、作った不良を外に出さない（スクリーニング）ことは品質管理の両輪。このゲームでは検出率の分だけ不良が廃棄され、残りは良品に混ざって出荷される。",
            unlock: .milestone("detection_80")
        ),
        GlossaryTerm(
            id: "term.die_compare", term: "ダイ比較", category: "品質",
            body: "検査装置が欠陥を見つける代表的な方法。同じ回路パターンが並ぶ隣どうしのダイの画像を比べ、違う箇所を欠陥候補として拾う。このゲームの光学検査装置（Q1）もこの方式で、基礎検出率55%に検査能力の余裕による上乗せが加わる。",
            unlock: .milestone("detection_80")
        ),
        GlossaryTerm(
            id: "term.learning_curve", term: "学習曲線", category: "品質",
            body: "生産量が増えるほど経験が蓄積し、品質やコストが改善していく現象。このゲームでは28nmで累計6,000枚を時定数として欠陥が指数関数的に減り、最終的に学習前の約1/6まで縮む。現実でも新工程の立ち上げ直後は歩留まりが低く、量産を重ねて改善していく。",
            unlock: .milestone("wafers_5000")
        ),
        GlossaryTerm(
            id: "term.pm", term: "予防保全", category: "経営",
            body: "故障してから直す事後保全に対し、故障する前に計画的な部品交換や清掃を行って装置を安定させる考え方（PM: Preventive Maintenance）。半導体装置は1台止まるだけでライン全体の律速になることがあるため、計画停止で突発停止を減らすのが基本。このゲームの稼働率85%は、こうした保守の時間も見込んだ値として扱っている。",
            unlock: .milestone("upgrade_lv5")
        ),
        GlossaryTerm(
            id: "term.capex", term: "設備投資", category: "経営",
            body: "CAPEX（Capital Expenditure）とも呼ばれ、装置や建屋などの長く使う資産に投じるお金。大手ファウンドリは年に数兆円規模を投じ、TSMCの年間設備投資は400億ドル前後に達する。このゲームでは装置の購入と改良が累計設備投資に数えられ、補助金の上限計算の基準になる。",
            unlock: .milestone("subsidy_received")
        ),
        GlossaryTerm(
            id: "term.cleanroom", term: "クリーンルーム", category: "製造",
            body: "空気中の微粒子を極限まで取り除いた作業空間。先端ファブの清浄度はISOクラス3〜5程度で、1立方メートルあたりの微粒子が外気より何桁も少ない状態に保たれる。このゲームでは増床でクリーンルームを広げ、装置を置ける枠を4つずつ増やす。",
            unlock: .milestone("first_expansion")
        ),
        GlossaryTerm(
            id: "term.euv", term: "EUV", category: "製造",
            body: "Extreme Ultraviolet（極端紫外線）の略で、波長13.5nmの光を使う露光技術。ArFの193nmより一桁以上短い波長で、多重露光に頼らず微細なパターンを描ける。装置は1台200億円を超えてASMLだけが供給しており、このゲームでは7nm以降で露光のパス数を大きく減らす装置として登場する。",
            unlock: .milestone("wph_17")
        ),
        GlossaryTerm(
            id: "term.ramp", term: "ランプ", category: "経営",
            body: "新しいプロセスや工場の生産量と歩留まりを、量産水準まで引き上げていく立ち上げ期間のこと（ランプアップ）。この期間の速さが新世代の収益を左右するため、各社は立ち上げの速さを競っている。このゲームでも累計投入ウェハが増えるほど歩留まりが上がり、90%に届けば一流の量産ラインと言える。",
            unlock: .milestone("yield_90")
        ),
    ]

    private static let glossaryTermIndex: [String: GlossaryTerm] =
        Dictionary(uniqueKeysWithValues: glossaryTerms.map { ($0.id, $0) })

    static func glossaryTerm(id: String) -> GlossaryTerm? { glossaryTermIndex[id] }
}

// MARK: - 歩留まり異常（エクスカーション）

/// 歩留まり異常の原因カタログ（工程ごとに1件）
struct ExcursionSpec: Identifiable, Equatable {
    let id: String
    let causeProcess: ProcessType
    /// 原因の名前（解決時に開示）
    let causeName: String
    /// 兆候テキスト（発生直後から見える）
    let symptom: String
    /// 原因工程の欠陥寄与（1 − 工程歩留まり）への倍率
    let defectMultiplier: Double
    /// ヒント1段階目：欠陥の種類
    let stage1Hint: String
    /// ヒント2段階目：分布・偏り
    let stage2Hint: String
    /// ヒント3段階目：ほぼ特定できる示唆
    let stage3Hint: String
    /// 対策の名前（解決時に表示）
    let countermeasureTitle: String
    /// 学習ノート（解決時に読める）
    let learningNote: String
}

extension Catalog {
    /// 歩留まり異常の原因。並びは工程順
    static let excursions: [ExcursionSpec] = [
        ExcursionSpec(
            id: "exc.lithography", causeProcess: .lithography,
            causeName: "フォーカスドリフト（焦点位置のずれ）",
            symptom: "ウェハ外周部のショットだけ線幅が太く、中心部は正常。輪帯状（ドーナツ状）に歩留まりが落ちている",
            defectMultiplier: 3.0,
            stage1Hint: "欠陥は『パターンの寸法ずれ』が中心です。ゴミや傷のような物理的な欠陥は増えていません",
            stage2Hint: "線幅の太り方はウェハの外周ほど大きく、中心ほど小さい『同心円状』の分布です",
            stage3Hint: "外周でだけピントが合っていない状態です。ステージの高さ方向のずれが疑われます",
            countermeasureTitle: "ステージ高さの再校正とフォーカスマップの再測定",
            learningNote: "露光の焦点深度（ピントが合う範囲）は数十nmしかない。ウェハの反りやステージのわずかな傾きで、外周部だけピントが外れて線幅が太ることがある。そのため露光機はレベリングセンサーでウェハ全面の高さを測り、ショットごとに傾きと高さを補正しながら焼いている。この補正の基準がずれると、中心は正常なのに外周だけ輪帯状に歩留まりが落ちる、という特徴的な出方をする。"
        ),
        ExcursionSpec(
            id: "exc.deposition", causeProcess: .deposition,
            causeName: "シャワーヘッドの部分的な目詰まり",
            symptom: "膜厚を測るとウェハ中心部だけ薄い。同心円状に歩留まりが悪化している",
            defectMultiplier: 3.0,
            stage1Hint: "欠陥は『膜の性質・厚さの異常』が中心です。パターンの形の崩れは目立ちません",
            stage2Hint: "膜厚の薄い領域はウェハ中心に集まっています。ガスの流れの中心側に問題がありそうです",
            stage3Hint: "中心にガスを供給する経路の詰まりが疑われます",
            countermeasureTitle: "シャワーヘッドの洗浄・交換と流量の再校正",
            learningNote: "PECVDでは、無数の小さな穴が開いたシャワーヘッドから原料ガスをウェハへ均一に吹き付けて成膜する。穴の一部が反応生成物で詰まると、その部分だけガスが届かず膜が薄くなる。膜厚はトランジスタの特性や後工程のエッチング量に直結するため、中心だけ薄い・外周だけ厚いといった分布の崩れは、そのまま歩留まりの同心円状の悪化として現れる。"
        ),
        ExcursionSpec(
            id: "exc.etching", causeProcess: .etching,
            causeName: "チャンバー壁への反応生成物の付着（ポリマー堆積）",
            symptom: "エッチング後のパターン寸法が全体的に少しずつ細っている。処理枚数が増えるほど悪化する",
            defectMultiplier: 2.8,
            stage1Hint: "欠陥は『パターンの寸法ずれ』が中心で、時間とともに少しずつ進行しています",
            stage2Hint: "寸法のずれは全ロット共通で、特定の場所に偏っていません。装置内部の状態変化が疑われます",
            stage3Hint: "チャンバー内の壁に反応生成物が積もり、プラズマの状態が変わってきている可能性が高いです",
            countermeasureTitle: "チャンバーのウェット洗浄とシーズニング（慣らし運転）のやり直し",
            learningNote: "ドライエッチングでは、削られた膜や反応ガスから生じるポリマー状の生成物がチャンバー壁に少しずつ積もる。壁の状態が変わるとプラズマ中の成分バランスがずれ、エッチング速度や寸法がゆっくりドリフトしていく。そのため定期的にチャンバーを開けて洗浄し、洗浄後はダミーウェハを流すシーズニングで壁の状態を整えてから量産に戻すのが現場の基本動作になっている。"
        ),
        ExcursionSpec(
            id: "exc.implant", causeProcess: .implant,
            causeName: "ビーム電流のドリフト（注入量のずれ）",
            symptom: "外観の欠陥はほとんど増えていないのに、電気特性（しきい値電圧）だけがばらついて歩留まりが落ちている",
            defectMultiplier: 2.6,
            stage1Hint: "欠陥は『電気的な不良』が中心です。光学検査では異常がほとんど見つかりません",
            stage2Hint: "しきい値電圧が全体的に一方向へ寄っています。注入された不純物の量がずれている疑いがあります",
            stage3Hint: "ビーム電流の実測値と設定値に開きが出ています。電流計のドリフトが疑われます",
            countermeasureTitle: "ビーム電流の再校正と線量モニタの点検",
            learningNote: "イオン注入の量（ドーズ）は、ビーム電流×照射時間で決まる。電流を測る計器がドリフトすると、設定どおり流したつもりでも実際の注入量がずれ、トランジスタのしきい値電圧が全体的に動いてしまう。外観ではまったく分からず、電気特性の測定で初めて気づくタイプの異常で、だからこそ工程内モニタと定期的な校正が欠かせない。"
        ),
        ExcursionSpec(
            id: "exc.cmp", causeProcess: .cmp,
            causeName: "研磨パッドの目詰まり（グレージング）",
            symptom: "ウェハに同心円状の浅いスクラッチ（傷）と研磨残りが混在して増えている",
            defectMultiplier: 3.2,
            stage1Hint: "欠陥は『傷と研磨ムラ』が中心です。円弧状の傷が目立ちます",
            stage2Hint: "傷はウェハ全面に同心円状に出ています。回転する部材との接触が関係していそうです",
            stage3Hint: "研磨パッドの表面が目詰まりして、砥粒の効きが落ちている状態が疑われます",
            countermeasureTitle: "研磨パッドの交換とドレッサー（コンディショナー）の点検",
            learningNote: "CMPの研磨パッドは、使い込むと表面の微細な凹凸に研磨くずが詰まってツルツルになる（グレージング）。すると研磨レートが落ちるだけでなく、傷も増えて歩留まりが悪化する。これを防ぐため、ダイヤモンド粒子を植えたドレッサーでパッド表面を常に『起こし』続けるコンディショニングが研磨と並行して行われている。パッドとドレッサーはCMPの代表的な消耗品管理の対象。"
        ),
        ExcursionSpec(
            id: "exc.inspection", causeProcess: .inspection,
            causeName: "検査レシピのしきい値ずれ（感度ドリフト）",
            symptom: "不良判定されるダイが急に増えたが、再検査すると判定が変わるダイが多い。本当の欠陥は増えていなさそうだ",
            defectMultiplier: 2.5,
            stage1Hint: "『欠陥』とされたものの多くは、再測定で正常と判定されます。ものづくり側より『測る側』の異常が疑われます",
            stage2Hint: "判定のブレはスキャン方向に沿った縞状に出ています。センサー感度のばらつきが疑われます",
            stage3Hint: "基準ウェハでの感度が規格から外れています。検査側の校正ずれでほぼ間違いありません",
            countermeasureTitle: "標準ウェハによる感度校正とレシピしきい値の見直し",
            learningNote: "検査装置自体の感度がずれると、良品を不良と弾く『見かけの歩留まり低下』が起きる。本当に工程が悪いのか、測る側が悪いのかを切り分けるのが原因究明の第一歩で、標準試料（基準ウェハ）を測って装置が正しく測れているかを確認するのが測定系管理の基本。同じウェハを2回測って結果が変わらないか（再現性）の確認もよく行われる。"
        ),
        ExcursionSpec(
            id: "exc.packaging", causeProcess: .packaging,
            causeName: "ダイシングブレードの欠け",
            symptom: "チップの端に欠け（チッピング）が多発している。ダイの外周部から歩留まりが落ちている",
            defectMultiplier: 2.8,
            stage1Hint: "欠陥は『チップ端部の欠け』が中心です。前工程のパターン異常は見られません",
            stage2Hint: "欠けは切り分けライン（スクライブライン）に沿って出ています。切断の工程に問題がありそうです",
            stage3Hint: "ブレード（刃）の先端に欠けがあり、切断時にダイ端部を傷めている可能性が高いです",
            countermeasureTitle: "ダイシングブレードの交換と切り込み条件の再設定",
            learningNote: "ダイシングブレードはダイヤモンド砥粒を固めた消耗品で、摩耗や欠けが生じると切断時にチップ端部を欠けさせる（チッピング）。欠けた部分からクラックが広がると製品の信頼性にも影響するため、ブレードの寿命管理と、送り速度・切り込み量といった条件の管理が後工程の歩留まりを左右する。切断幅（カーフ）を狭くして取れるチップ数を増やすほど、この管理はシビアになる。"
        ),
    ]

    private static let excursionIndex: [String: ExcursionSpec] =
        Dictionary(uniqueKeysWithValues: excursions.map { ($0.id, $0) })

    static func excursion(id: String) -> ExcursionSpec? { excursionIndex[id] }

    static func excursion(for process: ProcessType) -> ExcursionSpec? {
        excursions.first { $0.causeProcess == process }
    }
}
