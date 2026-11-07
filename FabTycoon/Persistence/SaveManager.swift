import Foundation

/// Documents/fabtycoon-save.json へのセーブ/ロード。
/// 保存前に直前のセーブを .bak へ退避し、読めないセーブや未知の将来版は上書きで消さずに退避ファイルへ残す。
struct SaveManager {
    static let fileName = "fabtycoon-save.json"
    static let backupFileName = "fabtycoon-save.bak.json"
    static let unreadableFileName = "fabtycoon-save.unreadable.json"

    let fileURL: URL
    let backupURL: URL
    let unreadableURL: URL

    /// 直近の load() で読み込んだセーブの元の schemaVersion（読み込めなかった場合は nil）
    private(set) var lastLoadedOriginalVersion: Int?

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent(Self.fileName)
        backupURL = base.appendingPathComponent(Self.backupFileName)
        unreadableURL = base.appendingPathComponent(Self.unreadableFileName)
    }

    var hasSave: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func save(_ state: GameState) throws {
        if hasSave {
            // 直前のセーブを .bak へ退避する（失敗しても保存は続ける）
            try? copyReplacing(from: fileURL, to: backupURL)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    /// メイン → .bak の順に読む。どちらも読めなければ nil（メインは退避ファイルへコピーして残す）
    mutating func load() -> GameState? {
        lastLoadedOriginalVersion = nil
        if let state = loadOne(url: fileURL, isMain: true) {
            return state
        }
        if let state = loadOne(url: backupURL, isMain: false) {
            return state
        }
        if hasSave {
            try? copyReplacing(from: fileURL, to: unreadableURL)
        }
        return nil
    }

    func deleteSave() throws {
        // 退避ファイルは残す
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
    }

    // MARK: 内部

    private mutating func loadOne(url: URL, isMain: Bool) -> GameState? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any]
        else { return nil }

        // schemaVersion を欠いた旧セーブは v1 とみなす
        let originalVersion = object["schemaVersion"] as? Int ?? 1
        if originalVersion > GameState.currentSchemaVersion {
            // 未知の将来版：上書きで消さないよう退避してから諦める
            if isMain {
                try? copyReplacing(from: url, to: unreadableURL)
            }
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var state = try? decoder.decode(GameState.self, from: data) else { return nil }

        lastLoadedOriginalVersion = originalVersion
        if state.schemaVersion < GameState.currentSchemaVersion {
            // v1 → v2：新フィールドはデコーダのデフォルトで補完済み
            if originalVersion < 3 {
                // v2 → v3：補助金の時刻をゲーム内時間基準から実時刻へ移す
                Engine.migrateSubsidyTimeline(state: &state, now: Date())
            }
            state.schemaVersion = GameState.currentSchemaVersion
        }
        return state
    }

    private func copyReplacing(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }
}
