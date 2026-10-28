# Phases

## phase/01-nxnative-backend

**目标**：在保留现有 MacNativeGames 后端（王国之泪多版本、旷野之息、并行着色器预热、预编译烘焙、RomFS Mods）的前提下，
把 [nxnative](https://github.com/seedds/nxnative)（AppleGamingWiki: *Nxnative Switch to Mac conversion*）作为第二个后端接进来，
让启动器能构建并运行 nxnative 支持的 69 款游戏及其支持的版本。

**设计要点**

- 两个后端并存：`macnative`（原来的 TOTK / BOTW，补丁、多线程预热、Mods 清单都不动）和 `nxnative`（新增）。
- 游戏目录 `NXCatalog.swift` 由 `scripts/gen-catalog.py` 从 nxnative 的 `dm/games/*/game.tsv` 生成；装好 nxnative 后，
  启动器也会在运行时读它的 `dm/games`，新增的游戏和版本不用等启动器更新。
- nxnative 的 Mac App 靠 `~/Library/Application Support/nxnative/<标题ID>/env.txt` 配置，启动器只写这个文件，不改 nxnative 的代码：
  - Mods → `DM_ROMFS_OVERLAY`（冒号分隔，靠前的优先，找不到再回退原版 RomFS）。
  - 多线程 → `DM_PSO_PREPARE_THREADS`（着色器 / 管线预热线程数，默认等于核心数）。
  - 语言、帧率、渲染比例、MetalFX、掌机 / 主机模式等 → 对应的 `DM_*` 变量。
- nxnative 构建只需要游戏本体、更新、DLC 和 `prod.keys`，**不需要固件**。每个游戏用独立的暂存文件夹（符号链接）喂给构建脚本，
  因为脚本要求“一个文件夹一款游戏”。
- 构建用 `--platform mac-app --progress json`，进度条读它的 JSON 事件。

**完成标准**

- [x] 功能达标：游戏库列出两个后端的全部游戏；nxnative 游戏可安装依赖、构建、启动，设置、Mods、线程数可用。
- [x] 能跑：`./build.sh` 成功，启动器能打开并显示游戏库。
- [x] 测试通过：`./scripts/test.sh` 全部通过（目录、设置迁移、env.txt、overlay、运行检测、命令生成）。
- [ ] 真机整条构建流程（需要 Homebrew 依赖、.NET 10、Metal Toolchain 和游戏文件，30–60 分钟）：**未在本阶段验证**。

## phase/02-nxnative-ios

**目标**：nxnative 后端除 Mac App 外，还能为 iPad / iPhone 构建，让用户用自己的 Apple ID 签名后装到设备上。

**设计要点**

- 构建目标三选一（设置 → 高级）：`Mac App`（原有）、`Xcode 工程`（`--prepare-xcode`，推荐）、`IPA`（`--platform ios`）。
- 推荐 Xcode 工程：Xcode 登录免费 Apple ID 后可直接签名并用线安装到 iPad；IPA 要靠 Sideloadly / AltStore 重签，文件也大得多。
- 免费 Apple ID 无法申请“增大内存限制”，所以默认用空的 `DM_ENTITLEMENTS=` 构建；代价是大型游戏可能被 iOS 关闭。付费账号取消勾选即可。
- Team ID 可选，通过 `--team-id` 传给构建脚本；留空就在 Xcode 里选。
- iOS 目标不改 Mac 的启动、env.txt、Mods 逻辑（这些只对 Mac App 生效）。

**完成标准**

- [x] 功能达标：目标选择、Team ID、免费账号开关、三种命令生成、完成后的提示（Xcode 工程自动打开，IPA 在访达中显示）。
- [x] 能跑：`./build.sh` 成功。
- [x] 测试通过：`./scripts/test.sh` 全部通过（新增 iOS 命令、路径、设置往返）。
- [ ] 真机：整条 iOS 构建与在 iPad 上运行**未验证**（需要 Xcode、Apple ID、iPad 和游戏文件）。

## phase/04-library-redesign

**目标**：主窗口改成“分类 + 游戏详情”，常用操作都在主窗口完成，不用再进设置；缺少的组件后台自动安装；新的 App 图标。

**设计要点**

- 左侧分类：全部 / 已添加 / 可启动，以及按引擎（MacNativeGames、nxnative）分类；底部是运行环境卡片。
- 中间列表只放名称、引擎、版本、状态，不再堆路径和 ID。
- 右侧详情：选择版本（按版本决定是否需要更新包，并校验更新包版本）、点击添加游戏本体 / 更新包 / DLC / prod.keys / 固件、
  构建目标（Mac / iPad·iPhone Xcode 工程 / IPA；MacNativeGames 只能 Mac）、构建与启动按钮固定在底部。
- 自动安装（`autoInstall`，默认开）：不需要密码的组件按顺序、在前置条件就绪后逐个后台安装；失败不自动重试；
  需要密码 / App Store 的（Homebrew、命令行工具、.NET、Xcode）列在环境卡片里，点“安装”在终端运行。
- 图标由 codex cli 生成（`assets/AppIcon-1024.png`），按 macOS 图标网格加边距后打包为 `AppIcon.icns`。

**完成标准**

- [x] 功能达标：分类、版本选择、主窗口添加文件、构建目标、后台自动安装、新图标。
- [x] 能跑：`./build.sh` 成功，demo 截图布局正常。
- [x] 测试通过：`./scripts/test.sh` 全部通过（新增版本选择、设置往返）。
- [ ] 真实环境里的整条点击流程（含自动安装）：未逐项点过。

## phase/05-one-click-mirrors

**目标**：缺少的组件一键装好；国内网络下不卡住；详情面板里直接管理存档和 Mods。

**设计要点**

- 一键安装：需要密码的（Homebrew、命令行工具、.NET、Xcode 设置）合进一个“终端”窗口依次执行，只输一次密码（`sudo -v` 并保持）；Xcode 打开 App Store；其余在后台按依赖顺序安装。终端安装期间每 15 秒重新检查。
- 下载源（设置 → 环境）：自动 / 官方源 / 国内镜像。自动 = 没有代理，或 PyPI、GitHub 4 秒内没响应时用镜像（Homebrew、PyPI：清华 TUNA；Homebrew 安装脚本：中科大；git：ghfast）。MacNativeGames 按提交哈希抓取，镜像换不了内容。
- 系统代理（`scutil --proxy`）作为 `http(s)_proxy` 传给所有安装和构建命令：从访达打开的 App 默认不会传。pip 加超时和重试，下载卡住会报错而不是一直“正在安装”。
- 修复：重新检查时不再丢掉“正在安装”的状态；同一组件同时只会有一个安装进程（之前会被重复启动）。
- 详情面板加“存档”（选择、导入、打开）和“Mods”（文件夹、开关、排序、冲突数）。

**完成标准**

- [x] 功能达标；Python 组件安装命令走镜像实测 29 秒装完。
- [x] 能跑：`./build.sh` 成功。
- [x] 测试通过：`./scripts/test.sh` 全部通过（代理解析、镜像命令、终端脚本）。
- [ ] 一键安装的终端流程未在缺组件的机器上完整走过。

## phase/06-cover-art

**目标**：游戏库显示游戏封面，而不是统一的播放键图标。

**设计要点**

- 优先级：已构建 App 的图标 → nxnative 从玩家自己的游戏文件解出的 `icon.jpg`（`<构建文件夹>/<ID>_build/extract/<版本>/`）→ 任天堂官方 eShop CDN 的图标。
- 图标地址由 `scripts/gen-covers.py` 从 titledb（美区，再用港区、日区补亚洲版）生成到 `Covers.swift`，只存地址，仓库和 Release 里不放图片；目前覆盖 96 款中的 95 款。
- 列表里出现哪款才下载哪款，缩到 256 px 缓存在 `~/Library/Caches/sw-launcher/covers`。不用第三方图片站。
- 设置 → 系统 可关闭“显示游戏封面”（关闭后不再联网下载，只用本机已有的图标）。

**完成标准**

- [x] 功能达标：真实数据截图里各游戏显示官方图标。
- [x] 能跑：`./build.sh` 成功。
- [x] 测试通过：`./scripts/test.sh` 全部通过（解包图标查找、设置往返）。

## phase/07-slim-settings

**目标**：设置窗口只保留主窗口里没有的东西。

**设计要点**

- 六页减为四页：通用（游戏语言、显示封面、版本与链接）、游戏（选中游戏的帧率 / 线程 / 着色器等）、环境（不变）、高级（构建工具目录、生成位置、构建文件夹、Xcode 工作区）。
- 去掉：游戏文件页、存档与 Mods 页（都在主窗口详情面板）、系统页的本机信息和运行要求（状态栏已显示）、高级里重复的构建目标 / Team ID。
- 版本号改为读取 Info.plist，发版时不用再改界面代码。
- 封面加载：启动时先把本机缓存一次读进来，再在后台同时下载 8 张缺的（官方 CDN 只有约 1 MB 的原图，没有小图）；清空缓存实测约 60 秒拉完 89 张，之前要滚到哪一行才下载哪一行。

**完成标准**

- [x] 功能达标：四页截图检查正常。
- [x] 能跑：`./build.sh` 成功。
- [x] 测试通过：`./scripts/test.sh` 全部通过。
