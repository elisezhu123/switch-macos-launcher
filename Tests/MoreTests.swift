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

var extraTests: [(String, () -> Void)] = [
    ("testScanBothLayouts", testScanBothLayouts), ("testLaterModWins", testLaterModWins),
    ("testDisabledModIgnored", testDisabledModIgnored), ("testManifestEscapesPaths", testManifestEscapesPaths),
    ("testAllDisabledRemovesManifest", testAllDisabledRemovesManifest), ("testNewFileIsReported", testNewFileIsReported),
    ("testOrderKeepsUnknownModsSorted", testOrderKeepsUnknownModsSorted),
]
