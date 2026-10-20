# sw-launcher 设计：两款游戏共用一个启动器 + RomFS Mods

日期：2026-10-20
仓库：`~/Games/Switch/TOTK-macos-launcher`（GitHub `elisezhu123/switch-macos-launcher`）

## 意图

现在的「王国之泪启动器」是一个 Ryujinx 风格的 macOS 启动器。它下载上游 MacNativeGames（固定到提交 `41e1e0c`），
打上本仓库的 `totk-mac-fixes.patch`，再用玩家自己的游戏文件、keys 和固件构建并启动原生 Mac 版王国之泪。

旷野之息（BOTW）的原生移植已经能启动，并画出开场画面（2026-10-20，见 MacNativeGames `games/botw/README.md`）。
这次要把它做成同一个启动器里的第二款游戏，并把设置里预留的 Mods 入口真正做出来。

启动器本身不带任何游戏内容、keys 或固件。它记录并执行的是“怎么移植”：对上游代码打什么补丁、按什么步骤构建、
用什么参数启动。玩家的游戏文件只在玩家自己的 Mac 上处理。

## 目标

1. **改名**：App、窗口标题、README、Release 包名都改为 `sw-launcher`。GitHub 仓库名不变。
2. **两款游戏**：游戏库里有王国之泪（TOTK）和旷野之息（BOTW）。每款游戏各自有：
   - 游戏文件、更新文件的设置（keys、固件两款共用）；
   - 构建流程、输出的 App、工作目录；
   - 存档、着色器缓存、日志、游戏槽位目录（`~/Library/Application Support/MacNativeGames/<TOTK|BOTW>/`，
     `~/Library/Logs/MacNativeGames/<totk|botw>.log`）；
   - 启动方式（可执行文件、环境变量、判断“已启动”的日志关键字）。
   选 BOTW 时，构建、启动、导入存档、日志全部走 BOTW 的那一套。两款游戏互不覆盖对方的文件。
   **玩家的使用流程（用户确认）**：在启动器里选中游戏，选好游戏文件、更新文件、keys、固件的路径，点“构建”
   （也就是移植），看进度条一步步走完；完成后点“启动”就能玩。中间不需要打开终端，也不需要手动跑任何脚本。
   BOTW 和 TOTK 用同样的流程和同样的进度条样式（分步显示，失败时能展开日志看原因）。
   第一次启动时要编译着色器，会比之后慢，界面上要提前说明。
3. **补丁包含 BOTW 移植**：启动器自带的补丁里包含 BOTW 移植所需的全部源码改动，安装构建工具时自动打上。
4. **RomFS Mods**（两款游戏都支持）：
   - 格式与 Ryujinx 相同：`<Mods 目录>/<mod 名>/romfs/...`，按 RomFS 内路径替换游戏原有文件。
   - 每个 mod 可以在启动器里单独开关；多个 mod 改了同一个文件时，按列表顺序，后面的覆盖前面的，界面上要标出冲突。
   - 改动 mod 不需要重新构建游戏，下次启动生效。
   - 关掉所有 mod 时，游戏读到的必须是原版文件，与没有这个功能时完全一样。

## 非目标（这一轮不做）

- ExeFS 补丁（`.ips` / `.pchtxt`）和金手指（Atmosphere `cheats/`）。
- BOTW 的 MetalFX 和补帧（120 帧）。它们需要先找出 BOTW 的场景画面、界面层、深度和摄像机数据，
  而且 BOTW 现在画面偏暗。排在下一轮。
- BOTW 的帧率、分辨率游戏补丁，DLC，其他游戏。
- 修改 GitHub 仓库名。

## 反目标（做出来也算失败的情况）

- 启动器、补丁或 Release 里带有任何游戏数据、keys、固件或游戏素材。
- 选了一款游戏，却改动或删除了另一款游戏的存档、缓存或构建产物。
- 已经在用 v1.0.1 的 TOTK 玩家升级后存档丢失，或者被迫重新构建才能继续玩。
- Mod 悄悄改坏原版：关掉 mod 后读到的不是原版文件，或者 mod 文件不完整却不报错。
- 启动一款游戏时把另一款正在运行的游戏，或者其他程序的进程杀掉
  （现在的 `launch()` 用 `pkill -f totk-native`，它会误杀任何命令行里带这个字符串的进程）。

## 约束

- 上游固定在 `41e1e0c`。所有改动以补丁形式发布，补丁必须能在干净的 `41e1e0c` 上 `git apply` 成功。
- 本机 `~/Sites/MacNativeGames` 里除了 BOTW 的工作，还有其他会话没提交的改动（`services.c`、`nvn_mtl.m` 等）。
  补丁只能收录 BOTW 和 Mods 需要的改动，并且要在一份干净的 `41e1e0c` 副本上重新验证；
  不能把本机工作区的全部差异直接打包。
- 现有 TOTK 的行为保持不变：BOTW 相关的运行时改动对 TOTK 必须没有影响（例如 `hle_nvn.c` 的深度模式默认值，
  TOTK 会显式设置同一个值）。
- BOTW 支持的版本：基础游戏加 1.9.0 更新，按 ExeFS 哈希识别（`games/botw/versions.json`）。
  其他版本要明确提示“不支持”。
- 已知问题：作者手上那份 BOTW 1.9.0 更新 NSP 有 1 MiB 损坏（RomFS IVFC 校验不通过）。
  构建必须做 IVFC 校验。**用户决定**：只放行这一处已知损坏，其他任何损坏都要停下。
  具体规则是：坏块全部落在 RomFS 文件 `Sound/Resource/Stream/Event_BGM_CompleteMasterSword.bfstm` 之内时，
  照常构建，但在进度界面和日志里明确提示“更新文件有一处已知损坏，只影响拔出大师之剑时的一段背景音乐”；
  只要有一个坏块落在这个文件之外（或者基础游戏本身有坏块），就停止构建，提示玩家换一份干净的更新文件，
  并列出出问题的文件。放行规则按 RomFS 内的文件判断，不绑定某一份 NSP 的哈希，所以别人下到同样损坏的文件也能用。
  这段音乐播放时会不会出错（杂音、卡住或者崩溃）还没有验证，要在已知问题里写明。
- 要求 macOS 26+、Metal 4、Apple 芯片（与现在一致）。

## 已经定下来的做法

- **用户已确认**：沿用现有启动器，只改名为 sw-launcher；这一轮只支持 TOTK 和 BOTW；Mods 只做 RomFS 替换；
  公开发布到 GitHub；游戏、keys、固件由玩家自己提供。
- **我的决定**（可以推翻）：
  - BOTW 的移植代码放进启动器自带的补丁里（可以是同一个补丁，也可以分成 `totk-mac-fixes.patch` 和
    `botw-port.patch` 两个，按顺序打）。
  - Mods 的选择和顺序按游戏分开保存。
  - Mods 在运行时通过现有的 RomFS 覆盖层（`games/totk/runtime/romfs.c`）接入，不在构建时改写游戏数据。
    现有覆盖层只能替换已有文件，最多 16 个，还会严格校验哈希；需要扩展成能容纳大量 mod 文件，
    并且只校验 mod 文件自身是否完整。
  - BOTW 必须同时提供基础游戏和 1.9.0 更新；只给基础游戏时，在构建前就提示需要更新文件。
  - Mods 目录两种结构都认：`<Mods 目录>/<mod 名>/romfs/...`，以及 Ryujinx 的
    `<Mods 目录>/contents/<游戏 ID>/<mod 名>/romfs/...`（按游戏 ID 只取当前游戏的 mod）。这样玩家可以直接把
    Ryujinx 的 mods 文件夹拿来用。
  - 构建完成后不自动启动，只显示“构建完成，可以启动了”，由玩家点“启动”（和现在一样）。
  - 判断“游戏是否在运行”、启动前清理旧进程，都改为使用现有的游戏槽位机制（`runtime/game_slot.c` 的锁和
    holder 文件），并且只针对当前这款游戏的进程，不再用 `pkill -f`。
  - BOTW 的预编译着色器（Metal Toolchain）和 TOTK 一样是可选项。
  - BOTW 在启动器里显示“实验性”标签，并写明现状：能启动并画出开场，光照不完整，未经长时间游玩验证。

- **用户决定**：界面沿用现有这一套，不重新设计。直接在 `switch-macos-launcher` 仓库里改。
  BOTW 作为游戏库里的第二个条目出现（列表 / 网格里已有的条目样式），选中哪个条目，构建、启动、设置就针对哪款游戏。

## 留给开发者决定的

- 在现有界面里把“每款游戏各自的设置”（游戏文件、更新文件、输出 App、Mods）放在哪里，改动越小越好。
- BOTW 构建流程的具体实现。可以扩展 `build_app.py`，也可以给 BOTW 写单独的构建入口。现有的零散脚本是
  `games/botw/scripts/extract_exefs.py`、`prepare_runtime.py`、`prepare_romfs_backend.py`、`build_native.sh`；
  进度显示要和 TOTK 一样分步。
- BOTW 启动时需要的运行时开关。目前验证用的是：`TOTK_GPU_ALLOW_SUBMIT=1 TOTK_GPU_WIDEN=1
  TOTK_GPU_BLOCKRT=1 TOTK_GPU_MIDCLEAR=1 TOTK_GPU_BUDGET_MB=5000 TOTK_ALIAS_GIB=12 TOTK_ROMFS_PATCHES=0`，
  要整理成打包后 App 自己带的默认值。
- Mod 覆盖层的数据格式、mod 的扫描和校验方式，以及 mod 里出现原版没有的新文件时怎么处理
  （至少要清楚提示“不支持新增文件”）。
- 从 v1.0.1 升级的迁移：旧设置文件和已经构建好的 TOTK App 要继续能用。

## 验收

- 在一份干净的 `41e1e0c` 上打补丁，TOTK 和 BOTW 都能从启动器构建，并且都能启动。
  BOTW 要能看到开场光芒和复苏神庙画面。
- TOTK 的行为和 v1.0.1 一致：原生 2K 启动、存档能读取。
- 一个替换单个贴图或文本的 RomFS mod 在两款游戏里都能生效；关掉后恢复原版；两个 mod 冲突时界面有提示。
- 用作者手上那份有已知损坏的 1.9.0 更新能构建成功，并显示已知损坏的提示。另外，人为在
  `Event_BGM_CompleteMasterSword.bfstm` 之外改坏一个块的副本必须被拦下，并报出出问题的文件。
- 同时只运行一款游戏，启动时不会误杀其他进程。
- Release 包里不含任何游戏数据、keys 或固件。
