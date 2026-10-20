// Tests for the mods (Task 7), run detection (Task 8) and install command (Task 9) parts of LauncherCore.swift.
import Foundation

func makeFile(_ root: URL, _ rel: String, _ bytes: Int = 4) {
    let u = root.appendingPathComponent(rel)
    try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(repeating: 65, count: bytes).write(to: u)
}

func testScanBothLayouts() {
    let d = tempHome()
    makeFile(d, "A/romfs/x.txt"); makeFile(d, "contents/01007EF00011E000/B/romfs/Sub/y.txt")
    let botw = scanMods(dir: d, titleID: "01007EF00011E000").map(\.name).sorted()
    expect(botw == ["A", "B"], "both layouts for BOTW: \(botw)")
    let totk = scanMods(dir: d, titleID: "0100F2C0115B6000").map(\.name)
    expect(totk == ["A"], "other game's contents/ folder ignored: \(totk)")
    let b = scanMods(dir: d, titleID: "01007ef00011e000").first { $0.name == "B" }
    expect(b?.files == ["Sub/y.txt"], "RomFS-relative file list")
}

func testLaterModWins() {
    let d = tempHome()
    makeFile(d, "A/romfs/x.txt"); makeFile(d, "B/romfs/x.txt")
    let r = resolveMods(scanMods(dir: d, titleID: "X"), order: ["A", "B"], enabled: [:])
    expect(r.winners["x.txt"]?.mod == "B", "later mod wins")
    expect(r.conflicts["x.txt"] == ["A", "B"], "conflict listed in order")
}

func testDisabledModIgnored() {
    let d = tempHome()
    makeFile(d, "A/romfs/x.txt"); makeFile(d, "B/romfs/x.txt")
    let r = resolveMods(scanMods(dir: d, titleID: "X"), order: ["A", "B"], enabled: ["B": false])
    expect(r.winners["x.txt"]?.mod == "A", "disabled mod ignored")
    expect(r.conflicts.isEmpty, "no conflict with a disabled mod")
}

func testManifestEscapesPaths() {
    let d = tempHome()
    makeFile(d, "塞尔达 mods/它's/romfs/UI/a.txt", 7)
    makeFile(d, "塞尔达 mods/它's/romfs/bad\tname.txt")
    let r = resolveMods(scanMods(dir: d.appendingPathComponent("塞尔达 mods"), titleID: "X"), order: [], enabled: [:])
    let manifest = d.appendingPathComponent("out/mods.tsv")
    let skipped = try! writeManifest(r, to: manifest)
    let text = try! String(contentsOf: manifest, encoding: .utf8)
    let expected = "UI/a.txt\t" + URL(fileURLWithPath: String(cString: realpath(d.path, nil))).appendingPathComponent("塞尔达 mods/它's/romfs/UI/a.txt").path + "\t7\n"
    expect(text == expected, "manifest line: \(text.debugDescription)")
    expect(skipped == ["bad\tname.txt"], "tab in a file name is skipped and reported: \(skipped)")
}

func testAllDisabledRemovesManifest() {
    let d = tempHome()
    makeFile(d, "A/romfs/x.txt")
    let manifest = d.appendingPathComponent("mods.tsv")
    _ = try! writeManifest(resolveMods(scanMods(dir: d, titleID: "X"), order: [], enabled: [:]), to: manifest)
    expect(FileManager.default.fileExists(atPath: manifest.path), "written")
    _ = try! writeManifest(resolveMods(scanMods(dir: d, titleID: "X"), order: [], enabled: ["A": false]), to: manifest)
    expect(!FileManager.default.fileExists(atPath: manifest.path), "removed when nothing is enabled")
}

func testNewFileIsReported() {
    let log = "[totk] mod: Foo/bar.txt not in the game (new files are not supported)\n[totk] mod: UI/x ignored (built-in fix)\nother\n"
    expect(parseModWarnings(log: log) == ["Foo/bar.txt"], "new-file warnings parsed")
}

func testOrderKeepsUnknownModsSorted() {
    let d = tempHome()
    makeFile(d, "C/romfs/x"); makeFile(d, "A/romfs/y"); makeFile(d, "B/romfs/z")
    let names = orderedMods(scanMods(dir: d, titleID: "X"), order: ["C"]).map(\.name)
    expect(names == ["C", "A", "B"], "listed order first, then by name: \(names)")
}


// MARK: Task 8
func holdSlot(_ g: GameKind, home: URL, start: UInt64?) -> Int32 {
    let slot = GamePaths(g, home: home).gameSlot
    try! FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
    let lock = slot.appendingPathComponent("lock").path
    FileManager.default.createFile(atPath: lock, contents: nil)
    let fd = open(lock, O_RDONLY)
    _ = flock(fd, LOCK_EX)
    let me = getpid()
    let holder = "owner=user\ngame_pid=\(me)\ngame_start=\(start ?? processStart(me))\n"
    try! holder.write(to: slot.appendingPathComponent("holder"), atomically: true, encoding: .utf8)
    return fd
}

func testIdleWhenNoLock() {
    let home = tempHome()
    if case .idle = runState(for: .totk, home: home) {} else { expect(false, "idle without a slot") }
}

func testOtherGameRunningBlocksLaunch() {
    let home = tempHome()
    let fd = holdSlot(.botw, home: home, start: nil)
    defer { close(fd) }
    if case .otherGameRunning(let g) = runState(for: .totk, home: home) { expect(g == .botw, "botw reported") }
    else { expect(false, "other game running") }
    if case .running(let pid) = runState(for: .botw, home: home) { expect(pid == getpid(), "own pid") }
    else { expect(false, "botw itself is running") }
}

func testStaleHolderIsIdle() {
    let home = tempHome()
    let fd = holdSlot(.botw, home: home, start: 12345)
    defer { close(fd) }
    if case .idle = runState(for: .botw, home: home) {} else { expect(false, "start time mismatch means not our game") }
}


// MARK: Task 9
func shellParses(_ cmd: String) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-n", "-c", cmd]
    try! p.run(); p.waitUntilExit(); return p.terminationStatus == 0
}

func testInstallCommandAppliesBothPatchesInOrder() {
    let c = installCommand(project: "/p", baseCommit: "abc", patches: ["/r/totk-mac-fixes.patch", "/r/sw-port.patch"])
    guard let a = c.range(of: "totk-mac-fixes.patch"), let b = c.range(of: "sw-port.patch") else { return expect(false, "both patches named") }
    expect(a.lowerBound < b.lowerBound, "first patch first")
    expect(c.contains("git fetch --depth 1 origin abc"), "pinned commit")
    let u = patchesCommand(project: "/p", patches: ["/r/totk-mac-fixes.patch", "/r/sw-port.patch"])
    expect(u.contains("--reverse --check") && shellParses(u), "update command skips applied patches and parses")
}

func testInstallCommandQuotesPaths() {
    let weird = "/Users/x/它's dir/sw-port.patch"
    let c = installCommand(project: "/Users/x/My 'Tools'", baseCommit: "abc", patches: [weird])
    expect(shellParses(c), "install command parses")
    expect(shellParses(patchesCommand(project: "/Users/x/My 'Tools'", patches: [weird])), "update command parses")
    expect(shellParses(patchCheckCommand(project: "/Users/x/My 'Tools'", patches: [weird])), "check command parses")
    expect(shQuote("a'b") == "'a'\\''b'", "quote: \(shQuote("a'b"))")
}


// MARK: final review fixes
func testUpgradeFallsBackToFreshTool() {
    let c = upgradeCommand(project: "/p/My 'Tools'", fresh: "/p/My 'Tools'-sw-launcher", baseCommit: "abc", patches: ["/r/a.patch", "/r/b.patch"])
    expect(shellParses(c), "upgrade command parses")
    expect(c.contains("git fetch --depth 1 origin abc") && c.contains(freshToolMarker), "fresh install fallback with marker")
}

func testBadRomfsPathsAreSkipped() {
    let d = tempHome()
    makeFile(d, "A/romfs/ok.txt"); makeFile(d, "A/romfs/romfs\\Actor\\x.bin")
    let skipped = try! writeManifest(resolveMods(scanMods(dir: d, titleID: "X"), order: [], enabled: [:]), to: d.appendingPathComponent("m.tsv"))
    expect(skipped == ["romfs\\Actor\\x.bin"], "backslash path skipped: \(skipped)")
    let text = try! String(contentsOf: d.appendingPathComponent("m.tsv"), encoding: .utf8)
    expect(text.hasPrefix("ok.txt\t") && !text.contains("\\"), "only the valid file listed")
}

func testFreshLogIgnoresPreviousRun() {
    let d = tempHome(), log = d.appendingPathComponent("botw.log")
    try! "window visible\n".write(to: log, atomically: false, encoding: .utf8)
    let before = fileIdentity(log)
    expect(freshLog(log, notSameAs: before) == nil, "same file is the previous run")
    try! FileManager.default.moveItem(at: log, to: d.appendingPathComponent("botw.previous.log"))
    try! "FAIL: reserve\n".write(to: log, atomically: false, encoding: .utf8)
    expect(freshLog(log, notSameAs: before) == "FAIL: reserve\n", "rotated log is read")
}

func testLaunchFailureMessages() {
    expect(launchFailure(log: "x\n[totk] FAIL: reserve guest stack\n") == nil, "reserve failures are retried")
    let m = launchFailure(log: "[totk] mod file changed since the launcher listed it: UI/a\n[totk] FAIL: RomFS mod file changed; start the game from the launcher again\n")
    expect(m?.contains("Mod") == true, "mods failure explained: \(m ?? "nil")")
    expect(launchFailure(log: "[totk] FAIL: RomFS integrity mismatch\n")?.contains("RomFS integrity mismatch") == true, "other failures shown")
    expect(launchFailure(log: "all good\n") == nil, "no failure")
}

func testAppSupportsMods() {
    expect(appSupportsMods(info: ["SWModsManifest": true]), "new build")
    expect(!appSupportsMods(info: ["CFBundleExecutable": "TOTK"]), "v1.0.1 build")
}


func run(_ cmd: String) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit(); return p.terminationStatus
}

func testPatchesStopAtFirstFailureEvenInsideOr() {
    let d = tempHome(), repo = d.appendingPathComponent("repo")
    try! FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try! "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try! "two\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    _ = run("cd \(shQuote(repo.path)) && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init")
    let bad = d.appendingPathComponent("bad.patch"), good = d.appendingPathComponent("good.patch")
    try! "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-nope\n+x\n".write(to: bad, atomically: true, encoding: .utf8)
    try! "--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-two\n+TWO\n".write(to: good, atomically: true, encoding: .utf8)
    let status = run("( " + patchesCommand(project: repo.path, patches: [bad.path, good.path]) + " ) || exit 7")
    expect(status == 7, "failure reaches the || fallback: \(status)")
    expect((try? String(contentsOf: repo.appendingPathComponent("b.txt"), encoding: .utf8)) == "two\n", "later patch not applied after a failure")
}

var extraTests: [(String, () -> Void)] = [
    ("testPatchesStopAtFirstFailureEvenInsideOr", testPatchesStopAtFirstFailureEvenInsideOr),
    ("testUpgradeFallsBackToFreshTool", testUpgradeFallsBackToFreshTool), ("testBadRomfsPathsAreSkipped", testBadRomfsPathsAreSkipped),
    ("testFreshLogIgnoresPreviousRun", testFreshLogIgnoresPreviousRun), ("testLaunchFailureMessages", testLaunchFailureMessages), ("testAppSupportsMods", testAppSupportsMods),
    ("testInstallCommandAppliesBothPatchesInOrder", testInstallCommandAppliesBothPatchesInOrder), ("testInstallCommandQuotesPaths", testInstallCommandQuotesPaths),
    ("testIdleWhenNoLock", testIdleWhenNoLock), ("testOtherGameRunningBlocksLaunch", testOtherGameRunningBlocksLaunch),
    ("testStaleHolderIsIdle", testStaleHolderIsIdle),
    ("testScanBothLayouts", testScanBothLayouts), ("testLaterModWins", testLaterModWins),
    ("testDisabledModIgnored", testDisabledModIgnored), ("testManifestEscapesPaths", testManifestEscapesPaths),
    ("testAllDisabledRemovesManifest", testAllDisabledRemovesManifest), ("testNewFileIsReported", testNewFileIsReported),
    ("testOrderKeepsUnknownModsSorted", testOrderKeepsUnknownModsSorted),
]
