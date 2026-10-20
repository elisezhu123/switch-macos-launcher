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

func runState(for game: GameKind, home: URL) -> RunState {
    if let pid = slotHolder(GamePaths(game, home: home).gameSlot) { return .running(pid: pid) }
    for other in GameKind.allCases where other != game {
        if slotHolder(GamePaths(other, home: home).gameSlot) != nil { return .otherGameRunning(other) }
    }
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
