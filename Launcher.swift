import SwiftUI
import AppKit
import Metal
import Foundation

// MARK: - Paths and settings

/// `--demo`: fixed sample data for documentation screenshots; never reads or writes the real settings.
let isDemoMode = CommandLine.arguments.contains("--demo")
/// `--snapshot <png>`: renders one window and exits; nothing is probed or installed.
let isSnapshot = CommandLine.arguments.contains("--snapshot")

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let launcher = home.appendingPathComponent("Library/Application Support/MacNativeGames/sw-launcher")
    static let config = launcher.appendingPathComponent("launcher.json")
    /// v1.0.1 (王国之泪启动器) kept its settings here; read once to migrate, never written.
    static let legacyConfig = home.appendingPathComponent("Library/Application Support/MacNativeGames/TOTK/launcher.json")
    static let cleanKeys = launcher.appendingPathComponent("prod.keys")
    /// The Python environment of nxnative's build scripts.
    static let nxVenv = launcher.appendingPathComponent("nx-venv")
    /// eShop icons, 256 px, by title ID.
    static let covers = home.appendingPathComponent("Library/Caches/sw-launcher/covers")
}

/// A JPEG of `data` (any image) scaled to fit `side` pixels.
func thumbnailJPEG(_ data: Data, side: Int) -> Data? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                kCGImageSourceThumbnailMaxPixelSize: side,
                                                                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
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
    static func of(_ i: SysInfo, backend: Backend = .macnative) -> Verdict {
        var level = Level.ok; var why: [String] = []
        func raise(_ l: Level, _ t: String) { why.append(t); if l == .bad || (l == .warn && level == .ok) { level = l } }
        if !i.arm64 { raise(.bad, "需要 Apple 芯片（M1–M5）的 Mac") }
        if backend == .macnative {
            if i.major < 26 { raise(.bad, "游戏核心需要 macOS 26 或更新（使用 Metal 4）；启动器本身支持 macOS 15 及以上") }
            else if !i.metal4 { raise(.bad, "这台机器的 Metal 不支持 Metal 4") }
        } else if i.major < 26 {   // nxnative: Apple silicon is the hard requirement; the current Xcode and its Metal Toolchain want macOS 26
            raise(.warn, "构建需要当前版本的 Xcode 和 Metal Toolchain，建议 macOS 26 或更新")
        }
        if i.memGB > 0 && i.memGB < 16 { raise(.warn, "内存 \(i.memGB) GB 偏低，建议 16 GB 或更多") }
        if why.isEmpty { why = [backend == .macnative ? "满足运行要求：Apple 芯片、macOS 26+、Metal 4" : "满足运行要求：Apple 芯片"] }
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

enum Field { case game, update, dlc, keys, firmware, save }
enum Check { case empty, ok(String), bad(String) }

@MainActor
final class Model: ObservableObject {
    @Published var s = LauncherSettings.load(from: Paths.config, legacy: Paths.legacyConfig, home: Paths.home) {
        didSet {
            if !isDemoMode { s.write(to: Paths.config) }
            if s.selected.backend != oldValue.selected.backend { refreshDeps() }   // each backend has its own list of requirements
            if s.network != oldValue.network { Model.autoTried.removeAll(); refreshDeps() }   // other download sources: worth another try
            if s.showCovers != oldValue.showCovers { coverRequested.removeAll(); if !s.showCovers { covers = [:] } }
        }
    }
    /// Folders of the selected game.
    var paths: GamePaths { GamePaths(s.selected, home: Paths.home) }
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
    @Published var modList: [ModInfo] = []
    @Published var modWarnings: [String] = []
    /// Game pictures loaded so far, by title ID (from the extraction or the eShop cache).
    @Published var covers: [String: NSImage] = [:]
    private var coverRequested: Set<String> = []
    /// The system proxy, passed on to every installer and build (an app opened from Finder does not pass it by itself).
    @Published var proxyEnv: [String: String] = [:]
    /// Whether PyPI and GitHub answered quickly; probed once at start, before anything is installed automatically.
    @Published var officialFast = true
    @Published var netChecked = false

    static let initialTab: Int = {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--tab").flatMap { Int(a[safe: $0 + 1] ?? "0") } ?? 0
    }()

    init() {
        if !isDemoMode {
            let own = ProcessInfo.processInfo.environment.filter { ["http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains($0.key.lowercased()) }
            proxyEnv = systemProxyEnvironment(scutil: sh("/usr/sbin/scutil --proxy").out).merging(own) { $1 }
        }
        deps = Model.makeDeps(project: s.projectDir, nxDir: s.nxDir, backend: s.selected.backend, mirror: mirror)
        if !isDemoMode { refreshCatalog() }
        if !isDemoMode && !isSnapshot { probeNetwork() }
        if isDemoMode { demo() }
    }

    /// nxnative's own profiles (a checked-out repository) add games and versions the built-in list does not have.
    func refreshCatalog() {
        GameCatalog.merge(gamesDir: URL(fileURLWithPath: (s.nxDir as NSString).expandingTildeInPath).appendingPathComponent("dm/games"))
        objectWillChange.send()
    }

    /// The build tool is pinned to the upstream commit the compatibility patch was made and tested against.
    static let baseCommit = "41e1e0caf43d58c4af3c478ca2d1bafd9dba7093"
    /// Applied in this order on top of baseCommit: the Mac fixes of v1.0, then the BOTW port and RomFS mods (sw-port.patch).
    nonisolated static var patchPaths: [String] { ["totk-mac-fixes", "sw-port"].map { Bundle.main.path(forResource: $0, ofType: "patch") ?? "" } }

    static func projectInstallCommand(_ project: String, mirror: Bool = false) -> String {
        installCommand(project: project, baseCommit: baseCommit, patches: patchPaths, mirror: mirror)
    }

    // MARK: network

    var hasProxy: Bool { proxyEnv.keys.contains { $0.lowercased() != "no_proxy" } }
    var mirror: Bool { useMirrors(s.network, proxy: hasProxy, officialFast: officialFast) }
    var netEnv: [String: String] { networkEnvironment(mirror: mirror, proxy: proxyEnv) }
    var netSummary: String {
        let proxy = proxyEnv["https_proxy"] ?? proxyEnv["http_proxy"] ?? proxyEnv["all_proxy"]
        let found = proxy.map { "检测到代理 \($0.replacingOccurrences(of: "http://", with: ""))" } ?? "没有检测到代理"
        switch s.network {
        case .direct: return found + "；按设置使用官方源"
        case .mirror: return found + "；按设置使用国内镜像（清华 TUNA、中科大、ghfast）"
        case .auto:
            if !netChecked { return found + "；正在测试官方源速度…" }
            if !hasProxy { return found + "，使用国内镜像（清华 TUNA、中科大、ghfast）" }
            return officialFast ? found + "，官方源速度正常，使用官方源" : found + "，但官方源响应慢，改用国内镜像"
        }
    }

    func probeNetwork() {
        let env = proxyEnv
        Task.detached {
            let fast = sh(exportLine(env) + officialSourcesProbe()).status == 0
            await MainActor.run { self.officialFast = fast; self.netChecked = true; self.refreshDeps() }
        }
    }

    static func makeDeps(project: String, nxDir: String, backend: Backend, mirror: Bool = false) -> [Dep] {
        let clt = Dep(id: "clt", title: "Xcode 命令行工具", detail: "编译游戏运行时所需", size: "约 1 GB", required: true, install: .terminal("xcode-select --install"))
        let brew = Dep(id: "brew", title: "Homebrew", detail: backend == .macnative ? "安装 Python 和音视频库" : "安装 Python、.NET 和构建工具", size: nil, required: true,
                       install: .terminal(brewInstallCommand(mirror: mirror)))
        let python = Dep(id: "python", title: "Python 3.14", detail: "运行构建脚本", size: "约 60 MB", required: true, install: .background("/opt/homebrew/bin/brew install python@3.14"))
        let xcode = Dep(id: "xcode", title: "Xcode（完整版）", detail: backend == .macnative ? "下载 Metal Toolchain 需要" : "构建着色器和主程序需要；装好后打开一次", size: "约 7 GB", required: backend == .nxnative,
                        install: .link("macappstore://apps.apple.com/app/xcode/id497799835"))
        let metal = Dep(id: "metal", title: "Metal Toolchain", detail: backend == .macnative ? "预编译着色器，缓存不会被系统清掉，启动快几十倍" : "编译游戏着色器需要（Xcode → 设置 → 组件 里也能装）", size: "839 MB",
                        required: backend == .nxnative, install: .background("xcodebuild -downloadComponent MetalToolchain"))
        switch backend {
        case .macnative:
            return [
                clt, brew, python,
                Dep(id: "libs", title: "opus 与 libvpx", detail: "游戏音频和过场视频解码", size: "约 10 MB", required: true, install: .background("/opt/homebrew/bin/brew install opus libvpx")),
                Dep(id: "project", title: "构建工具（MacNativeGames）", detail: project, size: "约 50 MB", required: true, install: .background(projectInstallCommand(project, mirror: mirror))),
                Dep(id: "patch", title: "Mac 兼容补丁与旷野之息移植", detail: "内存布局回退、并行预热、预编译着色器、语言设置；旷野之息移植和 Mods。已装过旧版构建工具时，点安装只补打缺少的补丁", size: nil, required: true,
                    install: .background(upgradeCommand(project: project, fresh: project + "-sw-launcher", baseCommit: baseCommit, patches: Model.patchPaths, mirror: mirror))),
                xcode, metal,
                Dep(id: "disk", title: "磁盘空间", detail: "构建需要约 25–40 GB 空闲", size: nil, required: true, install: .none),
            ]
        case .nxnative:
            return [
                clt, brew, python, xcode,
                Dep(id: "xcsel", title: "Xcode 已选用并同意许可", detail: "在“终端”里运行 sudo xcode-select -s 和 xcodebuild -license，需要你输入密码并自己阅读、同意许可", size: nil, required: true,
                    install: .terminal("sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license")),
                metal,
                Dep(id: "nxtools", title: "构建工具（git、zstd、spirv-cross、lz4、glslang）", detail: "解包、着色器翻译", size: "约 50 MB", required: true,
                    install: .background("/opt/homebrew/bin/brew install git zstd spirv-cross lz4 glslang")),
                Dep(id: "dotnet", title: ".NET SDK 10", detail: "读取游戏文件（nx_extract）；安装包需要你输入密码，会在“终端”里运行", size: "约 400 MB", required: true,
                    install: .terminal("/opt/homebrew/bin/brew install --cask dotnet-sdk")),
                Dep(id: "nxvenv", title: "Python 组件（capstone、fonttools、lz4、nsz）", detail: "装进启动器自己的环境，不改动系统 Python", size: "约 30 MB", required: true,
                    install: .background(nxVenvCommand(venv: Paths.nxVenv.path))),
                Dep(id: "nxrepo", title: "nxnative", detail: nxDir, size: "约 100 MB", required: true, install: .background(nxCloneCommand(dir: (nxDir as NSString).expandingTildeInPath, mirror: mirror))),
                Dep(id: "disk", title: "磁盘空间", detail: "构建需要约游戏大小的两倍再加 10 GB 空闲", size: nil, required: true, install: .none),
            ]
        }
    }

    func refreshDeps() {
        if isDemoMode { return }
        let project = s.projectDir, nxDir = (s.nxDir as NSString).expandingTildeInPath, venv = Paths.nxVenv.path
        let needGB = diskNeededGB
        // A new list starts at "checking": keep what is installing right now, so it is not shown as missing and started twice.
        let inFlight = Dictionary(uniqueKeysWithValues: deps.compactMap { d -> (String, Dep.State)? in
            if case .installing = d.state { return (d.id, d.state) }; return nil
        })
        deps = Model.makeDeps(project: project, nxDir: s.nxDir, backend: s.selected.backend, mirror: mirror)
        for i in deps.indices { if let st = inFlight[deps[i].id] { deps[i].state = st } }
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
                case "patch": results[id] = sh(patchCheckCommand(project: project, patches: Model.patchPaths)).status == 0
                case "xcode": results[id] = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
                case "xcsel": results[id] = sh("xcode-select -p 2>/dev/null | grep -q 'Xcode.app' && xcodebuild -version >/dev/null 2>&1").status == 0
                case "nxtools":
                    let fm = FileManager.default, bin = "/opt/homebrew/bin/"
                    results[id] = fm.fileExists(atPath: bin + "zstd") && fm.fileExists(atPath: bin + "spirv-cross") && (fm.fileExists(atPath: bin + "glslang") || fm.fileExists(atPath: bin + "glslangValidator"))
                case "dotnet": results[id] = sh("export PATH='\(nxToolPath(venv: venv))'; dotnet --list-runtimes 2>/dev/null | grep -q 'NETCore.App 10'").status == 0
                case "nxvenv": results[id] = sh(nxVenvCheckCommand(venv: venv)).status == 0
                case "nxrepo": results[id] = FileManager.default.fileExists(atPath: nxDir + "/scripts/build_ipa_from_nsp.py")
                case "metal": results[id] = sh("xcrun -sdk macosx metal --version >/dev/null 2>&1").status == 0
                case "disk":
                    let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    results[id] = (v?.volumeAvailableCapacityForImportantUsage ?? 0) > Int64(needGB) * 1_000_000_000
                default: break
                }
            }
            let final = results
            await MainActor.run {
                for i in self.deps.indices {
                    if case .installing = self.deps[i].state { continue }
                    self.deps[i].state = final[self.deps[i].id] == true ? .ok : .missing
                }
                self.autoInstallNext()
            }
        }
    }

    /// What a background installer needs installed first (Homebrew for its packages, Python for the environments, Xcode for the Metal Toolchain).
    static let prerequisites: [String: [String]] = [
        "python": ["brew"], "libs": ["brew"], "nxtools": ["brew"], "project": ["python", "clt"], "patch": ["project"],
        "nxvenv": ["python"], "nxrepo": ["clt"], "metal": ["xcode"],
    ]
    /// Requirements the auto-installer already started once this session: a failure is shown, not retried in a loop.
    private static var autoTried: Set<String> = []
    /// Background installers running now: one per requirement, whatever starts it (auto, one-click, a click).
    private static var running: Set<String> = []
    /// One-click install: keep going through the list even when automatic installs are off.
    private var forceAuto = false
    private var watchingManual = false

    var installingDep: Dep? { deps.first { if case .installing = $0.state { return true }; return false } }
    /// Missing requirements only the player can install (they need a password, the App Store or a license to read).
    var manualDeps: [Dep] {
        deps.filter { d in
            guard d.required, d.state == .missing else { return false }
            if case .terminal = d.install { return true }; if case .link = d.install { return true }; return false
        }
    }

    /// One missing requirement at a time, in list order, once its prerequisites are installed. Each finished install checks again and continues.
    func autoInstallNext() {
        guard s.autoInstall || forceAuto, netChecked, !isDemoMode, busy == nil, installingDep == nil else { return }
        let ok = Dictionary(uniqueKeysWithValues: deps.map { ($0.id, $0.state == .ok) })
        guard let next = deps.first(where: { d in
            guard d.required, d.state == .missing, !Model.autoTried.contains(d.id), case .background = d.install else { return false }
            return (Model.prerequisites[d.id] ?? []).allSatisfy { ok[$0] ?? true }
        }) else { return }
        Model.autoTried.insert(next.id)
        install(next.id)
    }

    /// Everything missing at once: the password installers in one Terminal window (one password), the App Store for Xcode, and the
    /// rest in the background, each as soon as what it needs is installed.
    func installAll() {
        Model.autoTried.removeAll()
        for i in deps.indices { if case .failed = deps[i].state { deps[i].state = .missing } }
        let ok = Dictionary(uniqueKeysWithValues: deps.map { ($0.id, $0.state == .ok) })
        let missing = deps.filter { $0.required && $0.state == .missing }
        var terminal: [String] = []
        for d in missing {
            switch d.install {
            case .terminal(let c):
                if d.id == "clt" && missing.contains(where: { $0.id == "brew" }) { continue }   // the Homebrew installer installs them itself
                if d.id == "xcsel" && ok["xcode"] != true { continue }   // needs Xcode first; offered again once it is installed
                terminal.append(c)
            case .link(let u): if let url = URL(string: u) { NSWorkspace.shared.open(url) }
            default: break
            }
        }
        if !terminal.isEmpty {
            openInTerminal(terminalInstallScript(terminal, exports: exportLine(netEnv)))
            watchManualInstalls()
        }
        forceAuto = true
        notice = terminal.isEmpty ? "正在后台安装缺少的组件…" : "需要密码的组件已在“终端”里开始安装（只输一次密码）；其余的在后台安装。"
        autoInstallNext()
    }

    /// While a Terminal installer runs: check again every 15 s (for up to 30 minutes) until nothing waits on the player.
    func watchManualInstalls() {
        guard !watchingManual else { return }
        watchingManual = true
        Task {
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                refreshDeps()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if manualDeps.isEmpty { break }
            }
            watchingManual = false
        }
    }

    func install(_ id: String) {
        guard let idx = deps.firstIndex(where: { $0.id == id }) else { return }
        switch deps[idx].install {
        case .terminal(let c):
            openInTerminal(terminalInstallScript([c], exports: exportLine(netEnv)))
            notice = "已在“终端”里打开安装命令，装完后启动器会自动重新检查。"
            watchManualInstalls()
        case .link(let u): if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case .none: break
        case .background(let cmd):
            guard !Model.running.contains(id) else { return }
            Model.running.insert(id)
            deps[idx].state = .installing(nil)
            let env = netEnv
            Task {
                var buffer = ""
                let status = await runStreaming(cmd, env: env) { text in
                    Task { @MainActor in
                        buffer += text; self.log += text
                        if let m = lastMatch(#"\(([0-9.]+) (?:MB|KB) of ([0-9.]+) MB downloaded\)"#, in: text),
                           let a = Double(m[1]), let b = Double(m[2]), b > 0, let j = self.deps.firstIndex(where: { $0.id == id }) {
                            self.deps[j].state = .installing(min(a / b, 1))
                        }
                    }
                }
                await MainActor.run {
                    Model.running.remove(id)
                    // The old build tool could not take the patches and a fresh one was installed next to it: use that one.
                    if status == 0, let m = lastMatch(NSRegularExpression.escapedPattern(for: freshToolMarker) + "(.+)", in: buffer) {
                        self.s.projectDir = m[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        self.notice = "原来的构建工具打不上新补丁，已在 \(self.s.projectDir) 装好一份新的，并改用它。"
                    }
                    if let j = self.deps.firstIndex(where: { $0.id == id }) {
                        self.deps[j].state = status == 0 ? .checking : .failed("安装没有成功，详情见日志")
                    }
                    if id == "nxrepo" && status == 0 { self.refreshCatalog() }
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
            case .dlc: return .empty
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
            if let info = s.selected.nxInfo { return checkNXFile(p, info: info, update: false) }
            if s.selected == .botw { return ext == "nsp" ? .ok(sizeText(p)) : .bad("请选择旷野之息基础版的 .nsp 文件") }
            return ["xci", "nsp"].contains(ext) ? .ok(sizeText(p)) : .bad("请选择 .xci 或 .nsp 文件（基础版 1.0.0）")
        case .update:
            guard !s.update.isEmpty else { return .empty }
            let p = path(s.update), ext = (p as NSString).pathExtension.lowercased()
            guard fm.fileExists(atPath: p) else { return .bad("找不到这个文件") }
            if let info = s.selected.nxInfo { return checkNXFile(p, info: info, update: true) }
            if s.selected == .botw { return ext == "nsp" ? .ok(sizeText(p)) : .bad("旷野之息需要 1.9.0 更新的 .nsp 文件") }
            guard ["nsp", "nsz"].contains(ext) else { return .bad("更新包应为 .nsp 或 .nsz") }
            if !needsUpdate { return .bad("选的是 1.0.0（本体），不需要更新包；要用它请改选对应版本") }
            if let v = updateVersion(s.selected, fileName: (p as NSString).lastPathComponent), v != version { return .bad("这是 \(v) 的更新包，所选版本是 \(version)") }
            return .ok(sizeText(p))
        case .dlc:
            guard !s.dlc.isEmpty else { return .empty }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path(s.dlc), isDirectory: &isDir), isDir.boolValue else { return .bad("请选择放 DLC 文件的文件夹") }
            let n = stageInputs(game: "", update: "", dlcFolder: s.dlc).count
            return n > 0 ? .ok("\(n) 个 DLC 文件") : .bad("文件夹里没有 .nsp / .nsz / .xci / .xcz 文件")
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
            if s.selected.backend == .nxnative {   // the layout of an nxnative save folder is the game's own: only check there is something to copy
                return items.contains { !$0.hasPrefix(".") } ? .ok("\(items.filter { !$0.hasPrefix(".") }.count) 项，会复制进游戏的 save 文件夹") : .bad("这个文件夹是空的")
            }
            return items.contains(where: { $0.hasPrefix("slot_") }) || items.contains("option.sav") ? .ok("\(items.filter { $0.hasPrefix("slot_") }.count) 个存档位") : .bad("没有找到 slot_00 之类的存档文件夹")
        }
    }

    /// An nxnative game file: the right game, a [v<N>] tag that nxnative can recognize as the update, and a version the profile registers.
    func checkNXFile(_ p: String, info: NXGameInfo, update: Bool) -> Check {
        let name = (p as NSString).lastPathComponent, ext = (p as NSString).pathExtension.lowercased()
        guard nxGameExtensions.contains(ext) else { return .bad("请选择 .nsp / .xci / .nsz / .xcz 文件") }
        let own = [info.id, String(format: "%016llX", (UInt64(info.id, radix: 16) ?? 0) + 0x800)]
        if let other = titleIDs(inFileName: name).first(where: { !own.contains($0) && (GameCatalog.nx[$0] != nil) }) {
            return .bad("这是《\(GameCatalog.nx[other]?.zh ?? GameCatalog.nx[other]?.name ?? other)》的文件")
        }
        let tag = versionTag(inFileName: name)
        if update {
            guard let tag else { return .bad("文件名里要有 [v版本号]（例如 [v\(info.package.dropFirst())]），否则 nxnative 不认这个更新") }
            if let shown = info.build(forTag: tag) {
                if !needsUpdate { return .bad("所选版本 \(version) 是本体，不需要更新包；这个更新包是 \(shown)") }
                return shown == version ? .ok("版本 \(shown)  ·  \(sizeText(p))") : .bad("这是 \(shown) 的更新包，所选版本是 \(version)")
            }
            return .bad("版本 v\(tag) 不在支持列表里（支持：\(info.displayVersions.joined(separator: "、"))）")
        }
        if let tag, tag != 0 { return .bad("文件名里的 [v\(tag)] 说明这是更新包，请放到“更新包”那一栏") }
        return .ok(sizeText(p))
    }

    /// Disk space the build needs: twice the game plus 10 GB for nxnative, 45 GB for the MacNativeGames build.
    var diskNeededGB: Int {
        if s.selected.backend == .macnative { return 45 }
        let size = ((try? FileManager.default.attributesOfItem(atPath: (s.game as NSString).expandingTildeInPath))?[.size] as? NSNumber)?.doubleValue ?? 0
        return max(30, Int(2 * size / 1_000_000_000) + 10)
    }

    func sizeText(_ p: String) -> String {
        let n = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.doubleValue ?? 0
        return String(format: "%.1f GB", n / 1_000_000_000)
    }

    var depsOK: Bool { deps.filter(\.required).allSatisfy { $0.state == .ok } }
    var verdict: Verdict { Verdict.of(info, backend: s.selected.backend) }
    /// The version the selected game is built at, and whether that needs an update file.
    var version: String { selectedVersion(s.selected, settings: s.current) }
    var needsUpdate: Bool { versionNeedsUpdate(s.selected, version: version) }
    var appBuilt: Bool { appBuilt(s.selected) }
    func appBuilt(_ g: GameKind) -> Bool {
        if isDemoMode { return g == .totk }
        let app = s.settings(for: g).outputApp as NSString
        return app.length > 0 && FileManager.default.fileExists(atPath: app.expandingTildeInPath + "/Contents/MacOS/" + g.executable)
    }

    var blockers: [String] {
        var out: [String] = []
        if verdict.level == .bad { out.append("系统不满足要求") }
        if case .ok = check(.game) {} else { out.append("游戏本体") }
        if case .ok = check(.keys) {} else { out.append("prod.keys") }
        if s.selected.backend == .macnative, case .ok = check(.firmware) {} else if s.selected.backend == .macnative { out.append("固件") }
        if needsUpdate, case .ok = check(.update) {} else if needsUpdate { out.append("\(version) 更新包") }
        if !needsUpdate, !s.update.isEmpty { out.append("移除更新包（所选版本是本体）") }
        if s.selected.backend == .nxnative, !s.dlc.isEmpty, case .bad = check(.dlc) { out.append("DLC 文件夹") }
        for d in deps where d.required && d.state != .ok { out.append(d.title) }
        return out
    }

    // MARK: language, save, build, launch

    func applyLanguage() {
        for g in GameKind.macnativeGames {   // the game reads <data folder>/language.txt
            let support = GamePaths(g, home: Paths.home).support
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try? (s.language + "\n").write(to: support.appendingPathComponent("language.txt"), atomically: true, encoding: .utf8)
        }
    }

    func importSave() {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: (s.save as NSString).expandingTildeInPath)
        if s.selected.backend == .nxnative { importNXSave(from: src); return }
        let root = paths.profileSave
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
        let backup = paths.support.appendingPathComponent("save-backup-\(stamp)")
        let r1 = sh("/usr/bin/ditto '\(target.path)' '\(backup.path)/\(target.lastPathComponent)'")
        let r2 = r1.status == 0 ? sh("/usr/bin/ditto '\(src.path)' '\(target.path)'") : r1
        notice = r2.status == 0 ? "存档已导入。原存档备份在 \(backup.lastPathComponent)。" : "导入失败：\(r2.out)"
    }

    /// nxnative keeps a game's save in <Application Support>/nxnative/<title ID>/save; the chosen folder's contents are copied over it.
    func importNXSave(from src: URL) {
        let target = paths.profileSave
        let alert = NSAlert()
        alert.messageText = "导入存档？"
        alert.informativeText = "会把所选文件夹里的内容复制到游戏的 save 文件夹，同名文件被覆盖。覆盖前会先备份现有存档。文件夹的结构要和 nxnative 的 save 一致。"
        alert.addButton(withTitle: "备份并导入"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = paths.support.appendingPathComponent("save-backup-\(stamp)")
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let r1 = sh("/usr/bin/ditto \(shQuote(target.path)) \(shQuote(backup.path))")
        let r2 = r1.status == 0 ? sh("/usr/bin/ditto \(shQuote(src.path)) \(shQuote(target.path))") : r1
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
        if s.selected.backend == .nxnative { buildNX(); return }
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
            var cmd = "/opt/homebrew/bin/python3.14 build_app.py --title \(s.selected.buildTitleArg) \(q(s.game)) -k \(q(keys)) --firmware \(q(firmware)) --work \(q(s.workDir)) -o \(q(s.outputApp))"
            if !s.update.isEmpty { cmd += " --update \(q(s.update))" }
            let status = await runStreaming(cmd, cwd: s.projectDir, env: netEnv.merging(["PIP_DEFAULT_TIMEOUT": "180", "PIP_RETRIES": "10"]) { $1 }) { text in
                Task { @MainActor in
                    self.log += text
                    if let m = lastMatch(#"(\d)/4 (\w+)"#, in: text), let n = Double(m[1]) {
                        self.progress = (n - 1) / 4
                        self.step = "第 \(m[1]) 步，共 4 步：" + (["code": "改写游戏代码", "data": "解密游戏数据", "update": "合并更新", "shaders": "准备着色器", "app": "生成 App"][m[2]] ?? m[2])
                    }
                }
            }
            busy = nil; progress = nil
            notice = status == 0 ? "构建完成，可以启动游戏了。第一次启动要编译着色器，会比之后慢一些。" : "构建没有成功，请展开下面的日志查看原因。"
            step = ""
        }
    }

    func launch() {
        guard !launching else { return }
        let game = s.selected
        switch runState(for: game, settings: s, home: Paths.home) {
        case .running(let pid):   // already running: bring it to the front, never start a second copy
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
            notice = "\(game.displayName) 已经在运行。"; return
        case .otherGameRunning(let other):
            notice = "另一款游戏（\(other.displayName)）正在运行，请先退出它。"; return
        case .idle: break
        }
        if game.backend == .nxnative { launchNX(game); return }
        applyLanguage()
        var problem = syncModsManifest()
        if FileManager.default.fileExists(atPath: paths.modsManifest.path),
           let info = NSDictionary(contentsOfFile: (s.outputApp as NSString).expandingTildeInPath + "/Contents/Info.plist") as? [String: Any],
           !appSupportsMods(info: info) {
            problem = "这个 App 是旧版启动器构建的，不会加载 Mods；重新构建一次后 Mods 才会生效。"
        }
        launching = true; notice = problem ?? "正在启动…"
        let app = (s.outputApp as NSString).expandingTildeInPath, log = paths.log
        Task {
            let (ok, failure) = await Task.detached { () -> (Bool, String?) in
                for attempt in 1...6 {
                    // A failed attempt exits by itself; wait until its slot is free instead of killing anything.
                    for _ in 0..<20 { if case .idle = runState(for: game, home: Paths.home) { break }; try? await Task.sleep(nanoseconds: 500_000_000) }
                    let before = fileIdentity(log)   // the game rotates its log on start: read only the new one
                    _ = sh("/usr/bin/open -n \(shQuote(app))")
                    var retry = false
                    for _ in 0..<40 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard let text = freshLog(log, notSameAs: before) else { continue }
                        if let message = launchFailure(log: text) { return (false, message) }   // retrying will not help
                        if text.contains("FAIL: reserve") { retry = true; break }   // address space was not free this time
                        if text.contains("window visible") || text.contains("启动关键管线已就绪") { return (true, nil) }
                    }
                    if !retry, case .running = runState(for: game, home: Paths.home) { return (true, nil) }   // still starting up
                    await MainActor.run { self.notice = "第 \(attempt) 次启动没成功，自动重试…" }
                }
                return (false, nil)
            }.value
            self.launching = false
            self.notice = ok ? (problem ?? "游戏已启动。") : (failure ?? "多次尝试仍未启动，请查看日志 ~/Library/Logs/MacNativeGames/\(game.logName).log")
        }
    }

    /// Finder save panel for an output path (an .app, .ipa or .xcworkspace); returns the chosen path.
    func pickSave(title: String, current: String) -> String? {
        let url = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
        let p = NSSavePanel()
        p.title = title; p.canCreateDirectories = true
        p.directoryURL = url.deletingLastPathComponent(); p.nameFieldStringValue = url.lastPathComponent
        return p.runModal() == .OK ? p.url?.path : nil
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
    enum Status { case built, building, notBuilt, notAdded }
    struct Entry {
        let kind: GameKind
        let title: String, subtitle: String, version: String, language: String, size: String, path: String
        let status: Status
    }

    /// The whole library: ready games first, then those with a game file, then the rest, each group in catalog order.
    var entries: [Entry] {
        let all = GameKind.all.map(entry)
        func rank(_ e: Entry) -> Int { switch e.status { case .built, .building: return 0; case .notBuilt: return 1; case .notAdded: return 2 } }
        return all.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    func entry(_ g: GameKind) -> Entry {
        let gs = s.settings(for: g)
        let gamePath = (gs.game as NSString).expandingTildeInPath
        let built = appBuilt(g)
        let lang = Language.all.first { $0.code == s.language }?.name ?? s.language
        let status: Status = gs.game.isEmpty && !built ? .notAdded : (busy != nil && g == s.selected ? .building : (built ? .built : .notBuilt))
        let fileSize = !gs.game.isEmpty && FileManager.default.fileExists(atPath: gamePath) ? sizeText(gamePath) : "—"
        let size = built && g.backend == .macnative ? (g == .totk ? "16 GB" : "15 GB") : fileSize
        let backend = g.backend == .nxnative ? "nxnative" : "MacNativeGames"
        return Entry(kind: g, title: g.displayName, subtitle: "\(g.englishName)  ·  \(g.titleID)  ·  \(backend)", version: gameVersion(g), language: lang,
                     size: size, path: gs.game.isEmpty ? "还没有选择游戏文件" : gamePath, status: status)
    }

    /// A built nxnative app carries the packed version in its Info.plist; otherwise the version chosen for the next build.
    func gameVersion(_ g: GameKind) -> String {
        let gs = s.settings(for: g)
        if g.backend == .nxnative, appBuilt(g), let d = NSDictionary(contentsOfFile: (gs.outputApp as NSString).expandingTildeInPath + "/Contents/Info.plist"),
           let v = d["CFBundleShortVersionString"] as? String { return v }
        return selectedVersion(g, settings: gs)
    }

    var appIcon: NSImage? { appIcon(s.selected) }
    func appIcon(_ g: GameKind) -> NSImage? {
        if isDemoMode { return nil }   // demo screenshots must not carry the game's artwork
        let app = (s.settings(for: g).outputApp as NSString).expandingTildeInPath
        for name in ["AppIcon.icns", "AppIcon.png"] {
            if let img = NSImage(contentsOfFile: app + "/Contents/Resources/" + name) { return img }
        }
        return nil
    }

    /// The game's picture: the built app's icon, else the icon nxnative extracted from the player's own file or the eShop icon.
    func cover(_ g: GameKind) -> NSImage? { appIcon(g) ?? covers[g.titleID] }

    /// Loads the game's picture once: the extracted icon, else the cached eShop icon, else downloads it (256 px) into the cache.
    func requestCover(_ g: GameKind) {
        let id = g.titleID
        guard !isDemoMode, covers[id] == nil, !coverRequested.contains(id), appIcon(g) == nil else { return }
        coverRequested.insert(id)
        let work = URL(fileURLWithPath: (s.settings(for: g).workDir as NSString).expandingTildeInPath)
        let cached = Paths.covers.appendingPathComponent(id + ".jpg")
        let remote = s.showCovers ? coverURLs[id].flatMap(URL.init(string:)) : nil
        Task.detached {
            let local = extractedIcon(workDir: work, titleID: id).flatMap(NSImage.init(contentsOf:))
                ?? (remote == nil ? nil : NSImage(contentsOf: cached))
            if let local { await MainActor.run { self.covers[id] = local }; return }
            guard let remote, let r = try? await URLSession.shared.data(from: remote), (r.1 as? HTTPURLResponse)?.statusCode == 200,
                  let small = thumbnailJPEG(r.0, side: 256), let img = NSImage(data: small) else { return }
            try? FileManager.default.createDirectory(at: Paths.covers, withIntermediateDirectories: true)
            try? small.write(to: cached, options: .atomic)
            await MainActor.run { self.covers[id] = img }
        }
    }

    var shaderDir: URL { paths.shaderDir }

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
        guard s.selected.backend == .macnative else { notice = "预编译烘焙只用于 MacNativeGames 的游戏；nxnative 在构建时已经编译好着色器。"; return }
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

    // MARK: mods

    var modsDir: URL? { s.mods.isEmpty ? nil : URL(fileURLWithPath: (s.mods as NSString).expandingTildeInPath) }

    func refreshMods() {
        modList = modsDir.map { orderedMods(scanMods(dir: $0, titleID: s.selected.titleID), order: s.current.modOrder) } ?? []
        let log = s.selected.backend == .macnative ? ((try? String(contentsOf: paths.log, encoding: .utf8)) ?? "") : ""
        modWarnings = parseModWarnings(log: log)
    }
    func modEnabled(_ name: String) -> Bool { s.current.modsEnabled[name] ?? true }
    func setMod(_ name: String, enabled: Bool) { s.current.modsEnabled[name] = enabled }
    func moveMod(_ name: String, by delta: Int) {
        var names = modList.map(\.name)
        guard let i = names.firstIndex(of: name), names.indices.contains(i + delta) else { return }
        names.swapAt(i, i + delta)
        s.current.modOrder = names
        refreshMods()
    }
    var modResolution: ModResolution { resolveMods(modList, order: s.current.modOrder, enabled: s.current.modsEnabled) }
    func conflictCount(_ name: String) -> Int { modResolution.conflicts.values.filter { $0.contains(name) }.count }

    /// Before each start: the selected game's <data>/mods.tsv from the enabled mods (removed when there are none).
    func syncModsManifest() -> String? {
        refreshMods()
        do {
            let skipped = try writeManifest(modsDir == nil ? ModResolution() : modResolution, to: paths.modsManifest)
            return skipped.isEmpty ? nil : "有 \(skipped.count) 个 mod 文件名里含制表符或换行，已跳过。"
        } catch { return "无法写入 Mods 清单：\(error.localizedDescription)" }
    }

    /// A dropped file: the game it belongs to is read from the title ID in its name (a base game, or its update at ID + 0x800).
    func addGame(from url: URL) {
        let ext = url.pathExtension.lowercased(), name = url.lastPathComponent
        if url.lastPathComponent == "prod.keys" { s.keys = url.path; return }
        guard nxGameExtensions.contains(ext) else { return }
        if let (game, isUpdate) = gameForFileName(name, current: s.selected) {
            s.selected = game
            if isUpdate { setUpdate(url.path) } else { s.game = url.path }
            return
        }
        // No known title ID in the name: the old rules for the selected game.
        if s.selected.backend == .nxnative { if s.game.isEmpty { s.game = url.path } else { setUpdate(url.path) } }
        else if ext == "xci" || ext == "nsp" { s.game = url.path }
        else if ext == "nsz" { setUpdate(url.path) }
    }

    /// A new update file also selects the version it brings the game to.
    func setUpdate(_ path: String) {
        s.update = path
        if let v = updateVersion(s.selected, fileName: (path as NSString).lastPathComponent), s.selected.supportedVersions.contains(v) { s.current.version = v }
    }

    /// The Finder panel for one of the selected game's files (or the shared prod.keys / firmware).
    func choose(_ f: Field) {
        let nx = s.selected.backend == .nxnative
        switch f {
        case .game: if let p = pick(directory: false, extensions: nx ? ["nsp", "xci", "nsz", "xcz"] : ["xci", "nsp"], title: "选择游戏本体") { s.game = p }
        case .update: if let p = pick(directory: false, extensions: ["nsp", "nsz"], title: "选择 \(version) 更新包") { setUpdate(p) }
        case .dlc: if let p = pick(directory: true, title: "选择放 DLC 文件的文件夹") { s.dlc = p }
        case .keys: if let p = pick(directory: false, extensions: ["keys"], title: "选择 prod.keys") { s.keys = p }
        case .firmware: if let p = pick(directory: true, extensions: ["zip"], title: "选择固件（文件夹或 .zip）") { s.firmware = p }
        case .save: if let p = pick(directory: true, title: "选择存档文件夹") { s.save = p }
        }
    }
}

// MARK: - nxnative: build, start, update

extension Model {
    /// Environment of every nxnative tool: the launcher's Python first, Homebrew and .NET on the PATH.
    nonisolated static var nxToolEnvironment: [String: String] {
        ["PATH": nxToolPath(venv: Paths.nxVenv.path), "PYTHONUNBUFFERED": "1", "DOTNET_CLI_TELEMETRY_OPTOUT": "1", "DOTNET_NOLOGO": "1",
         "PIP_DEFAULT_TIMEOUT": "180", "PIP_RETRIES": "10"]
    }

    func buildNX() {
        guard busy == nil, let info = s.selected.nxInfo else { return }
        busy = "构建中"; progress = 0; step = "准备"; log = ""
        let gs = s.current, nxDir = (s.nxDir as NSString).expandingTildeInPath
        let keys = (s.keys as NSString).expandingTildeInPath, app = (gs.outputApp as NSString).expandingTildeInPath
        let stage = (gs.workDir as NSString).expandingTildeInPath
        let target = s.nxTarget, teamID = s.teamID.trimmingCharacters(in: .whitespaces), free = s.freeAppleID
        let ipa = nxIPAPath(app: app), workspace = s.nxWorkspace.trimmingCharacters(in: .whitespaces).isEmpty ? nxWorkspacePath(stage: stage) : (s.nxWorkspace as NSString).expandingTildeInPath
        let output = target == .ipa ? ipa : app
        let files = stageInputs(game: gs.game, update: gs.update, dlcFolder: gs.dlc)
        Task {
            do {
                try FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try stageGameFiles(stage: URL(fileURLWithPath: stage), files: files)
            } catch {
                busy = nil; progress = nil; step = ""
                notice = "无法准备构建文件夹：\(error.localizedDescription)"; return
            }
            log += "构建文件夹：\(stage)\n" + files.map { "  \($0.lastPathComponent)\n" }.joined()
            let lines = LineBuffer()
            var totalStages = 0
            let status = await runStreaming(nxBuildCommand(venv: Paths.nxVenv.path, stage: stage, keys: keys, app: output, target: target, teamID: teamID, workspace: workspace, freeAppleID: free), cwd: nxDir, env: netEnv.merging(Model.nxToolEnvironment) { $1 }) { text in
                let whole = lines.feed(text)
                Task { @MainActor in for l in whole { totalStages = self.handleNXBuildLine(l, total: totalStages) } }
            }
            await MainActor.run {
                if let rest = lines.flush() { self.log += rest + "\n" }
                self.busy = nil; self.progress = nil; self.step = ""
                let fm = FileManager.default
                let built: Bool
                switch target {
                case .macApp: built = fm.fileExists(atPath: app + "/Contents/MacOS/nxnative")
                case .xcode: built = fm.fileExists(atPath: workspace)
                case .ipa: built = fm.fileExists(atPath: ipa)
                }
                let failed = "构建没有成功，请展开下面的日志查看原因。如果提示没有这个游戏或版本的档案，说明文件的版本不在支持列表里（\(info.displayVersions.joined(separator: "、"))）。"
                guard status == 0 && built else { self.notice = failed; return }
                switch target {
                case .macApp:
                    self.notice = "构建完成，可以启动《\(self.s.selected.displayName)》了。第一次启动要预热着色器，会慢一些。"
                case .xcode:
                    self.notice = nxXcodeNextSteps
                    NSWorkspace.shared.open(URL(fileURLWithPath: workspace))
                case .ipa:
                    self.notice = "IPA 已生成：\(ipa)。用 Sideloadly 或 AltStore 登录自己的 Apple ID 签名安装到 iPad；免费 Apple ID 的签名 7 天后过期，需要重新安装。"
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ipa)])
                }
            }
        }
    }

    /// One line of the build script's `--progress json` output (or of a tool's own output): updates the bar and the log. Returns the number of stages.
    func handleNXBuildLine(_ line: String, total: Int) -> Int {
        guard let event = parseNXBuildLine(line) else { log += line + "\n"; return total }
        switch event {
        case .stage(let k, let n, let name):
            progress = nxOverallProgress(k: k, n: n, fraction: nil)
            step = "第 \(k) 步，共 \(n) 步：" + nxStageLabel(name)
            log += "[\(k)/\(n)] \(name)\n"
            return n
        case .progress(let k, _, let fraction):
            progress = nxOverallProgress(k: k, n: total, fraction: fraction)
            return total
        case .message(let m):
            log += m + "\n"; return total
        }
    }

    /// Writes the game's env.txt (language, the player's settings, the mods' RomFS overlay) before each start. Returns a note for the status bar.
    func syncNXEnv(_ g: GameKind) -> String? {
        refreshMods()
        let gs = s.settings(for: g)
        let overlay = overlayRoots(modList, order: gs.modOrder, enabled: gs.modsEnabled)
        let work = URL(fileURLWithPath: (gs.workDir as NSString).expandingTildeInPath)
        let langs = findControlNacp(workDir: work, titleID: g.titleID).flatMap(nacpSupportedLanguages)
        let managed = nxManagedEnv(game: g, settings: gs, language: s.language, supportedLanguages: langs, overlay: overlay.value)
        do { try writeManagedEnv(managed, to: GamePaths(g, home: Paths.home).envFile) }
        catch { return "无法写入 env.txt：\(error.localizedDescription)" }
        if !overlay.skipped.isEmpty { return "有 \(overlay.skipped.count) 个 mod 的路径里含冒号，已跳过。" }
        if let langs, !langs.contains(s.language) {
            let name = Language.all.first { $0.code == s.language }?.name ?? s.language
            return "这款游戏不支持\(name)，使用游戏默认语言。"
        }
        return nil
    }

    func launchNX(_ game: GameKind) {
        let app = (s.outputApp as NSString).expandingTildeInPath, log = paths.log
        let problem = syncNXEnv(game)
        launching = true; notice = problem ?? "正在启动…"
        Task {
            let (ok, failure) = await Task.detached { () -> (Bool, String?) in
                let before = fileIdentity(log)   // the app's launcher renames the old log and starts a new one
                _ = sh("/usr/bin/open -n \(shQuote(app))")
                var aliveSeconds = 0
                for _ in 0..<90 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let text = freshLog(log, notSameAs: before), let message = nxLaunchFailure(log: text) { return (false, message) }
                    if nxRunningPID(app: app) != nil { aliveSeconds += 1; if aliveSeconds >= 5 { return (true, nil) } }
                    else if aliveSeconds > 0 { return (false, "游戏启动后马上退出了，请查看日志 \(log.path)") }
                }
                return (nxRunningPID(app: app) != nil, nil)   // still preparing shaders after 90 s
            }.value
            self.launching = false
            self.notice = ok ? (problem ?? "游戏已启动。第一次启动要预热着色器，窗口出现前会慢一些。") : (failure ?? "游戏没有启动，请查看日志 \(log.path)")
        }
    }

    /// `git pull` in the nxnative folder, then reads its game profiles again.
    func updateNX() {
        guard busy == nil else { return }
        let dir = (s.nxDir as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dir + "/.git") else { notice = "还没有安装 nxnative，请先在“环境”页安装。"; return }
        busy = "更新 nxnative"; log = ""
        Task {
            let status = await runStreaming(nxUpdateCommand(dir: dir, mirror: mirror), env: netEnv.merging(Model.nxToolEnvironment) { $1 }) { text in Task { @MainActor in self.log += text } }
            busy = nil
            refreshCatalog()
            notice = status == 0 ? "nxnative 已更新，游戏列表已刷新（共 \(GameCatalog.nx.count) 款）。已构建的 App 需要重新构建才会用上新版本。" : "更新没有成功，详情见日志。"
        }
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
    enum Kind { case required, optional, inactive, experimental }
    let kind: Kind
    var body: some View {
        let (text, color): (String, Color) = switch kind {
        case .required: ("必填", accent)
        case .optional: ("可选", .secondary)
        case .inactive: ("暂不生效", .orange)
        case .experimental: ("实验性", .orange)
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

/// The sidebar: the whole library, what the player added or can start, and each backend's games.
enum LibraryCategory: Hashable {
    case all, added, ready, backend(Backend)
    var title: String {
        switch self {
        case .all: return "全部游戏"
        case .added: return "已添加"
        case .ready: return "可启动"
        case .backend(let b): return b.title
        }
    }
    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .added: return "tray.full"
        case .ready: return "play.circle"
        case .backend(.macnative): return "leaf"
        case .backend(.nxnative): return "cube.transparent"
        }
    }
    func contains(_ e: Model.Entry) -> Bool {
        switch self {
        case .all: return true
        case .added: return e.status != .notAdded
        case .ready: return e.status == .built
        case .backend(let b): return e.kind.backend == b
        }
    }
}

extension Backend {
    var title: String { self == .nxnative ? "nxnative" : "MacNativeGames" }
}

struct BackendBadge: View {
    let backend: Backend
    var body: some View {
        Text(backend.title).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(backend == .nxnative ? Color(red: 0.55, green: 0.65, blue: 1.0) : accent)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((backend == .nxnative ? Color(red: 0.4, green: 0.5, blue: 1.0) : accent).opacity(0.14), in: Capsule())
    }
}

/// A row of buttons that act like a segmented control; an option can be disabled on its own.
struct SegmentPicker<T: Hashable>: View {
    struct Option { let value: T; let label: String; var icon: String? = nil; var enabled = true }
    let options: [Option]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i], on = selection == o.value
                Button { selection = o.value } label: {
                    HStack(spacing: 5) {
                        if let icon = o.icon { Image(systemName: icon) }
                        Text(o.label).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .foregroundStyle(o.enabled ? (on ? Color.white : Color.primary) : Color.secondary.opacity(0.45))
                    .background(on ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!o.enabled)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// One file of the selected game: click to choose it in Finder, × to remove it.
struct FileSlot: View {
    let title: String, hint: String
    let tag: TagView.Kind
    let path: String
    let check: Check
    let choose: () -> Void
    let clear: () -> Void
    @State private var hover = false

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let (icon, color, line): (String, Color, String) = switch check {
        case .empty: ("plus.circle.fill", accent, "点击添加 · " + hint)
        case .ok(let t): ("checkmark.circle.fill", accent, name + "  ·  " + t)
        case .bad(let t): ("exclamationmark.triangle.fill", .orange, (path.isEmpty ? "" : name + "：") + t)
        }
        return Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(color).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) { Text(title).font(.system(size: 12.5, weight: .medium)); TagView(kind: tag) }
                    Text(line).font(.system(size: 11)).foregroundStyle({ if case .bad = check { return Color.orange }; return Color.secondary }())
                        .lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if !path.isEmpty {
                    Button(action: clear) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("移除")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hover ? Color.white.opacity(0.07) : Color.white.opacity(path.isEmpty ? 0.02 : 0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(path.isEmpty ? Color.white.opacity(0.18) : Theme.line, style: StrokeStyle(lineWidth: 1, dash: path.isEmpty ? [5, 4] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(path.isEmpty ? "点击选择文件，也可以直接把文件拖进窗口" : path)
    }
}

struct MainView: View {
    @ObservedObject var model: Model
    var snapshot = false
    @State private var query = ""
    @State private var category = LibraryCategory.all
    @State private var grid = false
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                sidebar.frame(width: 214)
                Rectangle().fill(Theme.line).frame(width: 1)
                library
                Rectangle().fill(Theme.line).frame(width: 1)
                GameDetail(model: model).frame(width: 372)
            }
            if showLog { logDrawer }
            statusBar
        }
        .ignoresSafeArea(edges: .top)
        .frame(width: snapshot ? 1240 : nil, height: snapshot ? 760 : nil)
        .frame(minWidth: 1120, idealWidth: 1240, minHeight: 620, idealHeight: 760)
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
            Text("sw-launcher").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("搜索游戏（中文、英文或游戏 ID）", text: $query).textFieldStyle(.plain).font(.system(size: 12.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 260)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Picker("", selection: $grid) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 84).padding(.horizontal, 8)
            ToolButton(icon: "text.alignleft", text: "日志") { withAnimation { showLog.toggle() } }
            SettingsLink { ToolLabel(icon: "gearshape", text: "设置") }.buttonStyle(.plain)
        }
        .padding(.leading, snapshot ? 14 : 84).padding(.trailing, 14).padding(.bottom, 6).padding(.top, snapshot ? 6 : 4)
        .background(Theme.panel)
    }

    // MARK: sidebar

    var sidebar: some View {
        let all = model.entries
        return VStack(alignment: .leading, spacing: 2) {
            sidebarHeader("游戏库")
            ForEach([LibraryCategory.all, .added, .ready], id: \.self) { sidebarRow($0, count: all.filter($0.contains).count) }
            sidebarHeader("引擎").padding(.top, 12)
            ForEach([LibraryCategory.backend(.macnative), .backend(.nxnative)], id: \.self) { sidebarRow($0, count: all.filter($0.contains).count) }
            Spacer(minLength: 12)
            EnvCard(model: model)
        }
        .padding(10)
        .background(Theme.panel.opacity(0.55))
    }

    func sidebarHeader(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
    }

    func sidebarRow(_ c: LibraryCategory, count: Int) -> some View {
        let on = category == c
        return Button { category = c } label: {
            HStack(spacing: 8) {
                Image(systemName: c.icon).frame(width: 18).foregroundStyle(on ? Color.white : accent)
                Text(c.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer()
                Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(on ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(on ? accent.opacity(0.55) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: library

    var library: some View {
        let shown = model.entries.filter { e in
            category.contains(e) && (query.isEmpty || (e.title + e.subtitle).localizedCaseInsensitiveContains(query))
        }
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(category.title).font(.system(size: 17, weight: .bold))
                Text("\(shown.count) 款").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if case .backend(let b) = category {
                    Text(b == .nxnative ? "seedds/nxnative · 可构建 Mac / iPad / iPhone" : "王国之泪、旷野之息 · 仅 Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            Group {
                if shown.isEmpty {
                    placeholder(icon: "magnifyingglass", text: query.isEmpty ? "还没有“\(category.title)”的游戏。把游戏文件拖进窗口，或选中一款游戏后在右侧添加。" : "没有匹配“\(query)”的游戏")
                }
                else if grid { gridView(shown) } else { listView(shown) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // columns shared by header and rows
    let wVersion: CGFloat = 64, wStatus: CGFloat = 78

    func select(_ g: GameKind) { if model.busy == nil { model.s.selected = g } }
    func primaryAction() { if model.appBuilt { model.launch() } else if model.blockers.isEmpty { model.build() } }

    func listView(_ shown: [Model.Entry]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(shown, id: \.kind) { e in
                        let selected = e.kind == model.s.selected
                        HStack(spacing: 12) {
                            IconView(image: model.cover(e.kind), size: 40).onAppear { model.requestCover(e.kind) }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(e.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                    if e.kind.experimental { TagView(kind: .experimental) }
                                }
                                HStack(spacing: 6) {
                                    if case .backend = category {} else { BackendBadge(backend: e.kind.backend) }
                                    if e.kind.englishName != e.title { Text(e.kind.englishName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(e.version).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary).frame(width: wVersion, alignment: .leading)
                            statusPill(e.status).frame(width: wStatus, alignment: .leading)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(selected ? accent.opacity(0.20) : Color.clear)
                        .overlay(alignment: .leading) { if selected { Rectangle().fill(accent).frame(width: 3) } }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { select(e.kind); primaryAction() }
                        .onTapGesture { select(e.kind) }
                        .contextMenu {
                            Button("启动游戏") { select(e.kind); model.launch() }.disabled(!model.appBuilt(e.kind))
                            Button(model.appBuilt(e.kind) ? "重新构建" : "构建") { select(e.kind); model.build() }
                            Divider()
                            Button("在访达中显示 App") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (model.s.settings(for: e.kind).outputApp as NSString).expandingTildeInPath)]) }.disabled(!model.appBuilt(e.kind))
                            Button("打开存档文件夹") { model.openFolder(GamePaths(e.kind, home: Paths.home).profileSave) }
                        }
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 68)
                    }
                } header: {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("游戏").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 52)
                            Text("版本").frame(width: wVersion, alignment: .leading)
                            Text("状态").frame(width: wStatus, alignment: .leading)
                        }
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    .background(Theme.bg)
                }
            }
        }
    }

    func gridView(_ shown: [Model.Entry]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)], spacing: 16) {
                ForEach(shown, id: \.kind) { e in
                    let selected = e.kind == model.s.selected
                    VStack(spacing: 8) {
                        IconView(image: model.cover(e.kind), size: 96).onAppear { model.requestCover(e.kind) }
                        Text(e.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 6) { Text(e.version).font(.system(size: 11)).foregroundStyle(.secondary); statusPill(e.status) }
                        BackendBadge(backend: e.kind.backend)
                    }
                    .padding(14).frame(maxWidth: .infinity)
                    .background(selected ? accent.opacity(0.20) : Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? accent : Theme.line))
                    .onTapGesture(count: 2) { select(e.kind); primaryAction() }
                    .onTapGesture { select(e.kind) }
                }
            }
            .padding(18)
        }
    }

    func statusPill(_ s: Model.Status) -> some View {
        let (t, c): (String, Color) = switch s {
        case .built: ("可启动", accent)
        case .building: ("构建中", .orange)
        case .notBuilt: ("未构建", .yellow.opacity(0.8))
        case .notAdded: ("未添加", .secondary)
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
                    Text(model.notice ?? (model.s.game.isEmpty ? "选中一款游戏，在右侧点击添加游戏文件（也可以把文件拖进来）" : (model.appBuilt ? "就绪" : "还没有构建"))).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
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

// MARK: - Environment card (sidebar)

/// The selected backend's requirements: what is installing in the background, and what only the player can install.
struct EnvCard: View {
    @ObservedObject var model: Model
    var body: some View {
        let required = model.deps.filter(\.required)
        let ready = required.filter { $0.state == .ok }.count
        let checking = model.deps.contains { $0.state == .checking }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: ready == required.count ? "checkmark.seal.fill" : "shippingbox").foregroundStyle(ready == required.count ? accent : .orange)
                Text("运行环境").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(checking ? "检查中" : "\(ready)/\(required.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(model.s.selected.backend.title + " 所需组件").font(.system(size: 10.5)).foregroundStyle(.secondary)
            if let d = model.installingDep {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("后台安装：\(d.title)").font(.system(size: 11)).lineLimit(1)
                }
                if case .installing(let p?) = d.state { ProgressView(value: p).tint(accent) }
            } else if ready == required.count && !checking {
                Text("全部就绪").font(.system(size: 11)).foregroundStyle(accent)
            }
            ForEach(model.manualDeps) { d in
                HStack(spacing: 6) {
                    Image(systemName: "person.fill.questionmark").font(.system(size: 10)).foregroundStyle(.orange)
                    Text(d.title).font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 2)
                    Button("安装") { model.install(d.id) }.controlSize(.mini)
                }.help(d.detail + "（需要你输入密码或在 App Store 里操作，不能自动安装）")
            }
            ForEach(model.deps.filter { if case .failed = $0.state { return true }; return false }) { d in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    Text(d.title + " 安装失败").font(.system(size: 11)).lineLimit(1)
                    Spacer(minLength: 2)
                    Button("重试") { model.install(d.id) }.controlSize(.mini)
                }
            }
            if ready < required.count && !checking {
                Button { model.installAll() } label: { Label("一键安装全部", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
                    .help("需要密码的组件在一个“终端”窗口里依次安装（只输一次密码），Xcode 打开 App Store，其余的在后台安装")
            }
            Text(model.mirror ? "下载源：国内镜像" : "下载源：官方源").font(.system(size: 10.5)).foregroundStyle(.secondary).help(model.netSummary)
            Toggle("缺少的组件自动在后台安装", isOn: $model.s.autoInstall)
                .toggleStyle(.checkbox).font(.system(size: 11))
                .onChange(of: model.s.autoInstall) { if model.s.autoInstall { model.autoInstallNext() } }
        }
        .padding(10)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Game detail (right pane)

/// The selected game: version, its files (click to add), the build target, and build / start.
struct GameDetail: View {
    @ObservedObject var model: Model

    var body: some View {
        let g = model.s.selected
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(g)
                    section("版本") { versionPicker(g) }
                    section("游戏文件") { files(g) }
                    section("共享文件（所有游戏通用）") { shared(g) }
                    section("构建目标") { targetPicker(g) }
                    section("存档") { saves(g) }
                    section("Mods") { mods(g) }
                }
                .padding(18)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {   // build / start stay in view however long the pane above is
                actions(g)
                footer(g)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.panel.opacity(0.6))
        }
        .background(Theme.panel.opacity(0.35))
        .onAppear { model.refreshMods() }
        .onChange(of: model.s.selected) { model.refreshMods() }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            c()
        }
    }

    func header(_ g: GameKind) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconView(image: model.cover(g), size: 68).onAppear { model.requestCover(g) }.onChange(of: g) { model.requestCover(g) }
            VStack(alignment: .leading, spacing: 4) {
                Text(g.displayName).font(.system(size: 17, weight: .bold)).lineLimit(2)
                if g.englishName != g.displayName { Text(g.englishName).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 6) {
                    BackendBadge(backend: g.backend)
                    if g.experimental { TagView(kind: .experimental) }
                    Text(g.titleID).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: version

    var versionBinding: Binding<String> {
        Binding(get: { model.version }, set: { model.s.current.version = $0 })
    }

    @ViewBuilder func versionPicker(_ g: GameKind) -> some View {
        let versions = g.supportedVersions
        if versions.count <= 4 {
            SegmentPicker(options: versions.map { .init(value: $0, label: $0) }, selection: versionBinding).disabled(model.busy != nil)
        } else {
            Picker("", selection: versionBinding) { ForEach(versions, id: \.self) { Text($0).tag($0) } }.labelsHidden().disabled(model.busy != nil)
        }
        Text(model.needsUpdate ? "需要游戏本体 + \(model.version) 的更新包" + (g.backend == .nxnative ? "（文件名要带 [v版本号]）" : "")
                               : "只需要游戏本体（\(model.version)）")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    // MARK: files

    @ViewBuilder func files(_ g: GameKind) -> some View {
        let nx = g.backend == .nxnative
        FileSlot(title: "游戏本体", hint: nx ? "NSP / XCI / NSZ / XCZ" : (g == .botw ? "基础版 NSP" : "XCI / NSP（基础版）"), tag: .required,
                 path: model.s.game, check: model.check(.game), choose: { model.choose(.game) }, clear: { model.s.game = "" })
        if model.needsUpdate || !model.s.update.isEmpty {
            FileSlot(title: "更新包 \(model.version)", hint: nx ? "NSP / NSZ，文件名带 [v版本号]" : "NSP / NSZ", tag: model.needsUpdate ? .required : .optional,
                     path: model.s.update, check: model.check(.update), choose: { model.choose(.update) }, clear: { model.s.update = "" })
        }
        if nx {
            FileSlot(title: "DLC", hint: "放 DLC 文件的文件夹", tag: .optional,
                     path: model.s.dlc, check: model.check(.dlc), choose: { model.choose(.dlc) }, clear: { model.s.dlc = "" })
        }
    }

    @ViewBuilder func shared(_ g: GameKind) -> some View {
        FileSlot(title: "prod.keys", hint: "从你自己的 Switch 导出", tag: .required,
                 path: model.s.keys, check: model.check(.keys), choose: { model.choose(.keys) }, clear: { model.s.keys = "" })
        if g.backend == .macnative {
            FileSlot(title: "固件", hint: "文件夹或 .zip", tag: .required,
                     path: model.s.firmware, check: model.check(.firmware), choose: { model.choose(.firmware) }, clear: { model.s.firmware = "" })
        } else {
            Label("nxnative 不需要固件；游戏文件只做符号链接，不复制。", systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: saves and mods

    @ViewBuilder func saves(_ g: GameKind) -> some View {
        FileSlot(title: "要导入的存档", hint: "存档文件夹", tag: .optional,
                 path: model.s.save, check: model.check(.save), choose: { model.choose(.save) }, clear: { model.s.save = "" })
        HStack(spacing: 8) {
            Button { model.importSave() } label: { Label("导入到游戏", systemImage: "square.and.arrow.down") }
                .disabled({ if case .ok = model.check(.save) { return false }; return true }())
            Button { model.openFolder(model.paths.profileSave) } label: { Label("打开游戏存档", systemImage: "folder") }
        }.controlSize(.small)
        Text("导入前会自动备份现有存档。第一次要先启动一次游戏，让它创建存档目录。").font(.system(size: 11)).foregroundStyle(.secondary)
    }

    var modsCheck: Check {
        if model.s.mods.isEmpty { return .empty }
        if model.modList.isEmpty { return .bad("没有找到 mod（需要 <mod>/romfs/…）") }
        let on = model.modList.filter { model.modEnabled($0.name) }.count
        return .ok("\(model.modList.count) 个 mod，启用 \(on) 个")
    }

    @ViewBuilder func mods(_ g: GameKind) -> some View {
        FileSlot(title: "Mods 文件夹", hint: "RomFS 替换，<mod>/romfs/…", tag: .optional, path: model.s.mods, check: modsCheck,
                 choose: { if let p = model.pick(directory: true, title: "选择 Mods 文件夹") { model.s.mods = p; model.refreshMods() } },
                 clear: { model.s.mods = ""; model.refreshMods() })
        if !model.modList.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(model.modList.enumerated()), id: \.element.name) { i, m in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(get: { model.modEnabled(m.name) }, set: { model.setMod(m.name, enabled: $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(accent)
                        Text(m.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 2)
                        let c = model.modEnabled(m.name) ? model.conflictCount(m.name) : 0
                        if c > 0 { Text("\(c) 冲突").font(.system(size: 10.5)).foregroundStyle(.orange) }
                        Button { model.moveMod(m.name, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0)
                        Button { model.moveMod(m.name, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == model.modList.count - 1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    if i < model.modList.count - 1 { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
        }
        Text(target == .macApp ? "多个 mod 改了同一个文件时，靠下的生效。下次启动时生效，不用重新构建。" : "Mods 只对 Mac App 生效，iPad / iPhone 构建不会带上。")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    // MARK: build target

    var target: NXTarget { model.s.selected.backend == .nxnative ? model.s.nxTarget : .macApp }

    @ViewBuilder func targetPicker(_ g: GameKind) -> some View {
        let nx = g.backend == .nxnative
        SegmentPicker(options: [
            .init(value: NXTarget.macApp, label: "Mac", icon: "desktopcomputer"),
            .init(value: .xcode, label: "iPad/iPhone", icon: "ipad.and.iphone", enabled: nx),
            .init(value: .ipa, label: "IPA", icon: "shippingbox", enabled: nx),
        ], selection: Binding(get: { target }, set: { model.s.nxTarget = $0 }))
        .disabled(model.busy != nil)
        switch target {
        case .macApp:
            Text(nx ? "生成可以双击运行的 Mac App。" : "MacNativeGames 只能构建 Mac App；iPad / iPhone 请选 nxnative 的游戏。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .xcode, .ipa:
            Text(target == .xcode ? "生成 Xcode 工程并自动打开：登录自己的 Apple ID（免费的也行），选 Personal Team，连上设备点 Run。"
                                  : "生成 IPA，用 Sideloadly / AltStore 登录自己的 Apple ID 签名安装。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("Team ID").font(.system(size: 11.5)).foregroundStyle(.secondary)
                TextField("可留空", text: $model.s.teamID).textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
            Toggle("免费 Apple ID（不申请“增大内存限制”）", isOn: $model.s.freeAppleID).font(.system(size: 11.5))
                .help("免费账号无法申请这项权限；代价是大型游戏可能被系统关闭。签名 7 天后过期，重新 Run 即可。")
        }
    }

    // MARK: build / start

    var buildTitle: String {
        switch target {
        case .macApp: return model.appBuilt ? "重新构建" : "构建 Mac App"
        case .xcode: return "生成 Xcode 工程"
        case .ipa: return "生成 IPA"
        }
    }

    @ViewBuilder func actions(_ g: GameKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.busy != nil, let p = model.progress {
                ProgressView(value: p).tint(accent)
                Text(model.step).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if model.busy != nil {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(model.busy ?? "").font(.system(size: 11.5)) }
            }
            HStack(spacing: 8) {
                if target == .macApp && model.appBuilt {
                    Button { model.launch() } label: { Label(model.launching ? "启动中…" : "启动", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                        .disabled(model.launching || model.busy != nil)
                    Button { model.build() } label: { Label("重建", systemImage: "hammer") }
                        .controlSize(.large).disabled(model.busy != nil || !model.blockers.isEmpty)
                } else {
                    Button { model.build() } label: { Label(buildTitle, systemImage: "hammer.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                        .disabled(model.busy != nil || !model.blockers.isEmpty)
                }
            }
            if !model.blockers.isEmpty && model.busy == nil {
                Label("还缺：" + model.blockers.joined(separator: "、"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    func footer(_ g: GameKind) -> some View {
        HStack(spacing: 12) {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (model.s.outputApp as NSString).expandingTildeInPath)]) }
                .disabled(!model.appBuilt)
            Spacer()
            SettingsLink { Text("更多设置…") }
        }
        .buttonStyle(.borderless).font(.system(size: 11.5)).foregroundStyle(accent)
    }
}

// MARK: - nxnative setting row

/// One nxnative setting: "default" (nothing is written) or the player's value.
struct NXSettingRow: View {
    let setting: NXSetting
    @ObservedObject var model: Model

    private var value: Binding<String> {
        Binding(get: { model.s.current.nxEnv[setting.variable] ?? "" },
                set: { new in
                    if new.isEmpty { model.s.current.nxEnv.removeValue(forKey: setting.variable) } else { model.s.current.nxEnv[setting.variable] = new }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(setting.label).font(.system(size: 13))
                Spacer()
                control.frame(width: 250, alignment: .trailing)
            }
            if !setting.note.isEmpty { Text(setting.note).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .choice(let options):
            Picker("", selection: value) {
                Text("默认").tag("")
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }.labelsHidden().frame(width: 190)
        case .toggle(let on, let off):
            Picker("", selection: value) { Text("默认").tag(""); Text("开").tag(on); Text("关").tag(off) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
        case .range(let lo, let hi, let step):
            HStack(spacing: 8) {
                let current = Binding<Double>(get: { Double(value.wrappedValue) ?? min(max(1.0, lo), hi) },
                                              set: { value.wrappedValue = nxNormalized(String($0), for: setting) ?? "" })
                Slider(value: current, in: lo...hi, step: step).frame(width: 130)
                Text(value.wrappedValue.isEmpty ? "默认" : value.wrappedValue).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                Button { value.wrappedValue = "" } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).disabled(value.wrappedValue.isEmpty).help("恢复默认")
            }
        case .count(let max):
            let cores = ProcessInfo.processInfo.activeProcessorCount
            Picker("", selection: value) {
                Text("自动（\(cores)）").tag("")
                ForEach(1...Swift.min(max, Swift.max(cores * 2, 2)), id: \.self) { Text("\($0)").tag(String($0)) }
            }.labelsHidden().frame(width: 190)
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

    /// Which game the per-game fields (game file, update, save, mods, output) belong to.
    var gamePicker: some View {
        Picker("游戏", selection: $model.s.selected) {
            Section("MacNativeGames") {
                ForEach(GameKind.macnativeGames) { g in Text(g.displayName + (g.experimental ? "（实验性）" : "")).tag(g) }
            }
            Section("nxnative（\(GameCatalog.nx.count) 款）") {
                ForEach(GameKind.nxGames) { g in Text(g.displayName + (g.displayName == g.englishName ? "" : "  ·  " + g.englishName)).tag(g) }
            }
        }.pickerStyle(.menu).disabled(model.busy != nil)
    }

    /// The versions the selected game can be built from, and which one is packed.
    var versionsBlock: some View {
        let g = model.s.selected
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) { Text("支持的版本").font(.system(size: 13, weight: .medium)); Text(g.titleID).font(.system(size: 11)).foregroundStyle(.secondary) }
            HStack(spacing: 6) { ForEach(g.supportedVersions, id: \.self) { Chip(text: $0, ok: nil) } }
            Text(g.nxInfo.map { "游戏本体加上对应版本的更新包；默认打包最新的 \($0.packageDisplay)。其他版本会被 nxnative 当成未收录的游戏。" }
                 ?? (g == .botw ? "需要基础版和 1.9.0 更新。" : "基础版是 1.0.0；要玩 1.1.2 或 1.4.3，再选对应的累积更新包。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    var filesTab: some View {
        let g = model.s.selected
        return pane {
            gamePicker
            versionsBlock
            if g.backend == .nxnative { nxFiles } else { macFiles }
            DisclosureGroup("高级：输出位置", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 10) {
                    if g.backend == .nxnative {
                        Picker("构建目标", selection: $model.s.nxTarget) {
                            ForEach(NXTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        if model.s.nxTarget.isIOS {
                            labeled("Apple Team ID（可留空，在 Xcode 里选）", $model.s.teamID)
                            Toggle("免费 Apple ID（不申请“增大内存限制”，大型游戏可能被系统关闭）", isOn: $model.s.freeAppleID)
                        }
                        labeled("nxnative 目录", $model.s.nxDir)
                        labeled(model.s.nxTarget == .ipa ? "生成位置（IPA 与此同名，后缀换成 .ipa）" : "生成的 App", $model.s.outputApp, choose: appPicker)
                        labeled("构建文件夹（放游戏文件的链接和中间文件）", $model.s.workDir, choose: workPicker)
                        if model.s.nxTarget == .xcode {
                            labeled("Xcode 工作区（留空 = 构建文件夹旁的 sw-launcher.xcworkspace）", $model.s.nxWorkspace) {
                                model.pickSave(title: "选择 Xcode 工作区位置", current: model.s.nxWorkspace.isEmpty ? nxWorkspacePath(stage: (model.s.workDir as NSString).expandingTildeInPath) : model.s.nxWorkspace)
                            }
                        }
                    } else {
                        labeled("构建工具目录", $model.s.projectDir)
                        labeled("生成的 App", $model.s.outputApp, choose: appPicker)
                        labeled("构建缓存目录", $model.s.workDir, choose: workPicker)
                    }
                }.padding(.top, 8)
            }.font(.system(size: 12))
        }
    }

    @ViewBuilder var macFiles: some View {
        PathRow(title: model.s.selected == .botw ? "游戏本体（基础版 NSP）" : "游戏本体（XCI / NSP）", tag: .required, value: $model.s.game, check: model.check(.game)) {
            if let p = model.pick(directory: false, extensions: ["xci", "nsp"], title: "选择游戏本体") { model.s.game = p }
        }
        PathRow(title: "prod.keys", tag: .required, value: $model.s.keys, check: model.check(.keys)) {
            if let p = model.pick(directory: false, extensions: ["keys"], title: "选择 prod.keys") { model.s.keys = p }
        }
        PathRow(title: "固件（文件夹或 .zip）", tag: .required, value: $model.s.firmware, check: model.check(.firmware)) {
            if let p = model.pick(directory: true, extensions: ["zip"], title: "选择固件") { model.s.firmware = p }
        }
        PathRow(title: model.s.selected == .botw ? "更新包（1.9.0，NSP）" : "更新包（1.1.2 / 1.4.3，NSP 或 NSZ）", tag: model.s.selected == .botw ? .required : .optional, value: $model.s.update, check: model.check(.update)) {
            model.choose(.update)
        }
    }

    @ViewBuilder var nxFiles: some View {
        PathRow(title: "游戏本体（NSP / XCI / NSZ / XCZ）", tag: .required, value: $model.s.game, check: model.check(.game)) {
            if let p = model.pick(directory: false, extensions: ["nsp", "xci", "nsz", "xcz"], title: "选择游戏本体") { model.s.game = p }
        }
        PathRow(title: "更新包（文件名要带 [v版本号]）", tag: model.needsUpdate ? .required : .optional, value: $model.s.update, check: model.check(.update)) {
            model.choose(.update)
        }
        PathRow(title: "DLC 文件夹", tag: .optional, value: $model.s.dlc, check: model.check(.dlc)) {
            if let p = model.pick(directory: true, title: "选择放 DLC 文件的文件夹") { model.s.dlc = p }
        }
        PathRow(title: "prod.keys", tag: .required, value: $model.s.keys, check: model.check(.keys)) {
            if let p = model.pick(directory: false, extensions: ["keys"], title: "选择 prod.keys") { model.s.keys = p }
        }
        Label("nxnative 不需要固件。构建时游戏文件只做符号链接，不复制；放在外置硬盘上也行。", systemImage: "info.circle")
            .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    func labeled(_ title: String, _ binding: Binding<String>, choose: (() -> String?)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("", text: binding).textFieldStyle(.roundedBorder).font(.system(size: 12))
                if let choose { Button("选择…") { if let p = choose() { binding.wrappedValue = p } } }
            }
        }
    }

    func appPicker() -> String? { model.pickSave(title: "选择生成位置", current: model.s.outputApp) }
    func workPicker() -> String? { model.pick(directory: true, title: "选择构建文件夹") }

    var systemTab: some View {
        let i = model.info
        return pane {
            HStack(spacing: 8) {
                Text("游戏语言").font(.system(size: 13, weight: .medium)); TagView(kind: .required)
                Spacer()
                Picker("", selection: $model.s.language) { ForEach(Language.all) { Text($0.name).tag($0.code) } }.labelsHidden().frame(width: 190)
            }
            Toggle("显示游戏封面（还没构建的游戏从任天堂官方商店服务器下载图标并缓存）", isOn: $model.s.showCovers).font(.system(size: 12))
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

    @ViewBuilder var graphicsTab: some View {
        if model.s.selected.backend == .nxnative { nxGraphicsTab } else { macGraphicsTab }
    }

    var nxGraphicsTab: some View {
        let g = model.s.selected
        return pane {
            gamePicker
            Text("设置会写进这款游戏的 env.txt（\(GamePaths(g, home: Paths.home).envFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))），下次点“启动”时生效。没改过的项沿用游戏自己的默认值。你在 env.txt 里手写的行优先于这里。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(["游戏", "性能", "手柄"], id: \.self) { section in
                let items = nxSettings(for: g).filter { $0.section == section }
                if !items.isEmpty {
                    Divider()
                    Text(section).font(.system(size: 13, weight: .semibold))
                    ForEach(items) { NXSettingRow(setting: $0, model: model) }
                }
            }
            Divider()
            HStack {
                Button("全部恢复默认") { model.s.current.nxEnv = [:] }.disabled(model.s.current.nxEnv.isEmpty)
                Text("这台 Mac 有 \(ProcessInfo.processInfo.activeProcessorCount) 个 CPU 核心").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    var macGraphicsTab: some View {
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
            Text("默认以原生 2K（2560×1440）启动。游戏窗口里按 3 循环切换：原生 2K → 关闭 2K（1080p）→ MetalFX 2K。在测试机（M1 Max，macOS 27）上只有原生 2K 有画面，另外两档会黑屏。按 1 显示 / 隐藏帧率等信息，按 2 切换补帧。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    var envTab: some View {
        pane {
            HStack {
                Text("运行环境").font(.system(size: 13, weight: .semibold)); Spacer()
                Button("一键安装全部") { model.installAll() }.controlSize(.small).disabled(model.deps.filter(\.required).allSatisfy { $0.state == .ok })
                Button("重新检查") { model.refreshDeps() }.controlSize(.small)
            }
            HStack(spacing: 8) {
                Text("下载源").font(.system(size: 12))
                Picker("", selection: $model.s.network) { ForEach(NetworkMode.allCases, id: \.self) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 320)
            }
            Text(model.netSummary + "。Homebrew、Python 组件、MacNativeGames 和 nxnative 会走所选的源；Xcode、Metal Toolchain 来自 Apple，.NET 来自微软。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(model.s.selected.backend == .nxnative ? "当前游戏用 nxnative 构建" : "当前游戏用 MacNativeGames 构建").font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(model.deps) { dep in DepRow(dep: dep) { model.install(dep.id) } }
            Text("打开“自动后台安装”时，不需要密码的组件会在前置条件就绪后自动安装；Homebrew、命令行工具、.NET 和 Xcode 设置需要密码，要你点“安装”在“终端”里运行。").font(.system(size: 11)).foregroundStyle(.secondary)
            if model.s.selected.backend == .nxnative {
                Divider()
                HStack {
                    Button { model.updateNX() } label: { Label("更新 nxnative 与游戏列表", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(model.busy != nil || model.deps.first(where: { $0.id == "nxrepo" })?.state != .ok)
                    Button("刷新游戏列表") { model.refreshCatalog() }
                }
                Text("nxnative 经常加入新游戏和新版本。更新后游戏列表会自动读它的 dm/games；已经构建好的 App 要重新构建才会用上新版本。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    var extrasTab: some View {
        pane {
            gamePicker.onChange(of: model.s.selected) { model.refreshMods() }.onAppear { model.refreshMods() }
            PathRow(title: "存档", tag: .optional, value: $model.s.save, check: model.check(.save)) {
                if let p = model.pick(directory: true, title: "选择存档文件夹") { model.s.save = p }
            }
            HStack {
                Button("导入存档到游戏…") { model.importSave() }.disabled({ if case .ok = model.check(.save) { return false }; return true }())
                Button("打开游戏存档文件夹") { model.openFolder(model.paths.profileSave) }
            }
            Text("导入前会自动备份现有存档。第一次需要先启动一次游戏，让它创建存档目录。").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Text("Mods（RomFS 替换）").font(.system(size: 13, weight: .medium))
            HStack(spacing: 8) {
                TextField("选择…", text: $model.s.mods).textFieldStyle(.roundedBorder).font(.system(size: 12))
                Button("选择…") { if let p = model.pick(directory: true, title: "选择 Mods 文件夹") { model.s.mods = p; model.refreshMods() } }
                Button("刷新") { model.refreshMods() }
            }
            if model.modList.isEmpty {
                Text(model.s.mods.isEmpty ? "选择一个 Mods 文件夹。" : "这个文件夹里没有找到 mod（需要 <mod>/romfs/… 或 contents/\(model.s.selected.titleID)/<mod>/romfs/…）。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.modList.enumerated()), id: \.element.name) { i, m in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { model.modEnabled(m.name) }, set: { model.setMod(m.name, enabled: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(accent)
                            Text(m.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            let c = model.modEnabled(m.name) ? model.conflictCount(m.name) : 0
                            Text("\(m.files.count) 个文件").font(.system(size: 11)).foregroundStyle(.secondary)
                            if c > 0 { Text("\(c) 个冲突").font(.system(size: 11)).foregroundStyle(.orange).help(model.modResolution.conflicts.filter { $0.value.contains(m.name) }.keys.sorted().prefix(20).joined(separator: "\n")) }
                            if m.files.contains(where: model.modWarnings.contains) { Text("含新增文件，不支持").font(.system(size: 11)).foregroundStyle(.orange) }
                            Button { model.moveMod(m.name, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(i == 0)
                            Button { model.moveMod(m.name, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(i == model.modList.count - 1)
                        }.padding(.vertical, 4)
                    }
                }
            }
            Text(model.s.selected.backend == .nxnative
                 ? "nxnative 启动时先在 mod 的 romfs 文件夹里找文件，找不到再读游戏原版（DM_ROMFS_OVERLAY）。多个 mod 改了同一个文件时，列表里靠下的生效。改动在下次启动时生效，不用重新构建。暂不支持 ExeFS 补丁和金手指。"
                 : "只支持替换游戏里已有的文件（romfs 文件夹）。多个 mod 改了同一个文件时，列表里靠下的生效。改动在下次启动时生效，不用重新构建。暂不支持 ExeFS 补丁和金手指。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    var aboutTab: some View {
        pane {
            HStack(spacing: 14) {
                IconView(image: model.appIcon, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("sw-launcher").font(.system(size: 18, weight: .bold))
                    Text("版本 1.5.0 · \(GameKind.all.count) 款游戏：MacNativeGames 2 款（王国之泪、旷野之息），nxnative \(GameCatalog.nx.count) 款 · Apple 芯片").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("这个启动器只负责检测环境、调用构建脚本、导入存档、管理 Mods 和启动游戏。游戏本体、密钥和固件都必须是你自己的，启动器不包含任何游戏内容。").font(.system(size: 12)).foregroundStyle(.secondary)
            Link("构建工具：nxnative（GitHub）", destination: URL(string: "https://github.com/seedds/nxnative")!).font(.system(size: 12))
            Link("构建工具：MacNativeGames（GitHub）", destination: URL(string: "https://github.com/ly05010419/MacNativeGames")!).font(.system(size: 12))
            Link("教程：AppleGamingWiki · Nxnative Switch to Mac conversion", destination: URL(string: "https://www.applegamingwiki.com/wiki/Nxnative_Switch_to_Mac_conversion")!).font(.system(size: 12))
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
                let size = tab != nil ? NSSize(width: 640, height: 470) : NSSize(width: 1240, height: 760)
                let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: .darkAqua)
                win.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let wait = args.firstIndex(of: "--wait").flatMap { Double(args[safe: $0 + 1] ?? "") } ?? 0.9   // e.g. for covers to download
                RunLoop.current.run(until: Date().addingTimeInterval(wait))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("sw-launcher") {
            MainView(model: model).preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 760)
        .commands {
            CommandMenu("操作") {
                Button("启动游戏") { model.launch() }.keyboardShortcut("l").disabled(!model.appBuilt)
                Button(model.appBuilt ? "重新构建" : "构建 App") { model.build() }.keyboardShortcut("b").disabled(model.busy != nil || !model.blockers.isEmpty)
                Button("导入存档…") { model.importSave() }.keyboardShortcut("i")
            }
            CommandMenu("工具") {
                Button("重新检查环境") { model.refreshDeps() }
                Button("烘焙着色器缓存（MacNativeGames）") { model.bake() }.disabled(model.s.selected.backend != .macnative)
                Button("更新 nxnative 与游戏列表") { model.updateNX() }
                Divider()
                Button("打开游戏存档文件夹") { model.openFolder(model.paths.profileSave) }
                Button("打开着色器缓存文件夹") { model.openFolder(model.shaderDir) }
                Button("打开日志文件") { NSWorkspace.shared.open(model.paths.log) }
            }
            CommandGroup(replacing: .help) {
                Link("nxnative 主页（GitHub）", destination: URL(string: "https://github.com/seedds/nxnative")!)
                Link("MacNativeGames 主页（GitHub）", destination: URL(string: "https://github.com/ly05010419/MacNativeGames")!)
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
        s.selected = .botw
        s.game = "~/Games/Switch/BOTW/nsp/BOTW [01007EF00011E000][v0].nsp"
        s.update = "~/Games/Switch/BOTW/nsp/BOTW 1.9.0 [01007EF00011E800][v1114112].nsp"
        s.outputApp = "~/Games/Switch/BOTW/Breath of the Wild.app"
        s.selected = .totk
        s.game = "~/Games/Switch/TOTK/xci/TOTK [0100F2C0115B6000][v0].xci"
        s.keys = "~/Games/Switch/Keys/prod.keys"
        s.firmware = "~/Games/Switch/Firmware"
        s.update = "~/Games/Switch/TOTK/nsp/TOTK v1.4.3 [0100F2C0115B6800][UPD].nsp"
        s.save = ""
        s.projectDir = "~/Sites/MacNativeGames"
        s.outputApp = "~/Games/Switch/TOTK/Tears of the Kingdom.app"
        deps = Model.makeDeps(project: s.projectDir, nxDir: s.nxDir, backend: s.selected.backend)
        for i in deps.indices { deps[i].state = .ok }
        shaderSources = 8652; shaderBaked = 8652
        s.mods = NSTemporaryDirectory() + "sw-demo-mods"   // sample mods for the screenshots, if that folder exists
        // An nxnative game with an update and a few settings; `--select nx` shows it in the settings screenshots.
        let lm3 = GameKind.nx("0100DCA0064A6000")
        s.games[lm3.rawValue] = {
            var g = GameSettings.defaults(lm3, home: Paths.home)
            g.game = "~/Games/Switch/LM3/Luigi's Mansion 3 [0100DCA0064A6000][v0].nsp"
            g.update = "~/Games/Switch/LM3/Luigi's Mansion 3 [0100DCA0064A6800][v327680].nsp"
            g.nxEnv = ["DM_FPS_TARGET": "60", "DM_PSO_PREPARE_THREADS": "8", "DM_PRESENT_UPSCALE": "metalfx"]
            return g
        }()
        s.nxDir = "~/nxnative"
        if CommandLine.arguments.contains("nx") { s.selected = lm3 }
        deps = Model.makeDeps(project: s.projectDir, nxDir: s.nxDir, backend: s.selected.backend)
        for i in deps.indices { deps[i].state = .ok }
        refreshMods()
    }
}
