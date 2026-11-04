import Foundation

/// Documents/fabtycoon-save.json へのセーブ/ロード
struct SaveManager {
    static let fileName = "fabtycoon-save.json"

    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent(Self.fileName)
    }

    var hasSave: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func save(_ state: GameState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    /// セーブが無い・壊れている・スキーマ不一致の場合は nil
    func load() -> GameState? {
        guard hasSave, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(GameState.self, from: data),
              state.schemaVersion == GameState.currentSchemaVersion
        else { return nil }
        return state
    }

    func deleteSave() throws {
        guard hasSave else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
