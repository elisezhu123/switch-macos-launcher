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
