// sw-launcher logic that does not touch the UI: the games of both backends (MacNativeGames, nxnative), their folders, the settings
// (with the v1.0.1 migration), RomFS mods, nxnative's env.txt, build progress and run detection. Tests: scripts/test.sh (Tests/).
import Foundation

// MARK: - Backends and games

/// Which engine builds and runs a game. `macnative`: MacNativeGames (Tears of the Kingdom, Breath of the Wild; patched by
/// totk-mac-fixes / sw-port). `nxnative`: seedds/nxnative (the games of its dm/games profiles).
enum Backend: String, Codable { case macnative, nxnative }

/// One nxnative game profile (dm/games/<title ID>/game.tsv).
struct NXGameInfo {
    let id: String                    // the base game's title ID, upper case
    let name: String
    let zh: String?
    let builds: [(version: String, display: String)]   // every build the profile registers: "v327680" = 1.2.1
    let package: String               // the build nxnative packs by default (the newest it was brought up on)
    let fps: Int                      // fps_target of the profile, 0 = the game has no 60 fps mode

    var packageDisplay: String { builds.first { $0.version == package }?.display ?? builds.last?.display ?? "?" }
    var displayVersions: [String] { builds.map(\.display) }
    /// The update number a file name tagged `[v<N>]` carries, as the profile writes it ("v327680").
    func build(forTag n: UInt64) -> String? { builds.first { $0.version == "v\(n)" }?.display }
}

/// The nxnative games the launcher knows: the built-in list, plus whatever a checked-out nxnative says (newer games and versions).
enum GameCatalog {
    static var nx: [String: NXGameInfo] = Dictionary(uniqueKeysWithValues: nxBuiltinCatalog.map { ($0.id, $0) })

    /// Adds / replaces entries from `games` (a dm/games folder); the Chinese names of the built-in list are kept.
    static func merge(gamesDir: URL) {
        for g in loadNXCatalog(gamesDir: gamesDir) {
            let zh = g.zh ?? nx[g.id]?.zh
            nx[g.id] = NXGameInfo(id: g.id, name: g.name, zh: zh, builds: g.builds, package: g.package, fps: g.fps)
        }
    }
}

/// Reads dm/games/*/game.tsv (key <TAB> value rows, `#` comments) as data; nothing in it is executed.
func loadNXCatalog(gamesDir: URL) -> [NXGameInfo] {
    let fm = FileManager.default
    let dirs = ((try? fm.contentsOfDirectory(at: gamesDir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    var out: [NXGameInfo] = []
    for d in dirs {
        guard let text = try? String(contentsOf: d.appendingPathComponent("game.tsv"), encoding: .utf8) else { continue }
        var rows: [(String, [String])] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            rows.append((c[0], Array(c.dropFirst())))
        }
        func one(_ k: String) -> String? { rows.first { $0.0 == k }?.1.first }
        let id = (one("title_id") ?? d.lastPathComponent).uppercased()
        guard id.count == 16, id.allSatisfy(\.isHexDigit) else { continue }
        let builds = rows.filter { $0.0 == "build" && $0.1.count >= 2 }.map { (version: $0.1[0], display: $0.1[1]) }
        out.append(NXGameInfo(id: id, name: one("name") ?? id, zh: nil, builds: builds,
                              package: one("package") ?? builds.last?.version ?? "", fps: Int(one("fps_target") ?? "") ?? 0))
    }
    return out
}

/// A game in the library. `totk` and `botw` are the MacNativeGames games (their ids are what the v1.1.0 settings file holds);
/// an nxnative game is `nx-<title ID>`.
struct GameKind: Hashable, Identifiable, Codable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    var id: String { rawValue }

    static let totk = GameKind(rawValue: "totk")
    static let botw = GameKind(rawValue: "botw")
    static func nx(_ titleID: String) -> GameKind { GameKind(rawValue: "nx-" + titleID.uppercased()) }
    static let macnativeGames: [GameKind] = [.totk, .botw]
    /// The nxnative games, by English name.
    static var nxGames: [GameKind] { GameCatalog.nx.values.sorted { $0.name.lowercased() < $1.name.lowercased() }.map { .nx($0.id) } }
    /// The whole library: the MacNativeGames games first, then the nxnative catalog.
    static var all: [GameKind] { macnativeGames + nxGames }

    var backend: Backend { rawValue.hasPrefix("nx-") ? .nxnative : .macnative }
    var nxInfo: NXGameInfo? { backend == .nxnative ? GameCatalog.nx[String(rawValue.dropFirst(3))] : nil }
    var isTOTK: Bool { self == .totk }

    var displayName: String {
        if let g = nxInfo { return g.zh ?? g.name }
        return self == .totk ? "塞尔达传说 王国之泪" : "塞尔达传说 旷野之息"
    }
    var englishName: String {
        if let g = nxInfo { return g.name }
        return self == .totk ? "The Legend of Zelda: Tears of the Kingdom" : "The Legend of Zelda: Breath of the Wild"
    }
    var titleID: String {
        if backend == .nxnative { return String(rawValue.dropFirst(3)) }
        return self == .totk ? "0100F2C0115B6000" : "01007EF00011E000"
    }
    /// The versions this backend can build, for display.
    var supportedVersions: [String] {
        if let g = nxInfo { return g.displayVersions }
        return self == .totk ? ["1.0.0", "1.1.2", "1.4.3"] : ["1.9.0"]
    }
    var dataName: String { self == .totk ? "TOTK" : "BOTW" }
    var logName: String { self == .totk ? "totk" : "botw" }
    var binaryName: String { self == .totk ? "totk-native" : "botw-native" }
    /// Contents/MacOS/<executable> of the built game app.
    var executable: String { backend == .nxnative ? "nxnative" : dataName }
    var defaultAppName: String {
        if let g = nxInfo { return safeFileName(g.name) + ".app" }
        return self == .totk ? "Tears of the Kingdom.app" : "Breath of the Wild.app"
    }
    var defaultWorkName: String { backend == .nxnative ? "nx/\(titleID)" : (self == .totk ? "TOTK_build" : "BOTW_build") }
    /// build_app.py --title
    var buildTitleArg: String { rawValue }
    var experimental: Bool { self == .botw }
}

/// A file name for an app: letters, digits and spaces only, so no ':' or '/' in the Finder name.
func safeFileName(_ s: String) -> String {
    let kept = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" ? Character($0) : " " }
    return String(kept).split(separator: " ").joined(separator: " ")
}

struct GamePaths {
    let support, log, profileSave, shaderDir, modsManifest, gameSlot, envFile: URL
    init(_ g: GameKind, home: URL) {
        if g.backend == .nxnative {   // dm/mac/launcher.c: ~/Library/Application Support/nxnative/<title ID>/{save,temp,env.txt}, the log in ~/Library/Logs/nxnative
            support = home.appendingPathComponent("Library/Application Support/nxnative/\(g.titleID)")
            log = home.appendingPathComponent("Library/Logs/nxnative/\(g.titleID).log")
            profileSave = support.appendingPathComponent("save")
            shaderDir = support
        } else {
            support = home.appendingPathComponent("Library/Application Support/MacNativeGames/\(g.dataName)")
            log = home.appendingPathComponent("Library/Logs/MacNativeGames/\(g.logName).log")
            profileSave = support.appendingPathComponent("profile/save")
            shaderDir = support.appendingPathComponent("shader-cache/rt-totk-native-v4-unverified")
        }
        modsManifest = support.appendingPathComponent("mods.tsv")
        gameSlot = support.appendingPathComponent("game-slot")
        envFile = support.appendingPathComponent("env.txt")
    }
}

// MARK: - Settings

struct GameSettings: Codable, Equatable {
    var game = "", update = "", dlc = "", save = "", mods = "", outputApp = "", workDir = ""
    var modOrder: [String] = []
    var modsEnabled: [String: Bool] = [:]
    /// nxnative only: the player's choices (variable -> value); a setting that is not here keeps the game's default.
    var nxEnv: [String: String] = [:]

    init() {}
    /// Tolerant: the settings file of an older version lacks the newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        game = str(.game); update = str(.update); dlc = str(.dlc); save = str(.save); mods = str(.mods)
        outputApp = str(.outputApp); workDir = str(.workDir)
        modOrder = (try? c.decodeIfPresent([String].self, forKey: .modOrder)) ?? []
        modsEnabled = (try? c.decodeIfPresent([String: Bool].self, forKey: .modsEnabled)) ?? [:]
        nxEnv = (try? c.decodeIfPresent([String: String].self, forKey: .nxEnv)) ?? [:]
    }

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
    /// Keyed by GameKind.rawValue (a String key keeps the JSON a plain object). Only games the player touched are in here.
    var games: [String: GameSettings] = [:]
    var keys = "", firmware = "", language = "zh-Hans", projectDir = "", nxDir = ""
    /// nxnative only: what to build (Mac app, iPhone/iPad Xcode project, or IPA), the Apple team ID and whether the Apple ID is a free one.
    var nxTarget: NXTarget = .macApp, teamID = "", freeAppleID = true
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    enum CodingKeys: String, CodingKey { case selected, games, keys, firmware, language, projectDir, nxDir, nxTarget, teamID, freeAppleID }

    init() {}
    /// Tolerant: a v1.1.0 file has no nxDir, and an unknown game id (a game removed from the catalog) is kept as it is.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selected = (try? c.decodeIfPresent(GameKind.self, forKey: .selected)) ?? .totk
        games = (try? c.decodeIfPresent([String: GameSettings].self, forKey: .games)) ?? [:]
        func str(_ k: CodingKeys, _ d: String) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? d }
        keys = str(.keys, ""); firmware = str(.firmware, ""); language = str(.language, "zh-Hans")
        projectDir = str(.projectDir, ""); nxDir = str(.nxDir, ""); teamID = str(.teamID, "")
        nxTarget = (try? c.decodeIfPresent(NXTarget.self, forKey: .nxTarget)) ?? .macApp
        freeAppleID = (try? c.decodeIfPresent(Bool.self, forKey: .freeAppleID)) ?? true
    }

    static func fresh(home: URL) -> LauncherSettings {
        var s = LauncherSettings()
        s.projectDir = home.appendingPathComponent("Sites/MacNativeGames").path
        s.nxDir = home.appendingPathComponent("nxnative").path
        for g in GameKind.macnativeGames { s.games[g.rawValue] = GameSettings.defaults(g, home: home) }
        return s
    }

    /// Reads `file`; when it does not exist yet, migrates the v1.0.1 `legacy` file (left untouched) into the TOTK entry.
    static func load(from file: URL, legacy: URL, home: URL) -> LauncherSettings {
        var s = fresh(home: home)
        if let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode(LauncherSettings.self, from: data) {
            s.selected = read.selected; s.keys = read.keys; s.firmware = read.firmware; s.language = read.language
            if !read.projectDir.isEmpty { s.projectDir = read.projectDir }
            if !read.nxDir.isEmpty { s.nxDir = read.nxDir }
            s.nxTarget = read.nxTarget; s.teamID = read.teamID; s.freeAppleID = read.freeAppleID
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

    /// The settings of `g`, the defaults while the player has not touched that game.
    func settings(for g: GameKind) -> GameSettings { games[g.rawValue] ?? GameSettings.defaults(g, home: home) }

    /// The selected game's settings.
    var current: GameSettings {
        get { settings(for: selected) }
        set { games[selected.rawValue] = newValue }
    }
    var game: String { get { current.game } set { current.game = newValue } }
    var update: String { get { current.update } set { current.update = newValue } }
    var dlc: String { get { current.dlc } set { current.dlc = newValue } }
    var save: String { get { current.save } set { current.save = newValue } }
    var mods: String { get { current.mods } set { current.mods = newValue } }
    var outputApp: String { get { current.outputApp } set { current.outputApp = newValue } }
    var workDir: String { get { current.workDir } set { current.workDir = newValue } }
}

// MARK: - RomFS mods

/// One mod: `root` is its romfs/ folder, `files` the RomFS-relative paths inside it ("/"-separated, sorted).
struct ModInfo: Equatable {
    let name: String
    let root: URL
    let files: [String]
}

/// Mods in `<dir>/<mod>/romfs/...` and in Ryujinx's `<dir>/contents/<title ID>/<mod>/romfs/...` (only this game's ID).
func scanMods(dir: URL, titleID: String) -> [ModInfo] {
    let fm = FileManager.default
    func folders(_ u: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func files(in romfs: URL) -> [String] {
        guard let e = fm.enumerator(at: romfs, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        let base = romfs.standardizedFileURL.path + "/"
        var out: [String] = []
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let p = u.standardizedFileURL.path
            if p.hasPrefix(base) { out.append(String(p.dropFirst(base.count))) }
        }
        return out.sorted()
    }
    var mods: [ModInfo] = []
    func add(_ modDir: URL) {
        let romfs = modDir.appendingPathComponent("romfs")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: romfs.path, isDirectory: &isDir), isDir.boolValue else { return }
        var name = modDir.lastPathComponent
        if mods.contains(where: { $0.name == name }) { name += "（contents）" }
        mods.append(ModInfo(name: name, root: romfs, files: files(in: romfs)))
    }
    for d in folders(dir) where d.lastPathComponent != "contents" { add(d) }
    for t in folders(dir.appendingPathComponent("contents")) where t.lastPathComponent.uppercased() == titleID.uppercased() {
        for d in folders(t) { add(d) }
    }
    return mods
}

/// The mods in load order: the names in `order` first (in that order), then the others by name.
func orderedMods(_ mods: [ModInfo], order: [String]) -> [ModInfo] {
    let listed = order.compactMap { n in mods.first { $0.name == n } }
    return listed + mods.filter { !order.contains($0.name) }.sorted { $0.name < $1.name }
}

struct ModResolution {
    /// RomFS path -> the mod that supplies it and the file.
    var winners: [String: (mod: String, file: URL)] = [:]
    /// RomFS path -> every enabled mod that has it, in load order (only paths with two or more).
    var conflicts: [String: [String]] = [:]
}

/// Enabled mods (missing from `enabled` = on) in load order; a later mod wins a path.
func resolveMods(_ mods: [ModInfo], order: [String], enabled: [String: Bool]) -> ModResolution {
    var r = ModResolution(), owners: [String: [String]] = [:]
    for m in orderedMods(mods, order: order) where enabled[m.name] ?? true {
        for f in m.files {
            r.winners[f] = (m.name, m.root.appendingPathComponent(f))
            owners[f, default: []].append(m.name)
        }
    }
    r.conflicts = owners.filter { $0.value.count > 1 }
    return r
}

/// Writes the runtime's manifest (`<RomFS path>\t<host path>\t<size>`, runtime/romfs_mods.h), sorted by path; removes it
/// when no file is left. Returns the RomFS paths skipped because the runtime would reject them (romfsPathOK) or a host path
/// contains a tab or a line break.
@discardableResult
func writeManifest(_ r: ModResolution, to file: URL) throws -> [String] {
    var lines: [String] = [], skipped: [String] = []
    for path in r.winners.keys.sorted() {
        let host = r.winners[path]!.file.path
        if !romfsPathOK(path) || host.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) { skipped.append(path); continue }
        let size = ((try? FileManager.default.attributesOfItem(atPath: host))?[.size] as? NSNumber)?.uint64Value ?? 0
        lines.append("\(path)\t\(host)\t\(size)\n")
    }
    let fm = FileManager.default
    if lines.isEmpty {
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        return skipped
    }
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try lines.joined().data(using: .utf8)!.write(to: file, options: .atomic)
    return skipped
}

/// A RomFS path the runtime accepts (runtime/romfs_mods.c path_inside): relative, "/"-separated, no empty, "." or ".."
/// component, no backslash, no tab or line break.
func romfsPathOK(_ p: String) -> Bool {
    if p.isEmpty || p.hasPrefix("/") || p.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" || $0 == "\r" }) { return false }
    return p.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

/// RomFS paths the runtime skipped as new files (the game has no such file), from the game's log.
func parseModWarnings(log: String) -> [String] {
    let prefix = "[totk] mod: ", suffix = " not in the game (new files are not supported)"
    return log.split(separator: "\n").compactMap { line in
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
        return String(line.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

// MARK: - Which game is running

enum RunState { case idle, running(pid: Int32), otherGameRunning(GameKind) }

/// Start time (seconds) of a live process, 0 if it is gone or a zombie; with the pid it names one process exactly.
func processStart(_ pid: Int32) -> UInt64 {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB) else { return 0 }
    return info.pbi_start_tvsec
}

/// The game holding `slot` (runtime/game_slot.c: an exclusive lock on <slot>/lock, the player's game named in <slot>/holder),
/// as app/launcher.m's running_game reads it. A test run by someone else (owner other than "user") does not count.
func slotHolder(_ slot: URL) -> Int32? {
    let fd = open(slot.appendingPathComponent("lock").path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    let held = flock(fd, LOCK_EX | LOCK_NB) != 0
    close(fd)
    guard held, let text = try? String(contentsOf: slot.appendingPathComponent("holder"), encoding: .utf8) else { return nil }
    var kv: [String: String] = [:]
    for line in text.split(separator: "\n") {
        if let eq = line.firstIndex(of: "="), kv[String(line[..<eq])] == nil { kv[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
    }
    guard kv["owner"] == "user", let pid = Int32(kv["game_pid"] ?? ""), let start = UInt64(kv["game_start"] ?? ""),
          start != 0, processStart(pid) == start else { return nil }
    return pid
}

/// The MacNativeGames games only (their slot files).
func runState(for game: GameKind, home: URL) -> RunState {
    if let pid = slotHolder(GamePaths(game, home: home).gameSlot) { return .running(pid: pid) }
    for other in GameKind.macnativeGames where other != game {
        if slotHolder(GamePaths(other, home: home).gameSlot) != nil { return .otherGameRunning(other) }
    }
    return .idle
}

/// Both backends: a MacNativeGames game by its slot, an nxnative game by its app's host process (the apps the player has set up).
/// One game at a time, whichever backend.
func runState(for game: GameKind, settings: LauncherSettings, home: URL) -> RunState {
    var apps: [String: GameKind] = [:]   // host path -> game
    for (key, gs) in settings.games {
        let g = GameKind(rawValue: key)
        if g.backend == .nxnative, !gs.outputApp.isEmpty { apps[nxHostPath(app: gs.outputApp)] = g }
    }
    if game.backend == .nxnative { apps[nxHostPath(app: settings.settings(for: game).outputApp)] = game }
    let alive = runningExecutables(Array(apps.keys))
    if game.backend == .macnative, let pid = slotHolder(GamePaths(game, home: home).gameSlot) { return .running(pid: pid) }
    if game.backend == .nxnative, let path = apps.first(where: { $0.value == game })?.key, let pid = alive[path] { return .running(pid: pid) }
    for other in GameKind.macnativeGames where other != game {
        if slotHolder(GamePaths(other, home: home).gameSlot) != nil { return .otherGameRunning(other) }
    }
    for (path, g) in apps where g != game && alive[path] != nil { return .otherGameRunning(g) }
    return .idle
}

// MARK: - Build tool installation

/// Single-quoted for /bin/sh.
func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// A fresh build tool: the pinned upstream commit with every patch applied in order (stops if `project` is not empty).
func installCommand(project: String, baseCommit: String, patches: [String]) -> String {
    let d = shQuote(project)
    return "set -e; if [ -e \(d) ] && [ -n \"$(ls -A \(d) 2>/dev/null)\" ]; then echo \"目录已存在且不是空的：\"\(d); exit 1; fi; " +
        "mkdir -p \(d) && cd \(d) && git init -q && git remote add origin https://github.com/ly05010419/MacNativeGames && " +
        "git fetch --depth 1 origin \(baseCommit) && git checkout -q FETCH_HEAD" +
        patches.map { " && git apply -p1 \(shQuote($0))" }.joined()
}

/// Applies, in order, each patch that is not applied yet (an older install that has only the first one gets the rest).
func patchesCommand(project: String, patches: [String]) -> String {
    // Chained with && rather than set -e: set -e is ignored inside the left side of upgradeCommand's ||.
    "cd \(shQuote(project))" + patches.map { p in
        " && { git apply -p1 --reverse --check \(shQuote(p)) 2>/dev/null || git apply -p1 \(shQuote(p)); }"
    }.joined()
}

/// Exit status 0 when every patch is applied.
func patchCheckCommand(project: String, patches: [String]) -> String {
    "cd \(shQuote(project))" + patches.map { " && git apply -p1 --reverse --check \(shQuote($0)) 2>/dev/null" }.joined()
}

/// Printed by upgradeCommand when it had to install a fresh build tool; the launcher then switches to that folder.
let freshToolMarker = "SW_FRESH_BUILD_TOOL="

/// Applies the missing patches; when the existing build tool cannot take them (a v1.0.0 install, or a tree with its own
/// changes), installs a fresh build tool into `fresh` instead and prints freshToolMarker + its path. Never resets `project`.
func upgradeCommand(project: String, fresh: String, baseCommit: String, patches: [String]) -> String {
    "( \(patchesCommand(project: project, patches: patches)) ) || ( echo '现有的构建工具无法打上补丁，改为安装一份新的：'\(shQuote(fresh)); " +
        "\(installCommand(project: fresh, baseCommit: baseCommit, patches: patches)) && echo \(freshToolMarker)\(shQuote(fresh)) )"
}

// MARK: - Start-up log

/// The file's inode, to tell a new log (the game rotates it on start) from the previous run's.
func fileIdentity(_ url: URL) -> UInt64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64
}

/// The log's text once it is a different file than `before` (nil while it is still the previous run's log).
func freshLog(_ url: URL, notSameAs before: UInt64?) -> String? {
    guard let id = fileIdentity(url), id != before, let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    return String(decoding: h.readData(ofLength: 400_000), as: UTF8.self)
}

/// A start that failed for a reason retrying will not fix: the message to show, or nil (no failure, or the address-space
/// reservation failure that the launcher retries).
func launchFailure(log: String) -> String? {
    guard let line = log.split(separator: "\n").first(where: { $0.contains("FAIL: ") }),
          let r = line.range(of: "FAIL: ") else { return nil }   // runtime_fail prints "[totk] FAIL: <message>"
    let message = line[r.upperBound...]
    if message.hasPrefix("reserve") { return nil }
    if message.contains("RomFS mod") { return "Mod 文件在启动器列出之后被改动或删除了。请再点一次“启动”，启动器会重新生成 Mods 清单。" }
    return "游戏启动失败：" + message
}

/// Whether a built game app reads the mods manifest (apps built before sw-launcher 1.1.0 ignore it).
func appSupportsMods(info: [String: Any]) -> Bool { info["SWModsManifest"] as? Bool == true }

// MARK: - nxnative: player settings and env.txt

/// One player-facing setting of an nxnative game: the environment variable the host reads (dm/games/settings.tsv).
struct NXSetting: Identifiable {
    enum Kind {
        case choice([(value: String, label: String)])
        case toggle(on: String, off: String)
        case range(lo: Double, hi: Double, step: Double)
        case count(max: Int)   // a whole number, 0 = the host's own choice
    }
    let variable: String, label: String, note: String, section: String
    let kind: Kind
    /// Shown only for a game whose profile has a 60 fps mode.
    var needsFPSMode = false
    var id: String { variable }
}

let nxSettingTable: [NXSetting] = [
    NXSetting(variable: "DM_FPS_TARGET", label: "帧率", note: "", section: "游戏",
              kind: .choice([("30", "30 fps"), ("60", "60 fps")]), needsFPSMode: true),
    NXSetting(variable: "DM_RENDER_SCALE", label: "渲染比例", note: "只有提供该选项的游戏才会生效。", section: "游戏", kind: .range(lo: 0.5, hi: 1.0, step: 0.05)),
    NXSetting(variable: "DM_OPMODE", label: "主机模式", note: "", section: "游戏", kind: .choice([("1", "主机（Docked）"), ("0", "掌机（Handheld）")])),
    NXSetting(variable: "DM_PRESENT_UPSCALE", label: "画面放大", note: "MetalFX 更耗 GPU，窗口很大或 4K 屏幕上更有用。", section: "游戏",
              kind: .choice([("off", "标准"), ("metalfx", "MetalFX")])),
    NXSetting(variable: "DM_SHOW_FPS", label: "显示帧率", note: "", section: "游戏", kind: .toggle(on: "1", off: "0")),
    NXSetting(variable: "DM_PSO_PREPARE_THREADS", label: "着色器预热线程数", note: "首帧前并行编译着色器和渲染管线的线程数。自动 = 与 CPU 核心数相同。", section: "性能", kind: .count(max: 32)),
    NXSetting(variable: "DM_PSO_PREBUILD", label: "管线预建", note: "第一次启动会多等几分钟，只此一次。", section: "性能", kind: .toggle(on: "1", off: "0")),
    NXSetting(variable: "DM_PSO_MTL4", label: "Metal 4 管线", note: "保留管线档案，占用更多内存。", section: "性能", kind: .toggle(on: "1", off: "0")),
    NXSetting(variable: "DM_NVN_ENC_THREAD", label: "独立编码线程", note: "在 Mac 上默认关闭：平均帧时间下降，但最慢的帧会更慢。", section: "性能", kind: .toggle(on: "1", off: "0")),
    NXSetting(variable: "DM_PRESENT_SNAP", label: "帧缓冲", note: "最多多一帧显示延迟。", section: "性能", kind: .toggle(on: "1", off: "0")),
    NXSetting(variable: "DM_FPS_HOLD", label: "帧落后时保持", note: "", section: "性能", kind: .toggle(on: "on", off: "off"), needsFPSMode: true),
    NXSetting(variable: "DM_METAL_HUD", label: "Metal 性能面板", note: "", section: "性能", kind: .toggle(on: "1", off: "0")),
    NXSetting(variable: "DM_RUMBLE", label: "手柄震动", note: "", section: "手柄", kind: .toggle(on: "1", off: "0")),
    NXSetting(variable: "DM_RUMBLE_GAIN", label: "震动强度", note: "", section: "手柄", kind: .range(lo: 0, hi: 3, step: 0.1)),
]

/// The settings that apply to `game` (those that need a 60 fps mode only when its profile has one).
func nxSettings(for game: GameKind) -> [NXSetting] {
    let fps = game.nxInfo?.fps ?? 0
    return nxSettingTable.filter { !$0.needsFPSMode || fps > 0 }
}

/// `value` as the host wants it for `setting`, or nil when it is not an allowed value (nothing is written then).
func nxNormalized(_ value: String, for setting: NXSetting) -> String? {
    switch setting.kind {
    case .choice(let options): return options.contains { $0.value == value } ? value : nil
    case .toggle(let on, let off): return value == on || value == off ? value : nil
    case .range(let lo, let hi, _):
        guard let d = Double(value), d.isFinite else { return nil }
        let c = min(max(d, lo), hi)
        return c == c.rounded() ? String(Int(c)) : String(format: "%.2f", c).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    case .count(let m):
        guard let n = Int(value), n > 0 else { return nil }   // 0 = automatic: not written
        return String(min(n, m))
    }
}

/// The language codes of the NACP SupportedLanguageFlag bits (dm/tools/nacp.py LANGUAGES), in bit order.
let nacpLanguageCodes = ["en-US", "en-GB", "ja", "fr", "de", "es-419", "es", "it", "nl", "fr-CA", "pt", "ru", "ko", "zh-Hant", "zh-Hans", "pt-BR"]

/// The languages a control.nacp lists (the u32 at 0x302C), nil when the file is missing or too short.
func nacpSupportedLanguages(_ url: URL) -> [String]? {
    guard let d = try? Data(contentsOf: url), d.count >= 0x3030 else { return nil }
    let flags = (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[0x302C + $1]) << (8 * UInt32($1)) }
    return nacpLanguageCodes.enumerated().filter { flags >> UInt32($0.offset) & 1 == 1 }.map(\.element)
}

/// <work>/<title ID>_build/extract/<version>/control.nacp of the newest extraction, nil before the first build.
func findControlNacp(workDir: URL, titleID: String) -> URL? {
    let ex = workDir.appendingPathComponent("\(titleID)_build/extract")
    let dirs = ((try? FileManager.default.contentsOfDirectory(at: ex, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                  ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    return dirs.map { $0.appendingPathComponent("control.nacp") }.first { FileManager.default.fileExists(atPath: $0.path) }
}

/// DM_ROMFS_OVERLAY (dm/host/hle_fs.c rom_overlay_path): roots separated by ':', the first root that has a file wins, then the game's own RomFS.
/// The launcher's mods are "later wins", so the enabled mods go in reverse. A mod whose path holds ':' or a line break cannot be listed.
func overlayRoots(_ mods: [ModInfo], order: [String], enabled: [String: Bool]) -> (value: String, skipped: [String]) {
    var roots: [String] = [], skipped: [String] = []
    for m in orderedMods(mods, order: order).reversed() where (enabled[m.name] ?? true) && !m.files.isEmpty {
        let p = m.root.path
        if p.contains(":") || p.contains("\n") || p.contains("\r") { skipped.append(m.name) } else { roots.append(p) }
    }
    return (roots.joined(separator: ":"), skipped)
}

/// The KEY=VALUE lines the launcher manages for an nxnative game. `supportedLanguages` (from control.nacp, nil = unknown) keeps a
/// language the game lacks out of the file.
func nxManagedEnv(game: GameKind, settings gs: GameSettings, language: String, supportedLanguages: [String]?, overlay: String) -> [(String, String)] {
    var out: [(String, String)] = []
    if supportedLanguages == nil || supportedLanguages!.contains(language) { out.append(("DM_LANG", language)) }
    for s in nxSettings(for: game) {
        if let raw = gs.nxEnv[s.variable], let v = nxNormalized(raw, for: s) { out.append((s.variable, v)) }
    }
    if !overlay.isEmpty { out.append(("DM_ROMFS_OVERLAY", overlay)) }
    return out
}

let envBlockBegin = "# >>> sw-launcher (managed by the launcher; lines outside this block are yours and win)"
let envBlockEnd = "# <<< sw-launcher"

/// `existing` with the launcher's block replaced by `managed` (the block is dropped when there is nothing to write). The block goes last:
/// the host takes the first line of a variable, so a line the player wrote by hand beats the launcher's.
func mergeManagedEnv(existing: String, managed: [(String, String)]) -> String {
    var lines: [Substring] = [], inside = false
    for l in existing.split(separator: "\n", omittingEmptySubsequences: false) {
        if l == envBlockBegin[...] { inside = true; continue }
        if inside { if l == envBlockEnd[...] { inside = false }; continue }
        lines.append(l)
    }
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    var text = lines.joined(separator: "\n")
    let clean = managed.filter { !$0.1.contains("\n") && !$0.1.contains("\r") && !$0.0.isEmpty }
    if !clean.isEmpty {
        text += (text.isEmpty ? "" : "\n") + ([envBlockBegin] + clean.map { "\($0.0)=\($0.1)" } + [envBlockEnd]).joined(separator: "\n")
    }
    return text.isEmpty ? "" : text + "\n"
}

/// Writes (or trims) `file` so that its launcher block holds `managed`; a file that would be empty is removed.
func writeManagedEnv(_ managed: [(String, String)], to file: URL) throws {
    let fm = FileManager.default
    let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let text = mergeManagedEnv(existing: existing, managed: managed)
    if text.isEmpty { if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }; return }
    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
}

// MARK: - nxnative: files, names, versions

let nxGameExtensions: Set<String> = ["xci", "nsp", "xcz", "nsz"]

/// The 16-digit title IDs in a file name, upper case.
func titleIDs(inFileName name: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: #"(?<![0-9A-Fa-f])0[0-9A-Fa-f]{15}(?![0-9A-Fa-f])"#) else { return [] }
    return re.matches(in: name, range: NSRange(name.startIndex..., in: name)).compactMap { Range($0.range, in: name).map { String(name[$0]).uppercased() } }
}

/// The update number of a file name tagged `[v<N>]`, which nxnative needs to recognize an update.
func versionTag(inFileName name: String) -> UInt64? {
    guard let re = try? NSRegularExpression(pattern: #"\[v(\d+)\]"#, options: .caseInsensitive),
          let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), let r = Range(m.range(at: 1), in: name) else { return nil }
    return UInt64(name[r])
}

/// A game file the player dropped: which game it is for (by a title ID in its name) and whether it is that game's update (ID + 0x800).
/// `current` keeps the player's selection when the file is for the same title (TOTK and BOTW exist in both backends).
func gameForFileName(_ name: String, current: GameKind) -> (game: GameKind, isUpdate: Bool)? {
    for id in titleIDs(inFileName: name) {
        var base = id, isUpdate = false
        if GameCatalog.nx[id] == nil, let v = UInt64(id, radix: 16), v >= 0x800 {
            let b = String(format: "%016llX", v - 0x800)
            if GameCatalog.nx[b] != nil { base = b; isUpdate = true }
        }
        guard GameCatalog.nx[base] != nil else { continue }
        if current.titleID == base { return (current, isUpdate) }
        if base == GameKind.totk.titleID { return (.totk, isUpdate) }
        if base == GameKind.botw.titleID { return (.botw, isUpdate) }
        return (.nx(base), isUpdate)
    }
    return nil
}

/// Fills `stage` with symlinks to `files` (nxnative wants one game per folder: base, updates and DLC together). Only symlinks are ever
/// removed from `stage`; real files and the <title ID>_build folder stay.
func stageGameFiles(stage: URL, files: [URL]) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: stage, withIntermediateDirectories: true)
    for u in (try? fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
        guard (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
        let target = files.first { $0.lastPathComponent == u.lastPathComponent }
        if target == nil || (try? fm.destinationOfSymbolicLink(atPath: u.path)) != target!.path { try fm.removeItem(at: u) }
    }
    for f in files {
        let link = stage.appendingPathComponent(f.lastPathComponent)
        if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil { continue }   // already linked, or a real file of that name
        try fm.createSymbolicLink(at: link, withDestinationURL: f)
    }
}

/// The base / update / DLC files of a stage, from the three settings.
func stageInputs(game: String, update: String, dlcFolder: String) -> [URL] {
    func url(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
    var files: [URL] = []
    if !game.isEmpty { files.append(url(game)) }
    if !update.isEmpty { files.append(url(update)) }
    if !dlcFolder.isEmpty {
        let d = url(dlcFolder)
        let found = ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
            .filter { nxGameExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        files += found
    }
    return files
}

// MARK: - nxnative: commands

/// PATH for the nxnative tools: the launcher's Python environment first, then Homebrew and .NET.
func nxToolPath(venv: String) -> String {
    [venv + "/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/share/dotnet", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
}

let nxRepoURL = "https://github.com/seedds/nxnative.git"

/// Shallow clone (stops if `dir` is not empty).
func nxCloneCommand(dir: String) -> String {
    let d = shQuote(dir)
    return "set -e; if [ -e \(d) ] && [ -n \"$(ls -A \(d) 2>/dev/null)\" ]; then echo \"目录已存在且不是空的：\"\(d); exit 1; fi; git clone --depth 1 \(nxRepoURL) \(d)"
}

func nxUpdateCommand(dir: String) -> String { "git -C \(shQuote(dir)) pull --ff-only" }

/// A Python environment of its own for nxnative's build scripts (no change to the system Python).
func nxVenvCommand(venv: String, python: String = "/opt/homebrew/bin/python3.14") -> String {
    let v = shQuote(venv)
    return "set -e; \(shQuote(python)) -m venv \(v) && \(v)/bin/pip install --upgrade pip && \(v)/bin/pip install capstone fonttools nsz && " +
        "PYLZ4_USE_SYSTEM_LZ4=0 \(v)/bin/pip install --no-binary lz4 lz4 && \(v)/bin/python -c \"import lz4.block, capstone, fontTools; print('Python OK')\""
}

func nxVenvCheckCommand(venv: String) -> String {
    "\(shQuote(venv + "/bin/python")) -c \"import lz4.block, capstone, fontTools, importlib.util as u; assert u.find_spec('nsz')\" >/dev/null 2>&1"
}

/// What an nxnative build produces.
enum NXTarget: String, Codable, CaseIterable {
    case macApp, xcode, ipa
    var label: String {
        switch self {
        case .macApp: return "Mac App"
        case .xcode: return "iPad / iPhone（Xcode 工程，用自己的 Apple ID 签名）"
        case .ipa: return "iPad / iPhone（IPA，用 Sideloadly / AltStore 签名安装）"
        }
    }
    var isIOS: Bool { self != .macApp }
}

/// `scripts/build_ipa_from_nsp.py <stage> -k <keys> --platform mac-app -o <app> --progress json`, run in the nxnative folder.
/// For iOS: `--prepare-xcode` (an Xcode project in a workspace next to the stage folder) or `--platform ios -o <ipa>`.
/// `freeAppleID` drops the Increased Memory Limit entitlement (`DM_ENTITLEMENTS=` empty), which a free account cannot provision.
/// No language is passed: the build stops for a language the game lacks; the language is set at launch (DM_LANG in env.txt).
func nxBuildCommand(venv: String, stage: String, keys: String, app: String, target: NXTarget = .macApp, teamID: String = "", workspace: String = "", freeAppleID: Bool = true) -> String {
    let base = "\(shQuote(venv + "/bin/python")) scripts/build_ipa_from_nsp.py \(shQuote(stage)) -k \(shQuote(keys))"
    let team = teamID.isEmpty ? "" : " --team-id \(shQuote(teamID))"
    switch target {
    case .macApp:
        return base + " --platform mac-app -o \(shQuote(app)) --progress json"
    case .xcode:
        let env = freeAppleID ? "DM_ENTITLEMENTS= " : ""
        let ws = workspace.isEmpty ? "" : " --xcode-workspace \(shQuote(workspace))"
        return env + base + " --prepare-xcode\(ws)\(team) --progress json"
    case .ipa:
        return base + " --platform ios -o \(shQuote(app))\(team) --progress json"
    }
}

/// The IPA next to the Mac app's path: `~/Games/X/Game.app` -> `~/Games/X/Game.ipa`.
func nxIPAPath(app: String) -> String {
    (app as NSString).deletingPathExtension + ".ipa"
}

/// The Xcode workspace that collects the prepared games, next to the build folder.
func nxWorkspacePath(stage: String) -> String {
    ((stage as NSString).deletingLastPathComponent as NSString).appendingPathComponent("sw-launcher.xcworkspace")
}

let nxXcodeNextSteps = "Xcode 工程已生成并打开。接下来：1) Xcode > Settings > Apple Accounts 登录你的 Apple ID；2) 选 DmIOS 目标的 Signing & Capabilities，勾选自动签名并选你的 Personal Team，Bundle ID 冲突就换一个；3) 用线连接 iPad，开启开发者模式并信任；4) 选游戏的 scheme 点 Run。免费 Apple ID 的签名 7 天后过期，重新 Run 一次即可。"

// MARK: - nxnative: build progress

/// What a line of `--progress json` says.
enum NXBuildEvent: Equatable {
    case stage(k: Int, n: Int, name: String)
    case progress(k: Int, name: String, fraction: Double?)
    case message(String)
}

func parseNXBuildLine(_ line: String) -> NXBuildEvent? {
    guard line.hasPrefix("{"), let d = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let ev = o["ev"] as? String else { return nil }
    switch ev {
    case "stage": return .stage(k: o["k"] as? Int ?? 0, n: o["n"] as? Int ?? 0, name: o["name"] as? String ?? "")
    case "progress": return .progress(k: o["k"] as? Int ?? 0, name: o["name"] as? String ?? "", fraction: o["frac"] as? Double)
    case "say": return (o["msg"] as? String).map { .message($0) }
    default: return nil
    }
}

/// Overall progress 0...1 from the stage number and the fraction inside it.
func nxOverallProgress(k: Int, n: Int, fraction: Double?) -> Double {
    guard n > 0, k > 0 else { return 0 }
    return min((Double(k - 1) + (fraction ?? 0)) / Double(n), 0.99)
}

func nxStageLabel(_ name: String) -> String {
    let table: [(String, String)] = [
        ("decompress NSZ", "解压 NSZ / XCZ"), ("build ID lookup", "识别游戏版本"), ("build nx_extract", "构建解包工具"), ("extract DLC", "解包 DLC"),
        ("extract", "解包游戏文件"), ("survey", "分析游戏（未收录）"), ("rewrite", "改写游戏代码"), ("heap check", "检查内存布局"),
        ("shader split", "拆分着色器"), ("Mac shaders", "编译 Mac 着色器"), ("Vulkan shaders", "编译 Vulkan 着色器"), ("GL shaders", "编译 OpenGL 着色器"),
        ("GLSLC capture", "采集着色器"), ("UE shader decode", "解码着色器"), ("shader capture", "采集着色器"), ("Mac host", "构建 Mac 主程序"),
        ("Pipeline prebuild", "预建渲染管线"), ("Mac app", "生成 App"),
    ]
    return table.first { name.hasPrefix($0.0) || name.contains($0.0) }?.1 ?? name
}

/// Splits streamed text into whole lines (a chunk may end in the middle of one).
final class LineBuffer {
    private var rest = ""
    private let lock = NSLock()
    func feed(_ text: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        rest += text
        var parts = rest.components(separatedBy: "\n")
        rest = parts.removeLast()
        return parts.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
    func flush() -> String? { lock.lock(); defer { lock.unlock() }; let r = rest; rest = ""; return r.isEmpty ? nil : r }
}

// MARK: - nxnative: running and start-up

/// One pass over the process table: for each wanted executable path (compared as proc_pidpath reports it), a pid that runs it.
func runningExecutables(_ wanted: [String]) -> [String: Int32] {
    let real = Dictionary(wanted.map { (realPath($0), $0) }, uniquingKeysWith: { a, _ in a })
    guard !real.isEmpty else { return [:] }
    var all = [pid_t](repeating: 0, count: 4096)
    let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &all, Int32(MemoryLayout<pid_t>.size * all.count))
    guard bytes > 0 else { return [:] }
    var found: [String: Int32] = [:]
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in all.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, let orig = real[String(cString: buf)] else { continue }
        if found[orig] == nil { found[orig] = pid }
    }
    return found
}

/// realpath(3): symlinks resolved, "/private" kept (URL.resolvingSymlinksInPath drops it), the path itself when it does not exist.
func realPath(_ p: String) -> String {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(p, &buf) != nil ? String(cString: buf) : p
}

/// An nxnative game's host (the app's Contents/MacOS/dmhost).
func nxHostPath(app: String) -> String { (app as NSString).expandingTildeInPath + "/Contents/MacOS/dmhost" }

/// The pid of an nxnative game's host while it runs.
func nxRunningPID(app: String) -> Int32? {
    guard !app.isEmpty else { return nil }
    let host = nxHostPath(app: app)
    return runningExecutables([host])[host]
}

/// A start of an nxnative game that failed: the message to show, or nil. The launcher (dm/mac/launcher.c) logs "the host exited with N"
/// when the game ends and "[RED] ..." for what went wrong.
func nxLaunchFailure(log: String) -> String? {
    let lines = log.split(separator: "\n").map(String.init)
    let reds = lines.filter { $0.contains("[RED]") }
    guard let exit = lines.last(where: { $0.contains("the host exited with ") }) else { return nil }
    let code = exit.components(separatedBy: "the host exited with ").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    if code == "0" { return nil }
    let why = reds.last.map { $0.replacingOccurrences(of: "[RED] ", with: "") } ?? "退出码 \(code)"
    return "游戏启动失败：" + why
}
