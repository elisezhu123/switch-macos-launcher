// Tests of the nxnative side of LauncherCore.swift (catalog, env.txt, overlay, staging, progress, run detection).
import Foundation

private func write(_ text: String, to u: URL) {
    try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: u, atomically: true, encoding: .utf8)
}

// MARK: catalog and games

func testCatalogHasAllNxnativeGames() {
    expect(nxBuiltinCatalog.count == 69, "69 profiles, got \(nxBuiltinCatalog.count)")
    expect(Set(nxBuiltinCatalog.map(\.id)).count == nxBuiltinCatalog.count, "title IDs are unique")
    expect(nxBuiltinCatalog.allSatisfy { g in g.id.count == 16 && !g.builds.isEmpty && g.builds.contains { $0.version == g.package } }, "every game has its package among its builds")
    expect(GameKind.all.count == 2 + GameCatalog.nx.count, "library = 2 MacNativeGames games + the nxnative catalog")
    let u = GameKind.nx("010069401ADB8000")
    expect(u.backend == .nxnative && u.englishName == "Unicorn Overlord" && u.displayName == "圣兽之王", "Unicorn Overlord")
    expect(u.nxInfo?.packageDisplay == "1.05", "its supported version")
    let wonder = GameKind.nx("010015100B514000").nxInfo
    expect(wonder?.displayVersions == ["1.0.0", "1.0.1", "1.2.1"] && wonder?.packageDisplay == "1.2.1", "Wonder registers three builds")
    expect(GameKind.nx("0100A83022A22000").displayName == "Absolum", "no Chinese name: the English one")
    expect(GameKind.totk.supportedVersions == ["1.0.0", "1.1.2", "1.4.3"] && GameKind.botw.supportedVersions == ["1.9.0"], "MacNativeGames versions")
}

func testExtractedIcon() {
    let work = tempHome()
    expect(extractedIcon(workDir: work, titleID: "0100DCA0064A6000") == nil, "nothing extracted yet")
    write("x", to: work.appendingPathComponent("0100DCA0064A6000_build/extract/v0/icon.jpg"))
    write("x", to: work.appendingPathComponent("0100DCA0064A6000_build/extract/v327680/icon.jpg"))
    expect(extractedIcon(workDir: work, titleID: "0100DCA0064A6000")?.path.hasSuffix("v327680/icon.jpg") == true, "the newest version's icon")
    var s = LauncherSettings(); s.showCovers = false
    let back = try! JSONDecoder().decode(LauncherSettings.self, from: JSONEncoder().encode(s))
    expect(!back.showCovers && (try! JSONDecoder().decode(LauncherSettings.self, from: Data("{}".utf8))).showCovers, "covers setting: kept, on by default")
}

func testVersionSelection() {
    let wonder = GameKind.nx("010015100B514000")
    var gs = GameSettings()
    expect(selectedVersion(wonder, settings: gs) == "1.2.1", "default: nxnative's package")
    gs.update = "~/w/Wonder [010015100B514800][v65536].nsp"
    expect(selectedVersion(wonder, settings: gs) == "1.0.1", "from the update's [v] tag")
    gs.version = "1.0.0"
    expect(selectedVersion(wonder, settings: gs) == "1.0.0", "the player's choice wins")
    expect(!versionNeedsUpdate(wonder, version: "1.0.0") && versionNeedsUpdate(wonder, version: "1.2.1"), "only v0 builds without an update")
    gs.version = "9.9.9"
    expect(selectedVersion(wonder, settings: gs) == "1.0.1", "an unknown choice is ignored")
    expect(selectedVersion(.totk, settings: GameSettings()) == "1.4.3", "TOTK default: newest")
    expect(!versionNeedsUpdate(.totk, version: "1.0.0") && versionNeedsUpdate(.totk, version: "1.1.2") && versionNeedsUpdate(.botw, version: "1.9.0"), "MacNativeGames")
    expect(updateVersion(.totk, fileName: "TOTK v1.4.3 [0100F2C0115B6800][UPD].nsp") == "1.4.3", "TOTK update name")
}

func testAutoInstallSettingRoundTrip() {
    let home = tempHome(), file = home.appendingPathComponent("s.json")
    var s = LauncherSettings.load(from: file, legacy: home.appendingPathComponent("none"), home: home)
    expect(s.autoInstall, "on by default")
    s.autoInstall = false; s.current.version = "1.1.2"; s.write(to: file)
    let r = LauncherSettings.load(from: file, legacy: home.appendingPathComponent("none"), home: home)
    expect(!r.autoInstall && r.current.version == "1.1.2", "round trip")
}

func testProxyDetectionAndMirrors() {
    let off = "<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n  SOCKSEnable : 0\n}"
    let on = "<dictionary> {\n  HTTPEnable : 1\n  HTTPProxy : 127.0.0.1\n  HTTPSEnable : 1\n}"
    expect(!proxyConfigured(environment: [:], scutil: off), "no proxy")
    expect(proxyConfigured(environment: [:], scutil: on), "system proxy")
    expect(proxyConfigured(environment: ["HTTPS_PROXY": "http://127.0.0.1:7890"], scutil: off), "proxy in the environment")
    expect(!proxyConfigured(environment: ["HTTPS_PROXY": ""], scutil: off), "an empty variable is no proxy")
    expect(useMirrors(.auto, proxy: false) && !useMirrors(.auto, proxy: true) && useMirrors(.mirror, proxy: true) && !useMirrors(.direct, proxy: false), "modes")
    expect(mirrorExports(false).isEmpty && mirrorExports(true).contains("export PIP_INDEX_URL='https://pypi.tuna.tsinghua.edu.cn/simple'; "), "exports")
    expect(installCommand(project: "/p", baseCommit: "abc", patches: [], mirror: true).contains("origin https://ghfast.top/https://github.com/ly05010419/MacNativeGames") &&
           installCommand(project: "/p", baseCommit: "abc", patches: []).contains("origin https://github.com/ly05010419/MacNativeGames &&"), "MacNativeGames source")
    let clone = nxCloneCommand(dir: "/n", mirror: true)
    expect(clone.contains("clone --depth 1 https://ghfast.top/https://github.com/seedds/nxnative.git") && clone.hasSuffix("remote set-url origin https://github.com/seedds/nxnative.git"), "nxnative clone through the mirror")
    expect(nxUpdateCommand(dir: "/n") == "git -C '/n' pull --ff-only" && nxUpdateCommand(dir: "/n", mirror: true).hasSuffix("nxnative.git HEAD"), "update")
    expect(brewInstallCommand(mirror: true).contains("mirrors.ustc.edu.cn") && brewInstallCommand(mirror: false).contains("raw.githubusercontent.com"), "Homebrew installer")
    let sc = "<dictionary> {\n  HTTPEnable : 1\n  HTTPPort : 6152\n  HTTPProxy : 127.0.0.1\n  HTTPSEnable : 1\n  HTTPSPort : 6152\n  HTTPSProxy : 127.0.0.1\n  SOCKSEnable : 0\n}"
    let pe = systemProxyEnvironment(scutil: sc)
    expect(pe["https_proxy"] == "http://127.0.0.1:6152" && pe["HTTP_PROXY"] == "http://127.0.0.1:6152" && pe["all_proxy"] == nil, "system proxy for child processes: \(pe)")
    expect(systemProxyEnvironment(scutil: off).isEmpty, "no proxy, no variables")
    let ne = networkEnvironment(mirror: true, proxy: pe)
    expect(ne["PIP_INDEX_URL"] == Mirrors.pypi && ne["https_proxy"] != nil && ne["PIP_DEFAULT_TIMEOUT"] == "60", "mirror + proxy + pip timeout")
    expect(useMirrors(.auto, proxy: true, officialFast: false) && !useMirrors(.direct, proxy: true, officialFast: false), "slow official sources")
    let script = terminalInstallScript(["a", "b"])
    expect(script.hasPrefix("{ sudo -v;") && script.contains("a; b; kill $KEEP"), "one password, then each installer: \(script)")
}

func testGameKindIsAPlainStringInJSON() {
    let data = try! JSONEncoder().encode(["k": GameKind.totk, "n": GameKind.nx("0100152000022000")])
    let text = String(decoding: data, as: UTF8.self)
    expect(text.contains("\"totk\"") && text.contains("\"nx-0100152000022000\""), "encoded as strings: \(text)")
    let back = try! JSONDecoder().decode([String: GameKind].self, from: data)
    expect(back["k"] == .totk && back["n"] == GameKind.nx("0100152000022000"), "round trip")
}

func testNxPathsFollowTheMacApp() {
    let p = GamePaths(.nx("010069401ADB8000"), home: URL(fileURLWithPath: "/Users/x"))
    expect(p.support.path == "/Users/x/Library/Application Support/nxnative/010069401ADB8000", "support")
    expect(p.envFile.path == p.support.path + "/env.txt" && p.profileSave.path == p.support.path + "/save", "env.txt and save")
    expect(p.log.path == "/Users/x/Library/Logs/nxnative/010069401ADB8000.log", "log")
    expect(GamePaths(.totk, home: URL(fileURLWithPath: "/Users/x")).support.path.hasSuffix("MacNativeGames/TOTK"), "MacNativeGames paths unchanged")
}

func testNxDefaultsAndNames() {
    expect(safeFileName("The Legend of Zelda: Tears of the Kingdom") == "The Legend of Zelda Tears of the Kingdom", "colon dropped")
    expect(safeFileName("Pokémon Legends: Z-A") == "Pokémon Legends Z-A", "accents and hyphen kept")
    let home = tempHome()
    let d = GameSettings.defaults(.nx("0100E65002BB8000"), home: home)
    expect(d.outputApp.hasSuffix("Games/MacNative/Stardew Valley.app") && d.workDir.hasSuffix("Games/MacNative/nx/0100E65002BB8000"), "default app and work folder")
}

// MARK: settings compatibility

func testV110SettingsFileStillLoads() {
    let home = tempHome()
    let file = home.appendingPathComponent("s.json")
    let json = """
    {"selected":"botw","keys":"~/k","firmware":"~/fw","language":"ja","projectDir":"/p",
     "games":{"botw":{"game":"~/b.nsp","update":"~/u.nsp","save":"","mods":"~/m","outputApp":"/x/B.app","workDir":"/w","modOrder":["a","b"],"modsEnabled":{"a":false}},
              "totk":{"game":"~/t.xci","update":"","save":"","mods":"","outputApp":"/x/T.app","workDir":"/w2","modOrder":[],"modsEnabled":{}}}}
    """
    try! json.data(using: .utf8)!.write(to: file)
    let s = LauncherSettings.load(from: file, legacy: home.appendingPathComponent("none"), home: home)
    expect(s.selected == .botw && s.keys == "~/k" && s.language == "ja" && s.projectDir == "/p", "top level kept")
    let b = s.games["botw"]
    expect(b?.game == "~/b.nsp" && b?.mods == "~/m" && b?.modOrder == ["a", "b"] && b?.modsEnabled["a"] == false, "per-game kept")
    expect(b?.dlc == "" && b?.nxEnv.isEmpty == true, "new fields default")
    expect(s.nxDir.hasSuffix("/nxnative"), "nxDir defaults")
}

func testNxChoicesRoundTrip() {
    let home = tempHome(), file = home.appendingPathComponent("s.json")
    var s = LauncherSettings.load(from: file, legacy: home.appendingPathComponent("none"), home: home)
    s.selected = .nx("010069401ADB8000"); s.game = "~/uo.nsp"; s.dlc = "~/dlc"; s.current.nxEnv["DM_PSO_PREPARE_THREADS"] = "6"
    s.write(to: file)
    let r = LauncherSettings.load(from: file, legacy: home.appendingPathComponent("none"), home: home)
    expect(r.selected == .nx("010069401ADB8000") && r.game == "~/uo.nsp" && r.dlc == "~/dlc" && r.current.nxEnv["DM_PSO_PREPARE_THREADS"] == "6", "nx settings survive a write and read")
    expect(r.games.count == 3, "only touched nx games are stored (2 MacNativeGames + 1)")
}

// MARK: env.txt

func testNormalizingSettingValues() {
    func s(_ v: String) -> NXSetting { nxSettingTable.first { $0.variable == v }! }
    expect(nxNormalized("60", for: s("DM_FPS_TARGET")) == "60" && nxNormalized("45", for: s("DM_FPS_TARGET")) == nil, "choice")
    expect(nxNormalized("1", for: s("DM_SHOW_FPS")) == "1" && nxNormalized("yes", for: s("DM_SHOW_FPS")) == nil, "toggle")
    expect(nxNormalized("on", for: s("DM_FPS_HOLD")) == "on", "toggle with on/off words")
    expect(nxNormalized("0.8", for: s("DM_RENDER_SCALE")) == "0.8" && nxNormalized("9", for: s("DM_RENDER_SCALE")) == "1" && nxNormalized("x", for: s("DM_RENDER_SCALE")) == nil, "range is clamped")
    expect(nxNormalized("8", for: s("DM_PSO_PREPARE_THREADS")) == "8" && nxNormalized("0", for: s("DM_PSO_PREPARE_THREADS")) == nil
           && nxNormalized("99", for: s("DM_PSO_PREPARE_THREADS")) == "32", "threads: 0 = automatic, capped")
}

func testManagedEnvForAGame() {
    let wonder = GameKind.nx("0100DCA0064A6000"), stardew = GameKind.nx("0100E65002BB8000")
    var gs = GameSettings()
    gs.nxEnv = ["DM_FPS_TARGET": "60", "DM_PSO_PREPARE_THREADS": "6", "DM_SHOW_FPS": "maybe", "DM_FPS_HOLD": "on"]
    let a = Dictionary(nxManagedEnv(game: wonder, settings: gs, language: "zh-Hans", supportedLanguages: ["en-US", "zh-Hans"], overlay: "/m1:/m2"), uniquingKeysWith: { a, _ in a })
    expect(a["DM_LANG"] == "zh-Hans" && a["DM_FPS_TARGET"] == "60" && a["DM_PSO_PREPARE_THREADS"] == "6" && a["DM_FPS_HOLD"] == "on", "values written")
    expect(a["DM_SHOW_FPS"] == nil, "an invalid value is not written")
    expect(a["DM_ROMFS_OVERLAY"] == "/m1:/m2", "overlay")
    let b = Dictionary(nxManagedEnv(game: stardew, settings: gs, language: "zh-Hans", supportedLanguages: ["en-US"], overlay: ""), uniquingKeysWith: { a, _ in a })
    expect(b["DM_LANG"] == nil, "a language the game lacks is left out")
    expect(b["DM_FPS_TARGET"] == nil && b["DM_FPS_HOLD"] == nil, "no 60 fps mode: the fps settings do not apply")
    expect(b["DM_ROMFS_OVERLAY"] == nil, "no mods, no overlay")
    let c = nxManagedEnv(game: stardew, settings: GameSettings(), language: "ja", supportedLanguages: nil, overlay: "")
    expect(c.count == 1 && c[0].0 == "DM_LANG", "language unknown: written; defaults write nothing else")
}

func testMergeKeepsHandWrittenLinesFirst() {
    let mine = [("DM_LANG", "ja"), ("DM_PSO_PREPARE_THREADS", "4")]
    let once = mergeManagedEnv(existing: "DM_SHOW_FPS=1\n# note\n", managed: mine)
    expect(once.hasPrefix("DM_SHOW_FPS=1\n# note\n" + envBlockBegin), "hand-written lines stay first (the host takes the first line of a variable)")
    expect(once.contains("DM_LANG=ja\n") && once.hasSuffix(envBlockEnd + "\n"), "block written")
    expect(mergeManagedEnv(existing: once, managed: mine) == once, "writing twice changes nothing")
    let changed = mergeManagedEnv(existing: once, managed: [("DM_LANG", "ko")])
    expect(changed.contains("DM_LANG=ko") && !changed.contains("DM_LANG=ja") && !changed.contains("PREPARE_THREADS") && changed.hasPrefix("DM_SHOW_FPS=1\n"), "block replaced, the rest kept")
    expect(mergeManagedEnv(existing: once, managed: []) == "DM_SHOW_FPS=1\n# note\n", "empty managed list removes only the block")
    expect(mergeManagedEnv(existing: "", managed: []) == "", "nothing to write")
    expect(!mergeManagedEnv(existing: "", managed: [("A", "x\nB=y")]).contains("B=y"), "a value with a line break is dropped")
}

func testWriteManagedEnvRemovesAnEmptyFile() {
    let f = tempHome().appendingPathComponent("sup/env.txt")
    try! writeManagedEnv([("DM_LANG", "ja")], to: f)
    expect((try? String(contentsOf: f, encoding: .utf8))?.contains("DM_LANG=ja") == true, "written, folder created")
    try! writeManagedEnv([], to: f)
    expect(!FileManager.default.fileExists(atPath: f.path), "only our block: the file goes away")
    write("KEEP=1\n", to: f)
    try! writeManagedEnv([("DM_LANG", "ja")], to: f); try! writeManagedEnv([], to: f)
    expect((try? String(contentsOf: f, encoding: .utf8)) == "KEEP=1\n", "the player's line survives")
}

func testOverlayRootsAreReversedForFirstWins() {
    let d = tempHome()
    func mod(_ n: String, files: [String] = ["a"]) -> ModInfo { ModInfo(name: n, root: d.appendingPathComponent(n + "/romfs"), files: files) }
    let mods = [mod("a"), mod("b"), mod("c"), mod("empty", files: [])]
    let r = overlayRoots(mods, order: ["a", "b", "c"], enabled: ["b": false])
    expect(r.value == d.path + "/c/romfs:" + d.path + "/a/romfs", "the last mod (which wins) is listed first, b is off, a mod with no files is not listed: \(r.value)")
    let colon = ModInfo(name: "x", root: URL(fileURLWithPath: "/tmp/a:b/romfs"), files: ["f"])
    let r2 = overlayRoots([colon, mod("a")], order: [], enabled: [:])
    expect(r2.skipped == ["x"] && !r2.value.contains("a:b"), "a path with ':' cannot be listed")
    expect(overlayRoots([], order: [], enabled: [:]).value == "", "no mods, no overlay")
}

// MARK: NACP, files, staging

func testNacpLanguages() {
    var d = Data(count: 0x4000)
    let flags: UInt32 = 1 | 1 << 2 | 1 << 14   // en-US, ja, zh-Hans
    for i in 0..<4 { d[0x302C + i] = UInt8(flags >> UInt32(8 * i) & 0xFF) }
    let f = tempHome().appendingPathComponent("control.nacp"); try! d.write(to: f)
    expect(nacpSupportedLanguages(f) == ["en-US", "ja", "zh-Hans"], "languages: \(String(describing: nacpSupportedLanguages(f)))")
    let short = tempHome().appendingPathComponent("short.nacp"); try! Data(count: 100).write(to: short)
    expect(nacpSupportedLanguages(short) == nil && nacpSupportedLanguages(short.appendingPathExtension("x")) == nil, "short or missing file: unknown")
}

func testFindControlNacp() {
    let work = tempHome()
    expect(findControlNacp(workDir: work, titleID: "0100000000010000") == nil, "before the first build")
    write("x", to: work.appendingPathComponent("0100000000010000_build/extract/v0/control.nacp"))
    expect(findControlNacp(workDir: work, titleID: "0100000000010000")?.path.hasSuffix("extract/v0/control.nacp") == true, "found")
}

func testFileNamesAndVersionTags() {
    expect(titleIDs(inFileName: "Game [010069401ADB8000][v0].nsp") == ["010069401ADB8000"], "title ID")
    expect(titleIDs(inFileName: "x 0100f2c0115b6800 y") == ["0100F2C0115B6800"], "lower case")
    expect(titleIDs(inFileName: "no id here 12345.nsp").isEmpty, "none")
    expect(versionTag(inFileName: "U [010069401ADB8800][v262144].nsp") == 262144 && versionTag(inFileName: "U.nsp") == nil, "version tag")
    let uo = GameKind.nx("010069401ADB8000")
    let base = gameForFileName("Unicorn [010069401ADB8000][v0].nsp", current: .totk)
    expect(base?.game == uo && base?.isUpdate == false, "base game")
    let upd = gameForFileName("Unicorn [010069401ADB8800][v262144].nsp", current: .totk)
    expect(upd?.game == uo && upd?.isUpdate == true, "its update is ID + 0x800")
    expect(gameForFileName("TOTK [0100F2C0115B6000].xci", current: .botw)?.game == .totk, "TOTK defaults to the MacNativeGames one")
    expect(gameForFileName("TOTK [0100F2C0115B6000].xci", current: .nx("0100F2C0115B6000"))?.game == .nx("0100F2C0115B6000"), "unless its nxnative entry is selected")
    expect(gameForFileName("TOTK upd [0100F2C0115B6800][v720896].nsp", current: .totk)?.isUpdate == true, "TOTK update")
    expect(gameForFileName("unknown [0100AAAAAAAAA000].nsp", current: .totk) == nil && gameForFileName("prod.keys", current: .totk) == nil, "unknown")
}

func testStagingOnlyTouchesItsOwnSymlinks() {
    let d = tempHome(), stage = d.appendingPathComponent("stage")
    let base = d.appendingPathComponent("lib/base [0100E65002BB8000][v0].nsp"), upd = d.appendingPathComponent("lib/upd [0100E65002BB8800][v1310720].nsp")
    write("b", to: base); write("u", to: upd)
    write("keep", to: stage.appendingPathComponent("0100E65002BB8000_build/extract/x"))
    write("real", to: stage.appendingPathComponent("notes.txt"))
    try! stageGameFiles(stage: stage, files: [base, upd])
    let fm = FileManager.default
    expect((try? fm.destinationOfSymbolicLink(atPath: stage.appendingPathComponent(base.lastPathComponent).path)) == base.path, "base linked")
    expect((try? fm.destinationOfSymbolicLink(atPath: stage.appendingPathComponent(upd.lastPathComponent).path)) == upd.path, "update linked")
    try! stageGameFiles(stage: stage, files: [base])   // the update is deselected
    expect((try? fm.destinationOfSymbolicLink(atPath: stage.appendingPathComponent(upd.lastPathComponent).path)) == nil, "stale link removed")
    expect(fm.fileExists(atPath: upd.path), "the original file is untouched")
    expect(fm.fileExists(atPath: stage.appendingPathComponent("0100E65002BB8000_build/extract/x").path) && fm.fileExists(atPath: stage.appendingPathComponent("notes.txt").path), "build folder and real files stay")
    try! stageGameFiles(stage: stage, files: [base])   // idempotent
}

func testStageInputsListsDLCFiles() {
    let d = tempHome()
    write("", to: d.appendingPathComponent("dlc/a [0100E65002BB9001][v0].nsp")); write("", to: d.appendingPathComponent("dlc/readme.txt"))
    let files = stageInputs(game: "~/base.nsp", update: "", dlcFolder: d.appendingPathComponent("dlc").path)
    expect(files.map(\.lastPathComponent) == ["base.nsp", "a [0100E65002BB9001][v0].nsp"], "base, then the DLC packages only: \(files.map(\.lastPathComponent))")
}

// MARK: commands and progress

func testNxCommands() {
    let c = nxBuildCommand(venv: "/v e", stage: "/s t", keys: "/k'ey", app: "/Apps/G.app")
    expect(c.hasPrefix("'/v e/bin/python' scripts/build_ipa_from_nsp.py '/s t' -k '/k'\\''ey' --platform mac-app -o '/Apps/G.app'"), "build command is quoted: \(c)")
    expect(c.hasSuffix("--progress json") && !c.contains(" -l "), "json progress, no language")
    let x = nxBuildCommand(venv: "/v", stage: "/s", keys: "/k", app: "/Apps/G.app", target: .xcode, teamID: "AB12", workspace: "/w.xcworkspace", freeAppleID: true)
    expect(x.hasPrefix("DM_ENTITLEMENTS= '/v/bin/python'") && x.contains("--prepare-xcode --xcode-workspace '/w.xcworkspace' --team-id 'AB12'") && !x.contains("--platform"), "xcode command: \(x)")
    let paid = nxBuildCommand(venv: "/v", stage: "/s", keys: "/k", app: "/Apps/G.app", target: .xcode, freeAppleID: false)
    expect(!paid.contains("DM_ENTITLEMENTS") && !paid.contains("--team-id"), "paid account keeps entitlements")
    let i = nxBuildCommand(venv: "/v", stage: "/s", keys: "/k", app: "/Apps/G.ipa", target: .ipa)
    expect(i.contains("--platform ios -o '/Apps/G.ipa'") && i.hasSuffix("--progress json"), "ipa command: \(i)")
    expect(nxIPAPath(app: "/Apps/G.app") == "/Apps/G.ipa" && nxWorkspacePath(stage: "/a/b/stage") == "/a/b/sw-launcher.xcworkspace", "ios paths")
    var ls = LauncherSettings(); ls.nxTarget = .ipa; ls.teamID = "T"; ls.freeAppleID = false; ls.nxWorkspace = "/w.xcworkspace"
    let back = try? JSONDecoder().decode(LauncherSettings.self, from: JSONEncoder().encode(ls))
    expect(back?.nxTarget == .ipa && back?.teamID == "T" && back?.freeAppleID == false && back?.nxWorkspace == "/w.xcworkspace", "ios settings round-trip")
    expect(nxCloneCommand(dir: "/d").contains("git clone --depth 1 https://github.com/seedds/nxnative.git '/d'"), "clone")
    expect(nxVenvCommand(venv: "/v").contains("PYLZ4_USE_SYSTEM_LZ4=0") && nxVenvCommand(venv: "/v").contains("--no-binary lz4"), "lz4 built from source")
    expect(nxToolPath(venv: "/v").hasPrefix("/v/bin:/opt/homebrew/bin") && nxToolPath(venv: "/v").contains("/usr/local/share/dotnet"), "tool path")
}

func testParsingBuildProgress() {
    expect(parseNXBuildLine(#"{"ev":"stage","k":3,"n":9,"name":"extract v0","step":""}"#) == .stage(k: 3, n: 9, name: "extract v0"), "stage")
    expect(parseNXBuildLine(#"{"ev":"progress","k":3,"name":"extract v0","frac":0.5,"done":1}"#) == .progress(k: 3, name: "extract v0", fraction: 0.5), "progress")
    expect(parseNXBuildLine(#"{"ev":"progress","k":3,"name":"x","frac":null}"#) == .progress(k: 3, name: "x", fraction: nil), "no fraction yet")
    expect(parseNXBuildLine(#"{"ev":"say","msg":"[RED] oops"}"#) == .message("[RED] oops"), "message")
    expect(parseNXBuildLine("plain tool output") == nil && parseNXBuildLine(#"{"ev":"stage_end"}"#) == nil && parseNXBuildLine("{broken") == nil, "other lines")
    expect(nxOverallProgress(k: 1, n: 4, fraction: nil) == 0 && nxOverallProgress(k: 3, n: 4, fraction: 0.5) == 0.625 && nxOverallProgress(k: 4, n: 4, fraction: 1) == 0.99, "overall")
    expect(nxStageLabel("extract v327680") == "解包游戏文件" && nxStageLabel("extract DLC") == "解包 DLC" && nxStageLabel("Mac app") == "生成 App"
           && nxStageLabel("something new") == "something new", "labels")
}

func testLineBufferJoinsSplitLines() {
    let b = LineBuffer()
    expect(b.feed("{\"ev\":\"sta") == [], "no whole line yet")
    expect(b.feed("ge\"}\nsecond\r\nthi") == ["{\"ev\":\"stage\"}", "second"], "two lines, one left over")
    expect(b.feed("rd\n") == ["third"] && b.flush() == nil, "completed")
    _ = b.feed("tail"); expect(b.flush() == "tail", "flush returns the rest")
}

func testNxLaunchFailure() {
    expect(nxLaunchFailure(log: "launcher: x (id), host /h\nlauncher: env DM_LANG=ja\n") == nil, "still running")
    expect(nxLaunchFailure(log: "launcher: the host exited with 0\n") == nil, "a clean exit is not a failure")
    let m = nxLaunchFailure(log: "[RED] no game profile 0100 surveying first\nlauncher: the host exited with 1\n")
    expect(m == "游戏启动失败：no game profile 0100 surveying first", "last [RED] line: \(String(describing: m))")
    expect(nxLaunchFailure(log: "launcher: the host exited with 139\n") == "游戏启动失败：退出码 139", "exit code only")
}

// MARK: catalog from a checkout, running

func testCatalogReadsACheckout() {
    let games = tempHome().appendingPathComponent("games")
    write("# c\n\ntitle_id\t0100E65002BB8000\nname\tStardew Valley\nbuild\tv1310720\t1.6.15.13\nbuild\tv1400000\t1.7.0\npackage\tv1400000\n", to: games.appendingPathComponent("0100E65002BB8000/game.tsv"))
    write("title_id\t0100AAAA00000000\nname\tNew Game\nbuild\tv0\t1.0.0\nfps_target\t60\n", to: games.appendingPathComponent("0100AAAA00000000/game.tsv"))
    write("name\tNo id\n", to: games.appendingPathComponent("notes/game.tsv"))
    let before = GameCatalog.nx
    defer { GameCatalog.nx = before }
    GameCatalog.merge(gamesDir: games)
    let s = GameCatalog.nx["0100E65002BB8000"]
    expect(s?.displayVersions == ["1.6.15.13", "1.7.0"] && s?.packageDisplay == "1.7.0", "a newer version from the checkout")
    expect(s?.zh == "星露谷物语", "the Chinese name of the built-in list is kept")
    expect(GameCatalog.nx["0100AAAA00000000"]?.fps == 60 && GameKind.nx("0100AAAA00000000").displayName == "New Game", "a new game appears")
    expect(GameCatalog.nx.count == before.count + 1, "a folder without a valid title ID is ignored")
}

func testRunningNxGameIsFoundByItsHost() {
    let d = tempHome(), app = d.appendingPathComponent("Fake.app")
    let host = app.appendingPathComponent("Contents/MacOS/dmhost")
    try! FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
    // A copied system binary is killed by macOS, so the stand-in host is a tiny program of our own (ad-hoc signed by the linker).
    let src = d.appendingPathComponent("host.c")
    write("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n", to: src)
    let cc = Process(); cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc"); cc.arguments = [src.path, "-o", host.path]
    try! cc.run(); cc.waitUntilExit()
    expect(cc.terminationStatus == 0, "compiled the stand-in host")
    let p = Process(); p.executableURL = host
    do { try p.run() } catch { expect(false, "cannot start the stand-in host: \(error)"); return }
    defer { p.terminate(); p.waitUntilExit() }
    for _ in 0..<20 where nxRunningPID(app: app.path) == nil { Thread.sleep(forTimeInterval: 0.1) }
    expect(nxRunningPID(app: app.path) == p.processIdentifier, "the host is found by its path")

    let a = GameKind.nx("0100E65002BB8000"), b = GameKind.nx("010020D01AD24000")
    var s = LauncherSettings.fresh(home: d)
    s.games[a.rawValue] = { var g = GameSettings(); g.outputApp = app.path; return g }()
    if case .running(let pid) = runState(for: a, settings: s, home: d) { expect(pid == p.processIdentifier, "running pid") } else { expect(false, "a is running") }
    if case .otherGameRunning(let g) = runState(for: b, settings: s, home: d) { expect(g == a, "b is blocked by a") } else { expect(false, "b must see that a is running") }
    p.terminate(); p.waitUntilExit()
    if case .idle = runState(for: b, settings: s, home: d) {} else { expect(false, "idle after the host exits") }
    expect(nxRunningPID(app: d.appendingPathComponent("Nope.app").path) == nil && nxRunningPID(app: "") == nil, "no such app")
}

let nxTests: [(String, () -> Void)] = [
    ("testExtractedIcon", testExtractedIcon), ("testProxyDetectionAndMirrors", testProxyDetectionAndMirrors), ("testVersionSelection", testVersionSelection), ("testAutoInstallSettingRoundTrip", testAutoInstallSettingRoundTrip),
    ("testCatalogHasAllNxnativeGames", testCatalogHasAllNxnativeGames), ("testGameKindIsAPlainStringInJSON", testGameKindIsAPlainStringInJSON),
    ("testNxPathsFollowTheMacApp", testNxPathsFollowTheMacApp), ("testNxDefaultsAndNames", testNxDefaultsAndNames),
    ("testV110SettingsFileStillLoads", testV110SettingsFileStillLoads), ("testNxChoicesRoundTrip", testNxChoicesRoundTrip),
    ("testNormalizingSettingValues", testNormalizingSettingValues), ("testManagedEnvForAGame", testManagedEnvForAGame),
    ("testMergeKeepsHandWrittenLinesFirst", testMergeKeepsHandWrittenLinesFirst), ("testWriteManagedEnvRemovesAnEmptyFile", testWriteManagedEnvRemovesAnEmptyFile),
    ("testOverlayRootsAreReversedForFirstWins", testOverlayRootsAreReversedForFirstWins),
    ("testNacpLanguages", testNacpLanguages), ("testFindControlNacp", testFindControlNacp), ("testFileNamesAndVersionTags", testFileNamesAndVersionTags),
    ("testStagingOnlyTouchesItsOwnSymlinks", testStagingOnlyTouchesItsOwnSymlinks), ("testStageInputsListsDLCFiles", testStageInputsListsDLCFiles),
    ("testNxCommands", testNxCommands), ("testParsingBuildProgress", testParsingBuildProgress), ("testLineBufferJoinsSplitLines", testLineBufferJoinsSplitLines),
    ("testNxLaunchFailure", testNxLaunchFailure), ("testCatalogReadsACheckout", testCatalogReadsACheckout),
    ("testRunningNxGameIsFoundByItsHost", testRunningNxGameIsFoundByItsHost),
]
