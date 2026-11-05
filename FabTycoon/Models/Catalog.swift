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
    /// 歩留まり寄与：この装置で処理したウェハの良品率係数（改良で欠陥寄与が減る）
    let yieldFactor: Double
    /// 検出率の基礎値（検査装置のみ意味を持つ）
    let detectionBase: Double
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
        yieldFactor: Double = 0.95,
        detectionBase: Double = 0,
        unlockNote: String? = nil
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
                       lithoClass: .duvDry, yieldFactor: 0.950),
        EquipmentModel(id: "L2", name: "ArF液浸露光機", process: .lithography,
                       priceYen: 5_000_000_000, nominalWPH: 170, supportedNodeIds: ["n14", "n7"],
                       lithoClass: .duvImm, yieldFactor: 0.955, unlockNote: "研究「液浸露光機」"),
        EquipmentModel(id: "L3", name: "EUV露光機", process: .lithography,
                       priceYen: 20_000_000_000, nominalWPH: 120, supportedNodeIds: ["n7", "n5", "n3", "n2"],
                       lithoClass: .euv, yieldFactor: 0.965, unlockNote: "研究「EUV露光」"),
        EquipmentModel(id: "L4", name: "High-NA EUV露光機", process: .lithography,
                       priceYen: 40_000_000_000, nominalWPH: 100, supportedNodeIds: ["n3", "n2"],
                       lithoClass: .highNA, yieldFactor: 0.970, unlockNote: "研究「High-NA EUV」"),
        // 成膜
        EquipmentModel(id: "D1", name: "PECVD装置", process: .deposition,
                       priceYen: 300_000_000, nominalWPH: 80, supportedNodeIds: ["n28", "n14"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "D2", name: "ALD/CVDクラスタ", process: .deposition,
                       priceYen: 1_200_000_000, nominalWPH: 100, supportedNodeIds: ["n14", "n7", "n5"],
                       yieldFactor: 0.960),
        EquipmentModel(id: "D3", name: "先端ALD装置", process: .deposition,
                       priceYen: 3_500_000_000, nominalWPH: 110, supportedNodeIds: ["n5", "n3", "n2"],
                       yieldFactor: 0.968),
        // エッチング
        EquipmentModel(id: "E1", name: "プラズマエッチャ", process: .etching,
                       priceYen: 300_000_000, nominalWPH: 60, supportedNodeIds: ["n28", "n14"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "E2", name: "高選択比エッチャ", process: .etching,
                       priceYen: 1_500_000_000, nominalWPH: 75, supportedNodeIds: ["n14", "n7", "n5"],
                       yieldFactor: 0.958),
        EquipmentModel(id: "E3", name: "原子層エッチャ（ALE）", process: .etching,
                       priceYen: 4_500_000_000, nominalWPH: 85, supportedNodeIds: ["n5", "n3", "n2"],
                       yieldFactor: 0.970),
        // イオン注入・熱処理
        EquipmentModel(id: "I1", name: "イオン注入機", process: .implant,
                       priceYen: 400_000_000, nominalWPH: 200, supportedNodeIds: ["n28", "n14", "n7"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "I2", name: "高エネルギー注入＋レーザーアニール", process: .implant,
                       priceYen: 1_500_000_000, nominalWPH: 220, supportedNodeIds: ["n7", "n5", "n3", "n2"],
                       yieldFactor: 0.955),
        // CMP
        EquipmentModel(id: "C1", name: "CMP装置", process: .cmp,
                       priceYen: 200_000_000, nominalWPH: 60, supportedNodeIds: ["n28", "n14", "n7"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "C2", name: "先端CMP装置", process: .cmp,
                       priceYen: 1_000_000_000, nominalWPH: 70, supportedNodeIds: ["n7", "n5", "n3", "n2"],
                       yieldFactor: 0.960),
        // 検査
        EquipmentModel(id: "Q1", name: "光学検査装置", process: .inspection,
                       priceYen: 250_000_000, nominalWPH: 50, supportedNodeIds: ["n28", "n14"],
                       yieldFactor: 0.950, detectionBase: 0.55),
        EquipmentModel(id: "Q2", name: "電子ビーム検査装置", process: .inspection,
                       priceYen: 1_500_000_000, nominalWPH: 45, supportedNodeIds: ["n14", "n7", "n5"],
                       yieldFactor: 0.955, detectionBase: 0.70, unlockNote: "研究「EB検査装置」"),
        EquipmentModel(id: "Q3", name: "AI欠陥分類検査装置", process: .inspection,
                       priceYen: 5_000_000_000, nominalWPH: 60, supportedNodeIds: ["n5", "n3", "n2"],
                       yieldFactor: 0.960, detectionBase: 0.82),
        // ダイシング/パッケージング
        EquipmentModel(id: "P1", name: "ブレードダイシング＋ワイヤボンド", process: .packaging,
                       priceYen: 150_000_000, nominalWPH: 30, supportedNodeIds: ["n28", "n14"],
                       yieldFactor: 0.950),
        EquipmentModel(id: "P2", name: "レーザーダイシング＋フリップチップ", process: .packaging,
                       priceYen: 800_000_000, nominalWPH: 35, supportedNodeIds: ["n14", "n7", "n5"],
                       yieldFactor: 0.958),
        EquipmentModel(id: "P3", name: "先端パッケージ（2.5D/チップレット）", process: .packaging,
                       priceYen: 3_000_000_000, nominalWPH: 40, supportedNodeIds: ["n5", "n3", "n2"],
                       yieldFactor: 0.962, unlockNote: "研究「先端パッケージ」"),
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
            return "目安：露光そのものは1枚あたり数十秒〜数分。ただし28nmでは約30回繰り返すため、露光だけで何時間も積み上がる"
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
