import SwiftUI
import AppKit
import Metal
import Foundation

// MARK: - Paths and settings

/// `--demo`: fixed sample data for documentation screenshots; never reads or writes the real settings.
let isDemoMode = CommandLine.arguments.contains("--demo")

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/MacNativeGames/TOTK")
    static let config = support.appendingPathComponent("launcher.json")
    static let log = home.appendingPathComponent("Library/Logs/MacNativeGames/totk.log")
    static let cleanKeys = support.appendingPathComponent("launcher/prod.keys")
}

struct Language: Identifiable, Hashable {
    let code: String, name: String
    var id: String { code }
    static let all: [Language] = [
        .init(code: "zh-Hans", name: "简体中文"), .init(code: "zh-Hant", name: "繁體中文"),
        .init(code: "en-US", name: "English"), .init(code: "ja", name: "日本語"), .init(code: "ko", name: "한국어"),
        .init(code: "de", name: "Deutsch"), .init(code: "fr", name: "Français"), .init(code: "es", name: "Español"),
        .init(code: "it", name: "Italiano"), .init(code: "nl", name: "Nederlands"), .init(code: "ru", name: "Русский"),
        .init(code: "pt", name: "Português"),
    ]
}

struct LauncherSettings: Codable {
    var game = "", update = "", keys = "", firmware = "", save = "", mods = ""
    var language = "zh-Hans"
    var projectDir = Paths.home.appendingPathComponent("Sites/MacNativeGames").path
    var outputApp = Paths.home.appendingPathComponent("Games/MacNative/Tears of the Kingdom.app").path
    var workDir = Paths.home.appendingPathComponent("Games/MacNative/TOTK_build").path

    static func load() -> LauncherSettings {
        guard let data = try? Data(contentsOf: Paths.config), let s = try? JSONDecoder().decode(LauncherSettings.self, from: data) else { return LauncherSettings() }
        return s
    }
    func persist() {
        if isDemoMode { return }
        try? FileManager.default.createDirectory(at: Paths.config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Paths.config) }
    }
}

// MARK: - System information and compatibility

struct SysInfo {
    var macOS = "", build = "", chip = "", model = "", gpu = ""
    var family: Int? = nil
    var memGB = 0
    var arm64 = true, metal3 = false, metal4 = false
    var major = 0

    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }
    static func sysctlInt(_ name: String) -> Int {
        var v: Int64 = 0; var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : 0
    }

    static func read() -> SysInfo {
        var i = SysInfo()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        i.major = v.majorVersion
        i.macOS = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        i.build = sysctlString("kern.osversion")
        i.chip = sysctlString("machdep.cpu.brand_string")
        i.model = sysctlString("hw.model")
        i.memGB = Int((Double(sysctlInt("hw.memsize")) / 1_073_741_824).rounded())
        i.arm64 = sysctlInt("hw.optional.arm64") == 1
        if let r = i.chip.range(of: #"M(\d+)"#, options: .regularExpression) { i.family = Int(i.chip[r].dropFirst()) }
        if let dev = MTLCreateSystemDefaultDevice() {
            i.gpu = dev.name
            i.metal3 = dev.supportsFamily(.metal3)
            if #available(macOS 26.0, *) { i.metal4 = dev.supportsFamily(.metal4) }
        }
        return i
    }
}

enum Level { case ok, warn, bad }

struct Verdict {
    var level: Level
    var reasons: [String]
    static func of(_ i: SysInfo) -> Verdict {
        var level = Level.ok; var why: [String] = []
        func raise(_ l: Level, _ t: String) { why.append(t); if l == .bad || (l == .warn && level == .ok) { level = l } }
        if !i.arm64 { raise(.bad, "需要 Apple 芯片（M1–M5）的 Mac") }
        if i.major < 26 { raise(.bad, "游戏核心需要 macOS 26 或更新（使用 Metal 4）；启动器本身支持 macOS 15 及以上") }
        else if !i.metal4 { raise(.bad, "这台机器的 Metal 不支持 Metal 4") }
        if i.memGB > 0 && i.memGB < 16 { raise(.warn, "内存 \(i.memGB) GB 偏低，建议 16 GB 或更多") }
        if why.isEmpty { why = ["满足运行要求：Apple 芯片、macOS 26+、Metal 4"] }
        return Verdict(level: level, reasons: why)
    }
}

// MARK: - Environment checks and installers

enum InstallKind { case terminal(String), background(String), link(String), none }

struct Dep: Identifiable {
    enum State: Equatable { case checking, ok, missing, installing(Double?), failed(String) }
    let id: String
    let title: String
    let detail: String
    let size: String?
    let required: Bool
    let install: InstallKind
    var state: State = .checking
}

func sh(_ cmd: String) -> (status: Int32, out: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func runStreaming(_ cmd: String, cwd: String? = nil, env: [String: String] = [:], onText: @escaping (String) -> Void) async -> Int32 {
    await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { onText(String(decoding: d, as: UTF8.self)) }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            cont.resume(returning: proc.terminationStatus)
        }
        do { try p.run() } catch { onText("无法启动命令：\(error)\n"); cont.resume(returning: -1) }
    }
}

func lastMatch(_ pattern: String, in text: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last else { return nil }
    return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
}

func openInTerminal(_ command: String) {
    let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let src = "tell application \"Terminal\"\nactivate\ndo script \"\(esc)\"\nend tell"
    var err: NSDictionary?
    NSAppleScript(source: src)?.executeAndReturnError(&err)
}

// MARK: - Model

enum Field { case game, update, keys, firmware, save }
enum Check { case empty, ok(String), bad(String) }

@MainActor
final class Model: ObservableObject {
    @Published var s = LauncherSettings.load() { didSet { s.persist() } }
    @Published var info = SysInfo.read()
    @Published var deps: [Dep] = []
    @Published var busy: String? = nil
    @Published var progress: Double? = nil
    @Published var step = ""
    @Published var log = ""
    @Published var notice: String? = nil
    @Published var launching = false
    @Published var shaderSources = 0
    @Published var shaderBaked = 0

    static let initialTab: Int = {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--tab").flatMap { Int(a[safe: $0 + 1] ?? "0") } ?? 0
    }()

    init() {
        deps = Model.makeDeps(project: s.projectDir)
        if isDemoMode { demo() }
    }

    /// The build tool is pinned to the upstream commit the compatibility patch was made and tested against.
    static let baseCommit = "41e1e0caf43d58c4af3c478ca2d1bafd9dba7093"
    static var patchPath: String { Bundle.main.path(forResource: "totk-mac-fixes", ofType: "patch") ?? "" }

    static func projectInstallCommand(_ project: String) -> String {
        "set -e; d='\(project)'; if [ -e \"$d\" ] && [ -n \"$(ls -A \"$d\" 2>/dev/null)\" ]; then echo \"目录已存在且不是空的：$d\"; exit 1; fi; " +
        "mkdir -p \"$d\" && cd \"$d\" && git init -q && git remote add origin https://github.com/ly05010419/MacNativeGames && " +
        "git fetch --depth 1 origin \(baseCommit) && git checkout -q FETCH_HEAD && git apply -p1 '\(patchPath)'"
    }

    static func makeDeps(project: String) -> [Dep] {
        [
            Dep(id: "clt", title: "Xcode 命令行工具", detail: "编译游戏运行时所需", size: "约 1 GB", required: true, install: .terminal("xcode-select --install")),
            Dep(id: "brew", title: "Homebrew", detail: "安装 Python 和音视频库", size: nil, required: true,
                install: .terminal("/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")),
            Dep(id: "python", title: "Python 3.14", detail: "运行构建脚本", size: "约 60 MB", required: true,
                install: .background("/opt/homebrew/bin/brew install python@3.14")),
            Dep(id: "libs", title: "opus 与 libvpx", detail: "游戏音频和过场视频解码", size: "约 10 MB", required: true,
                install: .background("/opt/homebrew/bin/brew install opus libvpx")),
            Dep(id: "project", title: "构建工具（MacNativeGames）", detail: project, size: "约 50 MB", required: true,
                install: .background(projectInstallCommand(project))),
            Dep(id: "patch", title: "Mac 兼容补丁", detail: "内存布局回退（M1 / macOS 27）、并行预热、预编译着色器、语言设置", size: nil, required: true,
                install: .background("cd '\(project)' && git apply -p1 --check '\(Model.patchPath)' && git apply -p1 '\(Model.patchPath)'")),
            Dep(id: "xcode", title: "Xcode（完整版）", detail: "下载 Metal Toolchain 需要", size: "约 7 GB", required: false,
                install: .link("macappstore://apps.apple.com/app/xcode/id497799835")),
            Dep(id: "metal", title: "Metal Toolchain", detail: "预编译着色器，缓存不会被系统清掉，启动快几十倍", size: "839 MB", required: false,
                install: .background("xcodebuild -downloadComponent MetalToolchain")),
            Dep(id: "disk", title: "磁盘空间", detail: "构建需要约 25–40 GB 空闲", size: nil, required: true, install: .none),
        ]
    }

    func refreshDeps() {
        if isDemoMode { return }
        let project = s.projectDir
        deps = Model.makeDeps(project: project)
        let ids = deps.map(\.id)
        Task.detached {
            var results: [String: Bool] = [:]
            for id in ids {
                switch id {
                case "clt": results[id] = sh("xcode-select -p >/dev/null 2>&1 && xcrun --find clang >/dev/null 2>&1").status == 0
                case "brew": results[id] = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
                case "python": results[id] = FileManager.default.fileExists(atPath: "/opt/homebrew/opt/python@3.14/bin/python3.14") || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3.14")
                case "libs": results[id] = ["opus", "libvpx"].allSatisfy { FileManager.default.fileExists(atPath: "/opt/homebrew/opt/\($0)") }
                case "project": results[id] = FileManager.default.fileExists(atPath: project + "/build_app.py")
                case "patch":
                    let services = (try? String(contentsOfFile: project + "/games/totk/runtime/services.c", encoding: .utf8)) ?? ""
                    results[id] = services.contains("compact_layout") && FileManager.default.fileExists(atPath: project + "/games/totk/tools/bake_metallibs.py")
                case "xcode": results[id] = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
                case "metal": results[id] = sh("xcrun -sdk macosx metal --version >/dev/null 2>&1").status == 0
                case "disk":
                    let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    results[id] = (v?.volumeAvailableCapacityForImportantUsage ?? 0) > 45 * 1_000_000_000
                default: break
                }
            }
            let final = results
            await MainActor.run {
                for i in self.deps.indices {
                    if case .installing = self.deps[i].state { continue }
                    self.deps[i].state = final[self.deps[i].id] == true ? .ok : .missing
                }
            }
        }
    }

    func install(_ id: String) {
        guard let idx = deps.firstIndex(where: { $0.id == id }) else { return }
        switch deps[idx].install {
        case .terminal(let c): openInTerminal(c); notice = "已在“终端”里打开安装命令，装完后点“重新检查”。"
        case .link(let u): if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case .none: break
        case .background(let cmd):
            deps[idx].state = .installing(nil)
            Task {
                var buffer = ""
                let status = await runStreaming(cmd) { text in
                    Task { @MainActor in
                        buffer += text; self.log += text
                        if let m = lastMatch(#"\(([0-9.]+) (?:MB|KB) of ([0-9.]+) MB downloaded\)"#, in: text),
                           let a = Double(m[1]), let b = Double(m[2]), b > 0, let j = self.deps.firstIndex(where: { $0.id == id }) {
                            self.deps[j].state = .installing(min(a / b, 1))
                        }
                    }
                }
                await MainActor.run {
                    if let j = self.deps.firstIndex(where: { $0.id == id }) {
                        self.deps[j].state = status == 0 ? .checking : .failed("安装没有成功，详情见日志")
                    }
                    self.refreshDeps()
                }
            }
        }
    }

    // MARK: validation

    func check(_ f: Field) -> Check {
        if isDemoMode {
            switch f {
            case .game: return .ok("17.5 GB")
            case .keys: return .ok("prod.keys 格式正常")
            case .firmware: return .ok("238 个固件文件")
            case .update: return .ok("0.5 GB")
            case .save: return .empty
            }
        }
        let fm = FileManager.default
        func path(_ s: String) -> String { (s as NSString).expandingTildeInPath }
        switch f {
        case .game:
            guard !s.game.isEmpty else { return .empty }
            let p = path(s.game), ext = (p as NSString).pathExtension.lowercased()
            guard fm.fileExists(atPath: p) else { return .bad("找不到这个文件") }
            return ["xci", "nsp"].contains(ext) ? .ok(sizeText(p)) : .bad("请选择 .xci 或 .nsp 文件（基础版 1.0.0）")
        case .update:
            guard !s.update.isEmpty else { return .empty }
            let p = path(s.update), ext = (p as NSString).pathExtension.lowercased()
            guard fm.fileExists(atPath: p) else { return .bad("找不到这个文件") }
            return ["nsp", "nsz"].contains(ext) ? .ok(sizeText(p)) : .bad("更新包应为 .nsp 或 .nsz")
        case .keys:
            guard !s.keys.isEmpty else { return .empty }
            let p = path(s.keys)
            guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { return .bad("无法读取这个文件") }
            return text.contains("header_key") && text.contains("master_key_") ? .ok("prod.keys 格式正常") : .bad("看起来不是 prod.keys")
        case .firmware:
            guard !s.firmware.isEmpty else { return .empty }
            let p = path(s.firmware); var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return .bad("找不到这个位置") }
            if !isDir.boolValue { return (p as NSString).pathExtension.lowercased() == "zip" ? .ok("固件压缩包，构建时自动解压") : .bad("请选择固件文件夹或 .zip") }
            let n = ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter { $0.hasSuffix(".nca") }.count
            return n > 10 ? .ok("\(n) 个固件文件") : .bad("文件夹里没有解压后的 .nca 文件")
        case .save:
            guard !s.save.isEmpty else { return .empty }
            let p = path(s.save)
            let items = (try? fm.contentsOfDirectory(atPath: p)) ?? []
            return items.contains(where: { $0.hasPrefix("slot_") }) || items.contains("option.sav") ? .ok("\(items.filter { $0.hasPrefix("slot_") }.count) 个存档位") : .bad("没有找到 slot_00 之类的存档文件夹")
        }
    }

    func sizeText(_ p: String) -> String {
        let n = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.doubleValue ?? 0
        return String(format: "%.1f GB", n / 1_000_000_000)
    }

    var requiredOK: Bool {
        if case .ok = check(.game) {} else { return false }
        if case .ok = check(.keys) {} else { return false }
        if case .ok = check(.firmware) {} else { return false }
        return true
    }
    var depsOK: Bool { deps.filter(\.required).allSatisfy { $0.state == .ok } }
    var verdict: Verdict { Verdict.of(info) }
    var appBuilt: Bool { isDemoMode || FileManager.default.fileExists(atPath: s.outputApp + "/Contents/MacOS/TOTK") }

    var blockers: [String] {
        var out: [String] = []
        if verdict.level == .bad { out.append("系统不满足要求") }
        if case .ok = check(.game) {} else { out.append("游戏本体") }
        if case .ok = check(.keys) {} else { out.append("prod.keys") }
        if case .ok = check(.firmware) {} else { out.append("固件") }
        for d in deps where d.required && d.state != .ok { out.append(d.title) }
        return out
    }

    // MARK: language, save, build, launch

    func applyLanguage() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? (s.language + "\n").write(to: Paths.support.appendingPathComponent("language.txt"), atomically: true, encoding: .utf8)
    }

    func importSave() {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: (s.save as NSString).expandingTildeInPath)
        let root = Paths.support.appendingPathComponent("profile/save")
        let targets = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter { $0.hasDirectoryPath }
        guard targets.count == 1, let target = targets.first else {
            notice = targets.isEmpty ? "还没有游戏存档目录：请先启动一次游戏（进到标题画面即可），再导入存档。" : "发现多个存档目录，请手动处理。"
            return
        }
        let alert = NSAlert()
        alert.messageText = "导入存档？"
        alert.informativeText = "会用所选存档覆盖游戏里同名的存档位。覆盖前会自动备份现有存档。"
        alert.addButton(withTitle: "备份并导入"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = Paths.support.appendingPathComponent("save-backup-\(stamp)")
        let r1 = sh("/usr/bin/ditto '\(target.path)' '\(backup.path)/\(target.lastPathComponent)'")
        let r2 = r1.status == 0 ? sh("/usr/bin/ditto '\(src.path)' '\(target.path)'") : r1
        notice = r2.status == 0 ? "存档已导入。原存档备份在 \(backup.lastPathComponent)。" : "导入失败：\(r2.out)"
    }

    func prepareKeys() -> String {
        // hactool stops at keys whose value has the wrong length (seen in firmware 22 key dumps); the original file stays untouched.
        let src = (s.keys as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: src, encoding: .utf8) else { return src }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            guard let eq = line.firstIndex(of: "=") else { return true }
            let v = line[line.index(after: eq)...].filter { !$0.isWhitespace }
            return v.count != 34
        }
        try? FileManager.default.createDirectory(at: Paths.cleanKeys.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? kept.joined(separator: "\n").write(to: Paths.cleanKeys, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.cleanKeys.path)
        return Paths.cleanKeys.path
    }

    func build() {
        guard busy == nil else { return }
        busy = "构建中"; progress = 0; step = "准备"; log = ""
        let keys = prepareKeys()
        Task {
            var firmware = (s.firmware as NSString).expandingTildeInPath
            if firmware.lowercased().hasSuffix(".zip") {
                step = "解压固件"
                let dest = s.workDir + "/firmware-nca"
                _ = sh("mkdir -p '\(dest)' && /usr/bin/ditto -x -k '\(firmware)' '\(dest)'")
                firmware = dest
            }
            func q(_ x: String) -> String { "'" + (x as NSString).expandingTildeInPath.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            var cmd = "/opt/homebrew/bin/python3.14 build_app.py \(q(s.game)) -k \(q(keys)) --firmware \(q(firmware)) --work \(q(s.workDir)) -o \(q(s.outputApp))"
            if !s.update.isEmpty { cmd += " --update \(q(s.update))" }
            let status = await runStreaming(cmd, cwd: s.projectDir, env: ["PIP_DEFAULT_TIMEOUT": "180", "PIP_RETRIES": "10"]) { text in
                Task { @MainActor in
                    self.log += text
                    if let m = lastMatch(#"(\d)/4 (\w+)"#, in: text), let n = Double(m[1]) {
                        self.progress = (n - 1) / 4
                        self.step = "第 \(m[1]) 步，共 4 步：" + (["code": "改写游戏代码", "data": "解密游戏数据", "update": "合并更新", "shaders": "准备着色器", "app": "生成 App"][m[2]] ?? m[2])
                    }
                }
            }
            busy = nil; progress = nil
            notice = status == 0 ? "构建完成，可以启动游戏了。" : "构建没有成功，请展开下面的日志查看原因。"
            step = ""
        }
    }

    func launch() {
        guard !launching else { return }
        applyLanguage()
        launching = true; notice = "正在启动…"
        let app = s.outputApp
        Task {
            let ok = await Task.detached { () -> Bool in
                for attempt in 1...6 {
                    _ = sh("pkill -f totk-native")
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    _ = sh("/usr/bin/open -n '\(app)'")
                    for _ in 0..<30 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let head = (try? FileHandle(forReadingFrom: Paths.log))?.readData(ofLength: 400_000) ?? Data()
                        let text = String(decoding: head, as: UTF8.self)
                        if text.contains("FAIL: reserve") { break }   // address space was not free this time: try again
                        if text.contains("window visible") || text.contains("启动关键管线已就绪") { return true }
                    }
                    await MainActor.run { self.notice = "第 \(attempt) 次启动没成功，自动重试…" }
                }
                return false
            }.value
            self.launching = false
            self.notice = ok ? "游戏已启动。" : "多次尝试仍未启动，请查看日志 ~/Library/Logs/MacNativeGames/totk.log"
        }
    }

    func pick(directory: Bool, extensions: [String] = [], title: String) -> String? {
        let p = NSOpenPanel()
        p.title = title; p.canChooseFiles = !directory || !extensions.isEmpty; p.canChooseDirectories = directory
        p.allowsMultipleSelection = false; p.showsHiddenFiles = false
        return p.runModal() == .OK ? p.url?.path : nil
    }
}

// MARK: - Library entry, shader cache, bake

extension Model {
    enum Status { case built, building, notBuilt }
    struct Entry {
        let title: String, subtitle: String, version: String, language: String, size: String, path: String
        let status: Status
    }

    var titleID: String {
        let name = (s.game as NSString).lastPathComponent
        if let r = name.range(of: #"0100[0-9A-Fa-f]{12}"#, options: .regularExpression) { return String(name[r]).uppercased() }
        return "0100F2C0115B6000"
    }

    var gameVersion: String {
        let u = (s.update as NSString).lastPathComponent
        if u.contains("1.4.3") || u.contains("720896") { return "1.4.3" }
        if u.contains("1.1.2") || u.contains("65536") { return "1.1.2" }
        let plist = s.outputApp + "/Contents/Info.plist"
        if let d = NSDictionary(contentsOfFile: plist), let v = d["CFBundleShortVersionString"] as? String { return v }
        return "1.0.0"
    }

    var entry: Entry? {
        guard !s.game.isEmpty else { return nil }
        let gamePath = (s.game as NSString).expandingTildeInPath
        let size: String
        if appBuilt { size = "16 GB" } else { size = sizeText(gamePath) }
        let lang = Language.all.first { $0.code == s.language }?.name ?? s.language
        let status: Status = busy != nil ? .building : (appBuilt ? .built : .notBuilt)
        return Entry(title: "塞尔达传说 王国之泪", subtitle: "The Legend of Zelda: Tears of the Kingdom  ·  \(titleID)",
                     version: gameVersion, language: lang, size: size, path: gamePath, status: status)
    }

    var appIcon: NSImage? {
        if isDemoMode { return nil }   // demo screenshots must not carry the game's artwork
        for name in ["AppIcon.icns", "AppIcon.png"] {
            if let img = NSImage(contentsOfFile: s.outputApp + "/Contents/Resources/" + name) { return img }
        }
        return nil
    }

    var shaderDir: URL { Paths.support.appendingPathComponent("shader-cache/rt-totk-native-v4-unverified") }

    func refreshShaderStats() {
        if isDemoMode { return }
        let dir = shaderDir
        Task.detached {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let src = names.filter { $0.hasSuffix(".metal") }.count
            let baked = names.filter { $0.hasSuffix(".metallib") }.count
            await MainActor.run { self.shaderSources = src; self.shaderBaked = baked }
        }
    }

    func bake() {
        guard busy == nil else { return }
        let script = s.projectDir + "/games/totk/tools/bake_metallibs.py"
        guard FileManager.default.fileExists(atPath: script) else { notice = "找不到烘焙脚本，请先安装构建工具。"; return }
        busy = "烘焙着色器"; progress = 0; step = "预编译着色器库"; log = ""
        let dir = shaderDir.path
        Task {
            let status = await runStreaming("/opt/homebrew/bin/python3.14 -I '\(script)' '\(dir)' -j 8") { text in
                Task { @MainActor in
                    self.log += text
                    if let m = lastMatch(#"(\d+)/(\d+)\s+\d+s"#, in: text), let a = Double(m[1]), let b = Double(m[2]), b > 0 {
                        self.progress = a / b; self.step = "预编译着色器库 \(m[1]) / \(m[2])"
                    }
                }
            }
            busy = nil; progress = nil; step = ""
            notice = status == 0 ? "着色器预编译完成。" : "烘焙没有完全成功，请查看日志（需要先安装 Metal Toolchain）。"
            refreshShaderStats()
        }
    }

    func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func addGame(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "xci" || ext == "nsp" { s.game = url.path }
        else if ext == "nsz" { s.update = url.path }
        else if url.lastPathComponent == "prod.keys" { s.keys = url.path }
    }
}

// MARK: - Theme and small views

enum Theme {
    static let bg = Color(red: 0.105, green: 0.115, blue: 0.13)
    static let panel = Color(red: 0.145, green: 0.158, blue: 0.178)
    static let line = Color.white.opacity(0.08)
}
let accent = Color(red: 0.20, green: 0.70, blue: 0.62)

struct TagView: View {
    enum Kind { case required, optional, inactive }
    let kind: Kind
    var body: some View {
        let (text, color): (String, Color) = switch kind {
        case .required: ("必填", accent)
        case .optional: ("可选", .secondary)
        case .inactive: ("暂不生效", .orange)
        }
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct Chip: View {
    let text: String, ok: Bool?
    var body: some View {
        HStack(spacing: 4) {
            if let ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? accent : .red) }
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

struct PathRow: View {
    let title: String
    let tag: TagView.Kind
    @Binding var value: String
    let check: Check
    let pickAction: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) { Text(title).font(.system(size: 13, weight: .medium)); TagView(kind: tag) }
            HStack(spacing: 8) {
                TextField("选择…", text: $value).textFieldStyle(.roundedBorder).font(.system(size: 12))
                Button("选择…", action: pickAction)
            }
            switch check {
            case .empty: EmptyView()
            case .ok(let t): Label(t, systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(accent)
            case .bad(let t): Label(t, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }
}

struct DepRow: View {
    let dep: Dep
    let install: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch dep.state {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                case .missing: Image(systemName: dep.required ? "xmark.circle.fill" : "circle.dashed").foregroundStyle(dep.required ? .red : .secondary)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .checking, .installing: ProgressView().controlSize(.small)
                }
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dep.title).font(.system(size: 13, weight: .medium))
                    TagView(kind: dep.required ? .required : .optional)
                    if let size = dep.size { Text(size).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                if case .installing(let p) = dep.state {
                    if let p { ProgressView(value: p).tint(accent).frame(maxWidth: 300) } else { Text("正在安装…").font(.system(size: 11)).foregroundStyle(.secondary) }
                } else if case .failed(let why) = dep.state {
                    Text(why).font(.system(size: 11)).foregroundStyle(.orange)
                } else {
                    Text(dep.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if dep.state == .missing || { if case .failed = dep.state { return true }; return false }() {
                if case .none = dep.install {} else { Button("安装", action: install).controlSize(.small) }
            }
        }
    }
}

struct IconView: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFill() }
            else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.07, green: 0.27, blue: 0.33), Color(red: 0.14, green: 0.55, blue: 0.52)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "play.fill").font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(.white.opacity(0.95))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
    }
}

struct ToolLabel: View {
    let icon: String, text: String
    var enabled = true
    var badge = false
    @State private var hover = false
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).frame(height: 22)
            Text(text).font(.system(size: 10.5))
        }
        .frame(width: 58, height: 46)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.45))
        .background(hover && enabled ? Color.white.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(alignment: .topTrailing) { if badge { Circle().fill(.red).frame(width: 7, height: 7).offset(x: -11, y: 6) } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct ToolButton: View {
    let icon: String, text: String
    var enabled = true
    var badge = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { ToolLabel(icon: icon, text: text, enabled: enabled, badge: badge) }
            .buttonStyle(.plain).disabled(!enabled)
    }
}

// MARK: - Main window (game library)

struct MainView: View {
    @ObservedObject var model: Model
    var snapshot = false
    @State private var query = ""
    @State private var grid = false
    @State private var showLog = false
    @State private var selected = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            if !model.blockers.isEmpty && model.entry != nil && !model.appBuilt { warningBar }
            library
            if showLog { logDrawer }
            statusBar
        }
        .ignoresSafeArea(edges: .top)
        .frame(width: snapshot ? 1000 : nil, height: snapshot ? 640 : nil)
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 560, idealHeight: 640)
        .background(Theme.bg)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.addGame(from: url) } }
                }
            }
            return true
        }
        .task {
            if !snapshot {
                model.refreshDeps(); model.refreshShaderStats()
                if CommandLine.arguments.contains("--open-settings") {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            if !snapshot, let i = CommandLine.arguments.firstIndex(of: "--selfshot"), let dir = CommandLine.arguments[safe: i + 1] {
                // Documentation screenshots: each window renders itself, so it does not matter where Stage Manager parked it.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(nanoseconds: 600_000_000)
                if let item = NSApp.mainMenu?.items.compactMap({ $0.submenu }).flatMap({ $0.items }).first(where: { $0.keyEquivalent == "," }) {
                    NSApp.sendAction(item.action!, to: item.target, from: item)   // the same path as pressing Command-comma
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for w in NSApp.windows {
                    guard w.isVisible, let frameView = w.contentView?.superview, w.frame.width > 300 else { continue }
                    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    let kind = w.frame.width >= 900 ? "main" : "settings"
                    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: "\(dir)/\(kind).png")) }
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: toolbar

    var toolbar: some View {
        HStack(spacing: 4) {
            ToolButton(icon: "play.fill", text: "启动", enabled: model.appBuilt && !model.launching && model.busy == nil) { model.launch() }
            ToolButton(icon: "hammer.fill", text: model.appBuilt ? "重建" : "构建", enabled: model.busy == nil && model.blockers.isEmpty) { model.build() }
            ToolButton(icon: "square.and.arrow.down", text: "导入存档", enabled: { if case .ok = model.check(.save) { return true }; return false }()) { model.importSave() }
            ToolButton(icon: "text.alignleft", text: "日志") { withAnimation { showLog.toggle() } }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("搜索游戏", text: $query).textFieldStyle(.plain).font(.system(size: 12.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 190)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Picker("", selection: $grid) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 84).padding(.leading, 8)
            SettingsLink { ToolLabel(icon: "gearshape", text: "设置", badge: !model.blockers.isEmpty) }.buttonStyle(.plain)
        }
        .padding(.leading, snapshot ? 14 : 84).padding(.trailing, 14).padding(.bottom, 8).padding(.top, snapshot ? 8 : 6)
        .background(Theme.panel)
    }

    var warningBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("还缺：" + model.blockers.joined(separator: "、")).font(.system(size: 12))
            Spacer()
            SettingsLink { Text("打开设置").font(.system(size: 12, weight: .medium)).foregroundStyle(accent) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: library

    var library: some View {
        Group {
            if let e = model.entry {
                let visible = query.isEmpty || (e.title + e.subtitle).localizedCaseInsensitiveContains(query)
                if !visible { placeholder(icon: "magnifyingglass", text: "没有匹配“\(query)”的游戏") }
                else if grid { gridView(e) } else { listView(e) }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc").font(.system(size: 38, weight: .light)).foregroundStyle(accent)
            Text("把游戏文件拖到这里").font(.system(size: 17, weight: .semibold))
            Text("支持 .xci / .nsp（基础版 1.0.0）。你需要自己的游戏文件、prod.keys 和固件。").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("选择游戏文件…") { if let p = model.pick(directory: false, extensions: ["xci", "nsp"], title: "选择游戏本体") { model.s.game = p } }
                    .buttonStyle(.borderedProminent).tint(accent)
                SettingsLink { Text("打开设置") }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).padding(24))
    }

    // columns shared by header and rows
    let wVersion: CGFloat = 80, wLang: CGFloat = 96, wStatus: CGFloat = 104, wSize: CGFloat = 80

    func listView(_ e: Model.Entry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("游戏").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 70)
                Text("版本").frame(width: wVersion, alignment: .leading)
                Text("语言").frame(width: wLang, alignment: .leading)
                Text("状态").frame(width: wStatus, alignment: .leading)
                Text("大小").frame(width: wSize, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 7)
            .background(Theme.panel.opacity(0.7))
            Rectangle().fill(Theme.line).frame(height: 1)

            HStack(spacing: 14) {
                IconView(image: model.appIcon, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(e.title).font(.system(size: 14.5, weight: .semibold))
                    Text(e.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(e.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10.5)).foregroundStyle(.secondary.opacity(0.7)).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(e.version).font(.system(size: 12.5)).frame(width: wVersion, alignment: .leading)
                Text(e.language).font(.system(size: 12.5)).frame(width: wLang, alignment: .leading)
                statusPill(e.status).frame(width: wStatus, alignment: .leading)
                Text(e.size).font(.system(size: 12.5)).foregroundStyle(.secondary).frame(width: wSize, alignment: .trailing)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(selected ? accent.opacity(0.20) : Color.clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(accent).frame(width: 3) } }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if model.appBuilt { model.launch() } else if model.blockers.isEmpty { model.build() } }
            .onTapGesture { selected = true }
            .contextMenu {
                Button("启动游戏") { model.launch() }.disabled(!model.appBuilt)
                Button(model.appBuilt ? "重新构建" : "构建 App") { model.build() }.disabled(!model.blockers.isEmpty)
                Divider()
                Button("在访达中显示 App") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.s.outputApp)]) }.disabled(!model.appBuilt)
                Button("打开存档文件夹") { model.openFolder(Paths.support.appendingPathComponent("profile/save")) }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            Spacer(minLength: 0)
        }
    }

    func gridView(_ e: Model.Entry) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 220), spacing: 20)], spacing: 20) {
                VStack(spacing: 10) {
                    IconView(image: model.appIcon, size: 128)
                    Text(e.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) { Text(e.version).font(.system(size: 11)).foregroundStyle(.secondary); statusPill(e.status) }
                }
                .padding(18).frame(maxWidth: .infinity)
                .background(selected ? accent.opacity(0.20) : Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? accent : Theme.line))
                .onTapGesture(count: 2) { if model.appBuilt { model.launch() } else if model.blockers.isEmpty { model.build() } }
                .onTapGesture { selected = true }
            }
            .padding(24)
        }
    }

    func statusPill(_ s: Model.Status) -> some View {
        let (t, c): (String, Color) = switch s {
        case .built: ("可启动", accent)
        case .building: ("构建中", .orange)
        case .notBuilt: ("未构建", .secondary)
        }
        return HStack(spacing: 5) { Circle().fill(c).frame(width: 7, height: 7); Text(t).font(.system(size: 12)) }
    }

    var logDrawer: some View {
        ScrollView { Text(model.log.isEmpty ? "（还没有日志）" : model.log).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            .frame(height: 150).padding(10)
            .background(Color.black.opacity(0.28))
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: status bar

    var statusBar: some View {
        let i = model.info
        return HStack(spacing: 14) {
            HStack(spacing: 8) {
                if let p = model.progress {
                    ProgressView(value: p).tint(accent).frame(width: 150)
                    Text(model.step).font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else if model.launching {
                    ProgressView().controlSize(.small)
                    Text(model.notice ?? "正在启动…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    Text(model.notice ?? (model.entry == nil ? "把 .xci / .nsp 拖进来开始" : (model.appBuilt ? "就绪" : "还没有构建"))).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            statusItem("macOS 26+", detail: i.macOS, ok: i.major >= 26)
            statusItem("Metal 4", detail: i.metal4 ? "支持" : "不支持", ok: i.metal4)
            statusItem(i.family.map { "M\($0)" } ?? "Apple 芯片", detail: "\(i.memGB) GB", ok: i.arm64 && i.memGB >= 16 ? true : (i.arm64 ? nil : false))
        }
        .padding(.horizontal, 16).frame(height: 30)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    func statusItem(_ title: String, detail: String, ok: Bool?) -> some View {
        HStack(spacing: 4) {
            if let ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? accent : .red).font(.system(size: 11)) }
            else { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.system(size: 11)) }
            Text(title).font(.system(size: 11.5, weight: .medium))
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings window (tabs)

struct SettingsView: View {
    @ObservedObject var model: Model
    @State var tab = Model.initialTab
    @State private var advanced = false

    var body: some View {
        TabView(selection: $tab) {
            filesTab.tabItem { Label("游戏文件", systemImage: "folder") }.tag(0)
            systemTab.tabItem { Label("系统", systemImage: "cpu") }.tag(1)
            graphicsTab.tabItem { Label("图形", systemImage: "display") }.tag(2)
            envTab.tabItem { Label("环境", systemImage: "wrench.and.screwdriver") }.tag(3)
            extrasTab.tabItem { Label("存档与 Mods", systemImage: "tray.and.arrow.down") }.tag(4)
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }.tag(5)
        }
        .frame(width: 640, height: 470)
        .background(Theme.bg)
        .onAppear { model.refreshDeps(); model.refreshShaderStats() }
    }

    func pane<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) { c() }.padding(22).frame(maxWidth: .infinity, alignment: .leading) }
    }

    var filesTab: some View {
        pane {
            PathRow(title: "游戏本体（XCI / NSP）", tag: .required, value: $model.s.game, check: model.check(.game)) {
                if let p = model.pick(directory: false, extensions: ["xci", "nsp"], title: "选择游戏本体") { model.s.game = p }
            }
            PathRow(title: "prod.keys", tag: .required, value: $model.s.keys, check: model.check(.keys)) {
                if let p = model.pick(directory: false, extensions: ["keys"], title: "选择 prod.keys") { model.s.keys = p }
            }
            PathRow(title: "固件（文件夹或 .zip）", tag: .required, value: $model.s.firmware, check: model.check(.firmware)) {
                if let p = model.pick(directory: true, extensions: ["zip"], title: "选择固件") { model.s.firmware = p }
            }
            PathRow(title: "更新包（1.1.2 / 1.4.3，NSP 或 NSZ）", tag: .optional, value: $model.s.update, check: model.check(.update)) {
                if let p = model.pick(directory: false, extensions: ["nsp", "nsz"], title: "选择更新包") { model.s.update = p }
            }
            DisclosureGroup("高级：输出位置", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 10) {
                    labeled("构建工具目录", $model.s.projectDir)
                    labeled("生成的 App", $model.s.outputApp)
                    labeled("构建缓存目录", $model.s.workDir)
                }.padding(.top, 8)
            }.font(.system(size: 12))
        }
    }

    func labeled(_ title: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", text: binding).textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }

    var systemTab: some View {
        let i = model.info
        return pane {
            HStack(spacing: 8) {
                Text("游戏语言").font(.system(size: 13, weight: .medium)); TagView(kind: .required)
                Spacer()
                Picker("", selection: $model.s.language) { ForEach(Language.all) { Text($0.name).tag($0.code) } }.labelsHidden().frame(width: 190)
            }
            Divider()
            Text("这台 Mac").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                GridRow { Text("系统").foregroundStyle(.secondary); Text("macOS \(i.macOS)（\(i.build)）") }
                GridRow { Text("芯片").foregroundStyle(.secondary); Text("\(i.chip)\(i.family.map { " · M\($0) 系列" } ?? "")") }
                GridRow { Text("内存").foregroundStyle(.secondary); Text("\(i.memGB) GB") }
                GridRow { Text("图形").foregroundStyle(.secondary); HStack(spacing: 6) { Chip(text: "Metal 3", ok: i.metal3); Chip(text: "Metal 4", ok: i.metal4) } }
                GridRow { Text("机型").foregroundStyle(.secondary); Text(i.model) }
            }.font(.system(size: 13))
            Divider()
            Text("运行要求").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                requirement("macOS 26 或更新", ok: i.major >= 26, now: "当前 \(i.macOS)")
                requirement("Metal 4", ok: i.metal4, now: i.metal4 ? "已支持" : "不支持")
                requirement("Apple 芯片（M1–M5）", ok: i.arm64, now: i.family.map { "M\($0) 系列" } ?? i.chip)
                requirement("建议 16 GB 或更多内存", ok: i.memGB >= 16, now: "当前 \(i.memGB) GB")
            }
        }
    }

    func requirement(_ text: String, ok: Bool, now: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? accent : .red)
            Text(text).font(.system(size: 13))
            Spacer()
            Text(now).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    var graphicsTab: some View {
        pane {
            Text("预编译着色器").font(.system(size: 13, weight: .semibold))
            Text("把游戏的着色器提前编译成文件保存在本机，不依赖系统缓存。系统缓存被清掉时，预热也只要几秒，而不是几分钟。").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) { Text("\(model.shaderSources)").font(.system(size: 24, weight: .semibold)); Text("着色器源码").font(.system(size: 11)).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 2) { Text("\(model.shaderBaked)").font(.system(size: 24, weight: .semibold)).foregroundStyle(model.shaderBaked >= model.shaderSources && model.shaderSources > 0 ? accent : .primary); Text("已预编译").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if let toolchain = model.deps.first(where: { $0.id == "metal" }), toolchain.state != .ok {
                Label("需要先安装 Metal Toolchain（839 MB），在“环境”页里安装。", systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack {
                Button { model.bake() } label: { Label(model.busy == "烘焙着色器" ? "烘焙中…" : "烘焙缺少的着色器", systemImage: "bolt.fill") }
                    .buttonStyle(.borderedProminent).tint(accent)
                    .disabled(model.busy != nil || model.deps.first(where: { $0.id == "metal" })?.state != .ok)
                Button("打开着色器缓存文件夹") { model.openFolder(model.shaderDir) }
            }
            if let p = model.progress, model.busy == "烘焙着色器" { ProgressView(value: p).tint(accent); Text(model.step).font(.system(size: 11)).foregroundStyle(.secondary) }
            Divider()
            Text("画质模式").font(.system(size: 13, weight: .semibold))
            Text("游戏窗口里按 3 切换：MetalFX 2K → 原生 2K → 关闭。按 1 显示 / 隐藏帧率等信息，按 2 切换补帧。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    var envTab: some View {
        pane {
            HStack { Text("运行环境").font(.system(size: 13, weight: .semibold)); Spacer(); Button("重新检查") { model.refreshDeps() }.controlSize(.small) }
            ForEach(model.deps) { dep in DepRow(dep: dep) { model.install(dep.id) } }
            Text("每一项都要你点“安装”才会执行。Homebrew 和命令行工具需要密码，会在“终端”里打开命令。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    var extrasTab: some View {
        pane {
            PathRow(title: "存档", tag: .optional, value: $model.s.save, check: model.check(.save)) {
                if let p = model.pick(directory: true, title: "选择存档文件夹") { model.s.save = p }
            }
            HStack {
                Button("导入存档到游戏…") { model.importSave() }.disabled({ if case .ok = model.check(.save) { return false }; return true }())
                Button("打开游戏存档文件夹") { model.openFolder(Paths.support.appendingPathComponent("profile/save")) }
            }
            Text("导入前会自动备份现有存档。第一次需要先启动一次游戏，让它创建存档目录。").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 6) { Text("Mods").font(.system(size: 13, weight: .medium)); TagView(kind: .inactive) }
            HStack(spacing: 8) {
                TextField("选择…", text: $model.s.mods).textFieldStyle(.roundedBorder).font(.system(size: 12))
                Button("选择…") { if let p = model.pick(directory: true, title: "选择 Mods 文件夹") { model.s.mods = p } }
            }
            Text("当前版本的游戏运行时还没有 Mods 加载器，这里的路径只会被保存，不会被应用。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    var aboutTab: some View {
        pane {
            HStack(spacing: 14) {
                IconView(image: model.appIcon, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("王国之泪 启动器").font(.system(size: 18, weight: .bold))
                    Text("版本 1.0 · 需要 macOS 26+ 与 Metal 4").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("这个启动器只负责检测环境、调用构建脚本、导入存档和启动游戏。游戏本体、密钥和固件都必须是你自己的，启动器不包含任何游戏内容。").font(.system(size: 12)).foregroundStyle(.secondary)
            Link("构建工具：MacNativeGames（GitHub）", destination: URL(string: "https://github.com/ly05010419/MacNativeGames")!).font(.system(size: 12))
        }
    }
}

// MARK: - App

@main
struct LauncherApp: App {
    @StateObject private var model = Model()

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let out = args[i + 1]
            MainActor.assumeIsolated {
                let m = Model()
                _ = NSApplication.shared
                if args.contains("--demo") { m.demo() }
                let tab = args.firstIndex(of: "--settings").flatMap { Int(args[safe: $0 + 1] ?? "0") }
                let root: AnyView = tab != nil ? AnyView(SettingsView(model: m, tab: tab!)) : AnyView(MainView(model: m, snapshot: true))
                let host = NSHostingView(rootView: root.preferredColorScheme(.dark))
                let size = tab != nil ? NSSize(width: 640, height: 470) : NSSize(width: 1000, height: 640)
                let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: .darkAqua)
                win.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.9))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("王国之泪 启动器") {
            MainView(model: model).preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandMenu("操作") {
                Button("启动游戏") { model.launch() }.keyboardShortcut("l").disabled(!model.appBuilt)
                Button(model.appBuilt ? "重新构建" : "构建 App") { model.build() }.keyboardShortcut("b").disabled(model.busy != nil || !model.blockers.isEmpty)
                Button("导入存档…") { model.importSave() }.keyboardShortcut("i")
            }
            CommandMenu("工具") {
                Button("重新检查环境") { model.refreshDeps() }
                Button("烘焙着色器缓存") { model.bake() }
                Divider()
                Button("打开游戏存档文件夹") { model.openFolder(Paths.support.appendingPathComponent("profile/save")) }
                Button("打开着色器缓存文件夹") { model.openFolder(model.shaderDir) }
                Button("打开日志文件") { NSWorkspace.shared.open(Paths.log) }
            }
            CommandGroup(replacing: .help) {
                Link("构建工具主页（GitHub）", destination: URL(string: "https://github.com/ly05010419/MacNativeGames")!)
            }
        }
        Settings { SettingsView(model: model).preferredColorScheme(.dark) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension Model {
    /// Fixed sample data for the layout snapshot only.
    func demo() {
        s.game = "~/Games/Switch/TOTK/xci/TOTK [0100F2C0115B6000][v0].xci"
        s.keys = "~/Games/Switch/Keys/prod.keys"
        s.firmware = "~/Games/Switch/Firmware"
        s.update = "~/Games/Switch/TOTK/nsp/TOTK v1.4.3 [0100F2C0115B6800][UPD].nsp"
        s.save = ""
        s.projectDir = "~/Sites/MacNativeGames"
        s.outputApp = "~/Games/Switch/TOTK/Tears of the Kingdom.app"
        deps = Model.makeDeps(project: s.projectDir)
        for i in deps.indices { deps[i].state = .ok }
        shaderSources = 8652; shaderBaked = 8652
    }
}
