// sw-launcher logic that does not touch the UI: the games, their folders, the settings (with the v1.0.1 migration),
// RomFS mods and run detection. Tests: scripts/test.sh (Tests/).
import Foundation

// MARK: - Games

enum GameKind: String, Codable, CaseIterable, Identifiable {
    case totk, botw
    var id: String { rawValue }
    var displayName: String { self == .totk ? "塞尔达传说 王国之泪" : "塞尔达传说 旷野之息" }
    var englishName: String { self == .totk ? "The Legend of Zelda: Tears of the Kingdom" : "The Legend of Zelda: Breath of the Wild" }
    var titleID: String { self == .totk ? "0100F2C0115B6000" : "01007EF00011E000" }
    var dataName: String { self == .totk ? "TOTK" : "BOTW" }
    var logName: String { self == .totk ? "totk" : "botw" }
    var binaryName: String { self == .totk ? "totk-native" : "botw-native" }
    /// Contents/MacOS/<executable> of the built game app.
    var executable: String { dataName }
    var defaultAppName: String { self == .totk ? "Tears of the Kingdom.app" : "Breath of the Wild.app" }
    var defaultWorkName: String { self == .totk ? "TOTK_build" : "BOTW_build" }
    /// build_app.py --title
    var buildTitleArg: String { rawValue }
    var experimental: Bool { self == .botw }
}

struct GamePaths {
    let support, log, profileSave, shaderDir, modsManifest, gameSlot: URL
    init(_ g: GameKind, home: URL) {
        support = home.appendingPathComponent("Library/Application Support/MacNativeGames/\(g.dataName)")
        log = home.appendingPathComponent("Library/Logs/MacNativeGames/\(g.logName).log")
        profileSave = support.appendingPathComponent("profile/save")
        shaderDir = support.appendingPathComponent("shader-cache/rt-totk-native-v4-unverified")
        modsManifest = support.appendingPathComponent("mods.tsv")
        gameSlot = support.appendingPathComponent("game-slot")
    }
}

// MARK: - Settings

struct GameSettings: Codable, Equatable {
    var game = "", update = "", save = "", mods = "", outputApp = "", workDir = ""
    var modOrder: [String] = []
    var modsEnabled: [String: Bool] = [:]

    static func defaults(_ g: GameKind, home: URL) -> GameSettings {
        var s = GameSettings()
        s.outputApp = home.appendingPathComponent("Games/MacNative/\(g.defaultAppName)").path
        s.workDir = home.appendingPathComponent("Games/MacNative/\(g.defaultWorkName)").path
        return s
    }
}

/// The settings file of v1.0.1 (MacNativeGames/TOTK/launcher.json): one game, flat.
private struct LegacySettings: Codable {
    var game: String?, update: String?, keys: String?, firmware: String?, save: String?, mods: String?
    var language: String?, projectDir: String?, outputApp: String?, workDir: String?
}

struct LauncherSettings: Codable {
    var selected: GameKind = .totk
    /// Keyed by GameKind.rawValue (a String key keeps the JSON a plain object).
    var games: [String: GameSettings] = [:]
    var keys = "", firmware = "", language = "zh-Hans", projectDir = ""
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    enum CodingKeys: String, CodingKey { case selected, games, keys, firmware, language, projectDir }

    static func fresh(home: URL) -> LauncherSettings {
        var s = LauncherSettings()
        s.projectDir = home.appendingPathComponent("Sites/MacNativeGames").path
        for g in GameKind.allCases { s.games[g.rawValue] = GameSettings.defaults(g, home: home) }
        return s
    }

    /// Reads `file`; when it does not exist yet, migrates the v1.0.1 `legacy` file (left untouched) into the TOTK entry.
    static func load(from file: URL, legacy: URL, home: URL) -> LauncherSettings {
        var s = fresh(home: home)
        if let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode(LauncherSettings.self, from: data) {
            s.selected = read.selected; s.keys = read.keys; s.firmware = read.firmware; s.language = read.language
            if !read.projectDir.isEmpty { s.projectDir = read.projectDir }
            for (k, v) in read.games { s.games[k] = v }
            return s
        }
        if let data = try? Data(contentsOf: legacy), let old = try? JSONDecoder().decode(LegacySettings.self, from: data) {
            var t = GameSettings.defaults(.totk, home: home)
            t.game = old.game ?? ""; t.update = old.update ?? ""; t.save = old.save ?? ""; t.mods = old.mods ?? ""
            if let v = old.outputApp, !v.isEmpty { t.outputApp = v }
            if let v = old.workDir, !v.isEmpty { t.workDir = v }
            s.games[GameKind.totk.rawValue] = t
            s.keys = old.keys ?? ""; s.firmware = old.firmware ?? ""; s.language = old.language ?? s.language
            if let v = old.projectDir, !v.isEmpty { s.projectDir = v }
        }
        return s
    }

    func write(to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: file, options: .atomic) }
    }

    /// The selected game's settings.
    var current: GameSettings {
        get { games[selected.rawValue] ?? GameSettings.defaults(selected, home: home) }
        set { games[selected.rawValue] = newValue }
    }
    var game: String { get { current.game } set { current.game = newValue } }
    var update: String { get { current.update } set { current.update = newValue } }
    var save: String { get { current.save } set { current.save = newValue } }
    var mods: String { get { current.mods } set { current.mods = newValue } }
    var outputApp: String { get { current.outputApp } set { current.outputApp = newValue } }
    var workDir: String { get { current.workDir } set { current.workDir = newValue } }
}
