// Tests for LauncherCore.swift (no UI). Run: scripts/test.sh
import Foundation

var failures = 0
func expect(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    if !ok { failures += 1; print("FAIL \((file as NSString).lastPathComponent):\(line) \(what)") }
}
func tempHome() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sw-core-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

// MARK: Task 6
func testMigratesV101Settings() {
    let home = tempHome()
    let legacy = home.appendingPathComponent("Library/Application Support/MacNativeGames/TOTK/launcher.json")
    try! FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
    let json = """
    {"firmware":"~/fw","game":"~/g.xci","keys":"~/prod.keys","language":"ja","mods":"~/mods","outputApp":"/x/TOTK.app",
     "projectDir":"/p","save":"/s","update":"~/u.nsp","workDir":"/w"}
    """
    try! json.data(using: .utf8)!.write(to: legacy)
    let before = try! Data(contentsOf: legacy)
    let s = LauncherSettings.load(from: home.appendingPathComponent("Library/Application Support/MacNativeGames/sw-launcher/launcher.json"),
                                  legacy: legacy, home: home)
    expect(s.selected == .totk, "selected totk")
    let t = s.games[GameKind.totk.rawValue]
    expect(t?.game == "~/g.xci" && t?.update == "~/u.nsp" && t?.save == "/s" && t?.mods == "~/mods", "game fields migrated")
    expect(t?.outputApp == "/x/TOTK.app" && t?.workDir == "/w", "build fields migrated")
    expect(s.keys == "~/prod.keys" && s.firmware == "~/fw" && s.language == "ja" && s.projectDir == "/p", "shared fields migrated")
    expect(try! Data(contentsOf: legacy) == before, "legacy file untouched")
}

func testBotwPaths() {
    let h = URL(fileURLWithPath: "/Users/x")
    let p = GamePaths(.botw, home: h)
    expect(p.log.path == "/Users/x/Library/Logs/MacNativeGames/botw.log", "botw log")
    expect(p.support.path.hasSuffix("MacNativeGames/BOTW"), "botw support")
    expect(p.modsManifest.path == p.support.appendingPathComponent("mods.tsv").path, "mods manifest path")
    expect(p.gameSlot.path == p.support.appendingPathComponent("game-slot").path, "game slot path")
}

func testTotkPathsUnchanged() {
    let h = URL(fileURLWithPath: "/Users/x")
    let p = GamePaths(.totk, home: h)
    expect(p.support.path == "/Users/x/Library/Application Support/MacNativeGames/TOTK", "totk support")
    expect(p.log.path == "/Users/x/Library/Logs/MacNativeGames/totk.log", "totk log")
    expect(p.shaderDir.path == p.support.appendingPathComponent("shader-cache/rt-totk-native-v4-unverified").path, "totk shader dir")
    expect(p.profileSave.path == p.support.appendingPathComponent("profile/save").path, "totk save dir")
}

func testBotwDefaults() {
    let home = tempHome()
    var s = LauncherSettings.load(from: home.appendingPathComponent("none.json"), legacy: home.appendingPathComponent("none2.json"), home: home)
    s.selected = .botw
    expect(s.outputApp.hasSuffix("Games/MacNative/Breath of the Wild.app"), "botw default app")
    expect(s.workDir.hasSuffix("Games/MacNative/BOTW_build"), "botw default work")
    s.game = "~/b.nsp"
    expect(s.games[GameKind.botw.rawValue]?.game == "~/b.nsp", "setter routes to the selected game")
    expect(s.games[GameKind.totk.rawValue]?.game ?? "" == "", "other game untouched")
}

func testSettingsRoundTrip() {
    let home = tempHome()
    let file = home.appendingPathComponent("sw.json")
    var s = LauncherSettings.load(from: file, legacy: home.appendingPathComponent("none.json"), home: home)
    s.selected = .botw; s.game = "~/b.nsp"; s.keys = "~/k"
    s.write(to: file)
    let r = LauncherSettings.load(from: file, legacy: home.appendingPathComponent("none.json"), home: home)
    expect(r.selected == .botw && r.game == "~/b.nsp" && r.keys == "~/k", "round trip")
}

@main struct CoreTestsMain {
    static func main() {
        let all: [(String, () -> Void)] = [
            ("testMigratesV101Settings", testMigratesV101Settings), ("testBotwPaths", testBotwPaths),
            ("testTotkPathsUnchanged", testTotkPathsUnchanged), ("testBotwDefaults", testBotwDefaults),
            ("testSettingsRoundTrip", testSettingsRoundTrip),
        ] + extraTests + nxTests
        for (name, t) in all { let f = failures; t(); if failures > f { print("  in \(name)") } }
        if failures == 0 { print("ALL PASS (\(all.count) tests)") } else { print("\(failures) FAILED"); exit(1) }
    }
}
