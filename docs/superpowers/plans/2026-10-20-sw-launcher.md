# sw-launcher 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「王国之泪启动器」改名为 sw-launcher，加入旷野之息（BOTW 1.9.0），并让 RomFS Mods 真正生效。

**Architecture:** 启动器（Swift，单个 App）按“当前选中的游戏”切换设置、路径、构建命令和启动方式。
游戏侧的改动（BOTW 移植、Mods 覆盖层、BOTW 构建入口）都做在一份干净的上游 MacNativeGames `41e1e0c` 副本上，
作为第二个补丁 `sw-port.patch` 随启动器发布，排在现有的 `totk-mac-fixes.patch` 后面打。
Mods 不改动构建产物：启动器在每次启动前生成一份 `mods.tsv` 清单，游戏运行时按清单替换 RomFS 文件。

**Tech Stack:** Swift 5 / SwiftUI（`swiftc` 直接编译，无 Xcode 工程）、Objective-C（App 内的 `launcher.m`）、C（运行时）、Python 3.14（构建脚本，`unittest`）。

**Spec:** `docs/superpowers/specs/2026-10-20-sw-launcher-design.md`

## Global Constraints

- 上游固定在提交 `41e1e0caf43d58c4af3c478ca2d1bafd9dba7093`。两个补丁按 `totk-mac-fixes.patch` → `sw-port.patch` 的顺序，必须能在干净的上游上 `git apply -p1` 成功。
- 不在任何仓库或 Release 里放游戏数据、keys、固件或游戏素材。
- 名称：App 叫 `sw-launcher.app`，可执行文件叫 `sw-launcher`，Bundle ID 是 `org.macnativegames.sw-launcher`。GitHub 仓库名不变。
- BOTW：基础游戏 ID 是 `01007EF00011E000`，更新 ID 是 `01007EF00011E800`，只支持 1.9.0（ExeFS 哈希见 `games/botw/versions.json`）。
- 每款游戏的数据目录是 `~/Library/Application Support/MacNativeGames/<TOTK|BOTW>/`，日志是 `~/Library/Logs/MacNativeGames/<totk|botw>.log`。
- TOTK 的行为要和 v1.0.1 一致；BOTW 相关的运行时改动不能影响 TOTK。
- 唯一允许的 RomFS 损坏：坏块全部位于 `Sound/Resource/Stream/Event_BGM_CompleteMasterSword.bfstm` 之内。
- Mods 目录结构：`<Mods 目录>/<mod>/romfs/...`，以及 `<Mods 目录>/contents/<游戏 ID>/<mod>/romfs/...`。
- 界面沿用现有这一套，不重新设计。
- macOS 26+、Metal 4、Apple 芯片。

## Review Focus

1. **从 v1.0.1 升级**：旧的 `MacNativeGames/TOTK/launcher.json` 必须原样迁移成 TOTK 的设置，已经构建好的 TOTK App 不用重新构建就能启动（Task 6 的 `testMigratesV101Settings`）。
2. **Mod 里有原版没有的新文件**：不能让游戏启动失败，要跳过这个文件，并在界面上标出“不支持新增文件”（Task 5 的 `test_unknown_path_is_skipped`，Task 7 的 `testNewFileIsReported`）。
3. **Mod 文件在启动之后被删除或改动**：启动时就要检查大小，不一致就清楚地报错，不能读到一半才出错（Task 5 的 `test_size_mismatch_fails_at_start`）。
4. **路径里有空格、中文或单引号**（例如 `~/Games/塞尔达 mods/它's`）：清单和 shell 命令都不能出错（Task 7 的 `testManifestEscapesPaths`，Task 9 的引号测试）。
5. **另一款游戏正在运行时点击启动**：不能杀掉它，要提示“另一款游戏正在运行”（Task 8 的 `testOtherGameRunningBlocksLaunch`）。

---

## 文件结构

**启动器仓库**（`~/Games/Switch/TOTK-macos-launcher`）
- `LauncherCore.swift`（新建）：不依赖界面、可以测试的逻辑，包括 `GameKind`、按游戏划分的设置和迁移、Mods 扫描和清单、运行状态判断。
- `Launcher.swift`（修改）：界面和 `Model`，改为调用 `LauncherCore.swift`。
- `Tests/CoreTests.swift`（新建）+ `scripts/test.sh`（新建）：用 `swiftc` 把 `LauncherCore.swift` 和测试编在一起，自带断言运行器。
- `sw-port.patch`（新建，由 Task 10 生成）、`build.sh`、`scripts/make-release.sh`、`README.md`（修改）。

**游戏侧工作副本**（`~/Games/Switch/sw-upstream`，项目目录外，不发布；只把补丁导出到启动器仓库）
- `games/botw/**`、`games/totk/runtime/game_patches_v190.c`、`game_version.h` 等 BOTW 改动（Task 1）。
- `games/totk/runtime/romfs_mods.c` / `romfs_mods.h`（新建）、`romfs.c`（修改）、`tests/test_romfs_mods.py` + `tests/test_romfs_mods.c`（新建）（Task 5）。
- `games/botw/scripts/romfs_damage.py` + `tests/test_botw_romfs_damage.py`（新建）（Task 3）。
- `build_app.py`（修改）、`games/botw/scripts/build_botw.py`（新建）、`tests/test_botw_build_args.py`（新建）（Task 2）。
- `games/totk/app/launcher.m`、`game_version.h`（修改）（Task 4）。

---

### Task 1：干净的游戏侧工作副本 + 移入 BOTW 移植

**Files:**
- Create: `~/Games/Switch/sw-upstream`（git 工作副本）
- Copy into it: `games/botw/**`、`games/totk/runtime/game_patches_v190.c`，以及 `~/Sites/MacNativeGames` 里属于 BOTW 的修改片段

**Interfaces:**
- Produces: 工作副本里有三个提交：`base`（上游 + `totk-mac-fixes.patch`）、`botw: port`、`botw: NVN default depth mode`。后续任务都在这个副本上继续提交。

- [ ] **Step 1：建立基线。** `git clone https://github.com/ly05010419/MacNativeGames ~/Games/Switch/sw-upstream && cd ~/Games/Switch/sw-upstream && git checkout -b sw 41e1e0caf43d58c4af3c478ca2d1bafd9dba7093 && git apply -p1 ~/Games/Switch/TOTK-macos-launcher/totk-mac-fixes.patch && git add -A && git commit -m "base: upstream 41e1e0c + totk-mac-fixes.patch"`
- [ ] **Step 2：找出属于 BOTW 的修改片段。** `~/Sites/MacNativeGames` 里这些已修改的文件还混有其他会话的工作：`account.c applet_host.c audio_mixer.h audio_renderer.c fs_host.c game_version.h input.c loader.c romfs.c services.c world_survey.c prepare_romfs_backend.py prepare_runtime.py patch_nso.py nvn_mtl.m`。把 `~/.claude/projects/-Users-elise123/00f6867e-2af1-446e-bc2f-ee46fef5a069.jsonl`（BOTW 会话）里的 Edit/Write 调用作为依据，只拿 BOTW 会话写的那些片段；它们对应 `games/botw/README.md` “Host calls BOTW makes that TOTK never did”一节列出的调用，以及 `patch_nso.py` 的三个 BOTW 跳转表、`prepare_*.py` 的 `--version v190`。`nvn_mtl.m` 和 `services.c` 里其他会话的改动一个都不要。把清单写进提交说明。
- [ ] **Step 3：搬进 BOTW 片段和 `games/botw/**`、`game_patches_v190.c`，然后提交** `botw: port`。
- [ ] **Step 4：加上深度模式默认值的修复**（与 `~/Sites/MacNativeGames` 的 `hle_nvn.c` 改动相同，即 `nvnDeviceInitialize` 把 `g_depth_near_minus_w` 设为 1），然后提交 `botw: NVN default depth mode is NEAR_IS_MINUS_W`。
- [ ] **Step 5：验证 TOTK 没被影响。** 运行 `python3.14 -m unittest discover -s tests -v`，结果要和基线一样（先在 `base` 提交上跑一次，记下通过数）。
- [ ] **Step 6：验证 BOTW 能编译。** 运行 `games/botw/scripts/build_native.sh <BOTW 数据目录> /tmp/sw-botw-out <字体配置目录>`，结果要以 `BUILD_OK` 结束（BOTW 数据目录用 BOTW 会话 scratchpad 里的 `tree`）。

### Task 2：BOTW 构建入口（进度格式和 TOTK 一样）

**Files:**
- Create: `games/botw/scripts/build_botw.py`
- Modify: `build_app.py`（`parse_args` 和 `main`）：加上 `--title {totk,botw}`，默认 `totk`；选 `botw` 时把参数原样交给 `build_botw.main`
- Test: `tests/test_botw_build_args.py`

**Interfaces:**
- Consumes: `games/botw/scripts/extract_exefs.py`、`extract_update_romfs.py`、`extract_romfs.py`、`build_native.sh`；`build_app.py` 里的 `prerequisites`、`build_hactool`、`build_spirv_cross`、`step_shaders`、`sign_app`、`say`、`run`；Task 3 的 `check_damage`；Task 4 的 BOTW App 结构。
- Produces: 命令 `python3.14 build_app.py --title botw <base.nsp> --update <1.9.0.nsp> -k <keys> --firmware <dir> --work <dir> -o <BOTW.app>`。输出里有四行进度 `1/4 code`、`2/4 data`、`3/4 update`、`4/4 app`（`shaders` 的位置和 TOTK 一致），启动器的正则 `(\d)/4 (\w+)` 不用改。失败时退出码不为 0，最后一行以 `ERROR:` 开头。

- [ ] **Step 1：写失败的测试** `tests/test_botw_build_args.py`：
  - `test_update_required`：不带 `--update` 调用 `build_botw.parse_args` 时，抛出的 `SystemExit` 消息里包含 `BOTW needs the 1.9.0 update`。
  - `test_title_routes_to_botw`：`build_app.parse_args(['--title','botw', 'b.nsp','--update','u.nsp','-k','k'])` 返回的 `title == 'botw'`。
  - `test_default_title_is_totk`：不带 `--title` 时 `title == 'totk'`。
- [ ] **Step 2：运行** `python3.14 -m unittest tests.test_botw_build_args -v`，预期全部 FAIL。
- [ ] **Step 3：实现。** 编写 `build_botw.parse_args(argv) -> Namespace` 和 `build_botw.main(args) -> int`，以及 `build_app.py` 里的路由。步骤顺序：ExeFS 哈希识别（不是 1.9.0 就报 `ERROR: unsupported BOTW version`），改写代码，合并 RomFS 并调用 `check_damage`，`prepare_runtime/prepare_romfs_backend --version v190`，着色器，原生程序，打包 App。
- [ ] **Step 4：运行测试**，预期 PASS。
- [ ] **Step 5：真实构建一次**（用作者的 BOTW 文件），输出里要有四个 `n/4` 进度行和已知损坏的提示，最后生成 `BOTW.app`。
- [ ] **Step 6：提交** `botw: build entry with launcher progress lines`。

### Task 3：RomFS 损坏判定（只放行那一处已知损坏）

**Files:**
- Create: `games/botw/scripts/romfs_damage.py`
- Test: `tests/test_botw_romfs_damage.py`

**Interfaces:**
- Produces: `check_damage(bad_ranges: list[tuple[int,int]], files: list[tuple[str,int,int]]) -> DamageVerdict`，其中 `bad_ranges` 是 RomFS 数据区里的坏字节区间 `(offset, end)`，`files` 是 `(romfs 路径, 偏移, 大小)`。`DamageVerdict` 有三个字段：`ok: bool`、`known: bool`、`offending: list[str]`。常量 `ALLOWED = 'Sound/Resource/Stream/Event_BGM_CompleteMasterSword.bfstm'`。另外提供 `KNOWN_DAMAGE_MESSAGE = '更新文件有一处已知损坏，只影响拔出大师之剑时的一段背景音乐'`。

- [ ] **Step 1：写失败的测试**：
  - `test_no_damage`：`check_damage([], files)` 返回 `ok=True, known=False, offending=[]`。
  - `test_known_damage_only`：坏区间完全落在 `ALLOWED` 文件内时，返回 `ok=True, known=True`。
  - `test_damage_elsewhere`：坏区间落在 `Actor/Pack/X.sbactorpack` 内时，返回 `ok=False, offending=['Actor/Pack/X.sbactorpack']`。
  - `test_mixed`：一段在 `ALLOWED` 内、一段在别的文件里时，返回 `ok=False`，`offending` 里只有那个别的文件。
  - `test_damage_outside_any_file`（落在文件表或者文件之间的空隙）：返回 `ok=False, offending=['<RomFS metadata>']`。
- [ ] **Step 2：运行** `python3.14 -m unittest tests.test_botw_romfs_damage -v`，预期 FAIL。
- [ ] **Step 3：实现 `check_damage`**，然后在 Task 2 的合并步骤里用它。合并时把 IVFC 第 6 层坏块的位置换算成 RomFS 偏移传进来，不能一碰到坏块就停（现在 `extract_update_romfs.py` 用的 `require(... GOOD ...)` 要改成“收集坏块 → 判定”）。基础游戏本身的坏块一律不放行。
- [ ] **Step 4：运行测试**，预期 PASS。
- [ ] **Step 5：实测。** 用作者的 1.9.0 更新构建，要通过，并打印 `KNOWN_DAMAGE_MESSAGE`。再复制一份，把 RomFS 中别的文件（如 `Pack/Bootup.pack` 所在区域）里的一个字节翻转后构建，必须失败，并报出那个文件名。
- [ ] **Step 6：提交** `botw: allow only the known BGM damage in the 1.9.0 RomFS`。

### Task 4：App 内启动器（`launcher.m`）按游戏区分 + 传入 Mods 清单

**Files:**
- Modify: `games/totk/runtime/game_version.h`：给每个版本分支加上 `TOTK_GAME_DATA_NAME`（`"TOTK"` / `"BOTW"`）、`TOTK_GAME_LOG_NAME`（`"totk"` / `"botw"`）、`TOTK_GAME_BINARY`（`"totk-native"` / `"botw-native"`）
- Modify: `games/totk/app/launcher.m`：所有写死的 `TOTK`、`totk`、`totk-native` 改用这三个宏；如果 `<data>/mods.tsv` 存在，就 `setenv("TOTK_MODS_MANIFEST", <路径>, 1)`

**Interfaces:**
- Produces: 打包好的 BOTW App 结构和 TOTK 一样，可执行文件在 `Contents/Resources/totk/build/botw-native`；数据目录、日志、游戏槽位分别是 `MacNativeGames/BOTW/...`、`botw.log`、`MacNativeGames/BOTW/game-slot`。运行时会读环境变量 `TOTK_MODS_MANIFEST`。

- [ ] **Step 1：写失败的测试** `tests/test_launcher_names.py`：用 `-DTOTK_GAME_V190` 和默认的 TOTK 宏各预处理一次 `launcher.m`（`xcrun clang -E`），断言 BOTW 版里出现 `MacNativeGames/BOTW`、`botw.log`，并且不出现 `"TOTK"`；TOTK 版的这几处和改动前完全相同。
- [ ] **Step 2：运行**，预期 FAIL。
- [ ] **Step 3：实现。**
- [ ] **Step 4：运行这个测试和全部测试**，预期 PASS。
- [ ] **Step 5：提交** `app: per-game data, log and binary names; pass mods manifest`。

### Task 5：运行时 Mods 覆盖层

**Files:**
- Create: `games/totk/runtime/romfs_mods.h`、`romfs_mods.c`
- Modify: `games/totk/runtime/romfs.c`（`overlay_init`、打开文件时查找覆盖层的地方 `:208`、`handle_source` `:212-215`）；把 `romfs_mods.c` 加进 `Makefile`、`build_native.sh` 和 Task 2 的构建
- Test: `tests/test_romfs_mods.c`、`tests/test_romfs_mods.py`（写法照 `tests/test_romfs_paths.py`）

**Interfaces:**
- Consumes: `TOTK_MODS_MANIFEST`（Task 4）。清单是 UTF-8 文本，每行一个文件：`<romfs 路径>\t<主机绝对路径>\t<大小>`；路径里不会出现制表符和换行（Task 7 保证）。
- Produces:
  - `int mods_parse(const char *text, size_t len, mods_t *out, char *err, size_t errlen)`：返回 0 表示成功。
  - `const mods_entry *mods_find(const mods_t *m, const char *romfs_path)`：按路径做二分查找。
  - `void mods_free(mods_t *m)`。
  - `romfs.c` 的规则：内置覆盖层（游戏修复）优先，被它占用的路径上的 mod 文件跳过，并打印 `[totk] mod: <path> ignored (built-in fix)`；RomFS 里没有的路径也跳过，打印 `[totk] mod: <path> not in the game (new files are not supported)`；文件数量不设上限（动态数组）。启动时用 `stat` 检查每个 mod 文件的大小，不一致就 `runtime_fail("mod file changed since the launcher listed it: <path>")`。不计算 mod 文件的哈希。没有清单时，行为和原来一样。

- [ ] **Step 1：写失败的测试**（C 程序只编译 `romfs_mods.c`，Python 负责编译和运行）：
  - `test_parse_and_find`：三行清单，`mods_find` 能找到其中两条，不存在的路径返回 NULL。
  - `test_bad_line_fails`：缺字段的行让 `mods_parse` 返回非 0，并在 `err` 里写明行号。
  - `test_duplicate_path_last_wins`：同一路径出现两次，取后面那条（清单由启动器按顺序写出）。
  - `test_unknown_path_is_skipped` 和 `test_size_mismatch_fails_at_start`：这两项放在 `probe-fs` 层面测。用 `tests/` 已有的 RomFS 测试镜像（没有的话就做一个只含两个文件的小镜像）运行 `probe-fs`，断言输出包含 `not in the game`，以及大小不一致时退出码非 0、输出含 `mod file changed`。
- [ ] **Step 2：运行** `python3.14 -m unittest tests.test_romfs_mods -v`，预期 FAIL。
- [ ] **Step 3：实现。**
- [ ] **Step 4：运行这些测试和全部测试**，预期 PASS。
- [ ] **Step 5：实测。** 两款游戏各用一个替换单个文本或贴图的 mod，在游戏里能看到变化；把清单删掉后恢复原样。
- [ ] **Step 6：提交** `runtime: RomFS mods from TOTK_MODS_MANIFEST`。

### Task 6：启动器的游戏模型和按游戏划分的设置（含 v1.0.1 迁移）

**Files:**
- Create: `LauncherCore.swift`、`Tests/CoreTests.swift`、`scripts/test.sh`（`swiftc -parse-as-library LauncherCore.swift Tests/CoreTests.swift -o /tmp/sw-core-tests && /tmp/sw-core-tests`，所有断言通过时打印 `ALL PASS`）
- Modify: `Launcher.swift`：`Paths`、`LauncherSettings`、`Model.entry`、`titleID`、`gameVersion`、`shaderDir`、所有 `Paths.support` / `Paths.log` 的用法

**Interfaces:**
- Produces:
  - `enum GameKind: String, Codable, CaseIterable { case totk, botw }`，属性有 `displayName`（`"塞尔达传说 王国之泪"` / `"塞尔达传说 旷野之息"`）、`englishName`、`titleID`（`0100F2C0115B6000` / `01007EF00011E000`）、`dataName`（`TOTK`/`BOTW`）、`logName`、`binaryName`、`defaultAppName`（`Tears of the Kingdom.app` / `Breath of the Wild.app`）、`buildTitleArg`（`totk`/`botw`）、`experimental`（BOTW 为 `true`）。
  - `struct GamePaths { init(_ g: GameKind, home: URL) }`，属性有 `support`、`log`、`profileSave`、`shaderDir`、`modsManifest`、`gameSlot`。
  - `struct GameSettings: Codable { var game, update, save, mods, outputApp, workDir: String; var modOrder: [String]; var modsEnabled: [String: Bool] }`
  - `struct LauncherSettings: Codable { var selected: GameKind; var games: [GameKind: GameSettings]; var keys, firmware, language, projectDir: String }`
  - `static func load(from: URL, legacy: URL) -> LauncherSettings`：新的设置文件放在 `MacNativeGames/sw-launcher/launcher.json`。新文件不存在、而旧的 `MacNativeGames/TOTK/launcher.json` 存在时，把旧文件里的 `game/update/save/mods/outputApp/workDir` 迁移成 `games[.totk]`，`keys/firmware/language/projectDir` 迁移到顶层。旧文件保留不动。

- [ ] **Step 1：写失败的测试**（`Tests/CoreTests.swift`）：
  - `testMigratesV101Settings`：用一份 v1.0.1 格式的 JSON（含 `game、update、keys、firmware、save、mods、language、projectDir、outputApp、workDir`），迁移后每个字段都落在对应位置，`selected == .totk`，旧文件的字节没有变化。
  - `testBotwPaths`：`GamePaths(.botw, home: h).log == h/Library/Logs/MacNativeGames/botw.log`，`support` 以 `MacNativeGames/BOTW` 结尾。
  - `testTotkPathsUnchanged`：TOTK 的 `support`、`log`、`shaderDir` 和 v1.0.1 完全相同。
  - `testBotwDefaults`：`games[.botw]` 不存在时，默认 `outputApp` 以 `Games/MacNative/Breath of the Wild.app` 结尾，`workDir` 以 `Games/MacNative/BOTW_build` 结尾。
- [ ] **Step 2：运行** `scripts/test.sh`，预期编译失败或断言失败。
- [ ] **Step 3：实现 `LauncherCore.swift`**，并把 `Launcher.swift` 改成使用它。界面结构不变：游戏库列表或网格里显示两个条目（`GameKind.allCases`），点击条目会设置 `selected`；“游戏文件”设置页、构建、启动、导入存档、日志按钮都针对 `selected`。BOTW 条目上显示“实验性”标签（复用现有的 `TagView`），没设置游戏文件时显示“未添加”的占位样式（复用 `placeholder`）。
  选中 BOTW 但没设置更新文件时，“构建”按钮不可用，并显示 `"旷野之息需要 1.9.0 更新文件"`。构建完成的提示后面加一句
  `"第一次启动要编译着色器，会比之后慢一些。"`（两款游戏都加）。
- [ ] **Step 4：运行测试** `scripts/test.sh`，预期输出 `ALL PASS`；再运行 `./build.sh`，预期编译成功。
- [ ] **Step 5：截图核对。** 运行 `--demo`，游戏库里有两个条目，选中 BOTW 后，设置页显示 BOTW 自己的路径。
- [ ] **Step 6：提交** `launcher: two games with per-game settings; migrate v1.0.1 settings`。

### Task 7：Mods 扫描、冲突处理和清单（启动器）

**Files:**
- Modify: `LauncherCore.swift`、`Tests/CoreTests.swift`、`Launcher.swift`（把“存档与 Mods”页里的 Mods 区域换成 mod 列表；去掉“暂不生效”标签和那句说明）

**Interfaces:**
- Consumes: `GameKind.titleID`、`GameSettings.modOrder/modsEnabled`、`GamePaths.modsManifest`
- Produces:
  - `struct ModInfo { let name: String; let root: URL; let files: [String] }`，其中 `files` 是 RomFS 内的相对路径，用 `/` 分隔。
  - `func scanMods(dir: URL, titleID: String) -> [ModInfo]`：两种目录结构都认；`contents/<其他游戏 ID>` 下的 mod 不算进来。
  - `func resolveMods(_ mods: [ModInfo], order: [String], enabled: [String: Bool]) -> (winners: [String: (mod: String, file: URL)], conflicts: [String: [String]])`：按 `order`，后面的覆盖前面的；`order` 里没有的 mod 按名字排序后接在后面。
  - `func writeManifest(_ winners: ..., to: URL) throws`：写成 Task 5 的格式，每行的大小取当前文件的大小。路径含有制表符或换行的文件跳过，并报告出来。
  - `func knownRomfsPaths(...)` 不实现。“新增文件”由运行时判断，启动器只显示运行时日志里的 `not in the game` 行（下次打开 Mods 页时，从 `GamePaths.log` 里读取）。
  - 每次点“启动”前都重新扫描并写清单；所有 mod 都关掉时删除清单文件。

- [ ] **Step 1：写失败的测试**：
  - `testScanBothLayouts`：临时目录里放 `A/romfs/x.txt` 和 `contents/01007EF00011E000/B/romfs/y.txt`，`titleID` 为 BOTW 时两个都能扫到；`titleID` 为 TOTK 时只扫到 `A`。
  - `testLaterModWins`：A、B 都包含 `x.txt`，`order=[A,B]` 时取 B 的文件，`conflicts["x.txt"] == ["A","B"]`。
  - `testDisabledModIgnored`：`enabled[B]=false` 时取 A 的文件，也不算冲突。
  - `testManifestEscapesPaths`：mod 目录名是 `塞尔达 mods/它's`，清单里写的是正确的绝对路径；文件名里带制表符的文件被跳过并报告。
  - `testAllDisabledRemovesManifest`。
  - `testNewFileIsReported`：日志里有 `[totk] mod: Foo/bar.txt not in the game` 时，`parseModWarnings(log:)` 返回 `["Foo/bar.txt"]`。
- [ ] **Step 2：运行** `scripts/test.sh`，预期 FAIL。
- [ ] **Step 3：实现**，包括界面：每个 mod 一行，带开关、上移/下移按钮和文件数；有冲突的文件数显示为橙色，点开可以看是哪些文件；有“不支持新增文件”警告的 mod 显示同样的提示。
- [ ] **Step 4：运行测试**，预期输出 `ALL PASS`；`./build.sh` 编译成功。
- [ ] **Step 5：提交** `launcher: RomFS mods list, conflicts and manifest`。

### Task 8：安全启动（不再用 `pkill -f`）

**Files:**
- Modify: `LauncherCore.swift`、`Tests/CoreTests.swift`、`Launcher.swift` 的 `launch()`

**Interfaces:**
- Produces: `enum RunState { case idle, running(pid: Int32), otherGameRunning(GameKind) }`，以及 `func runState(for: GameKind, home: URL) -> RunState`：读取每款游戏的 `game-slot/lock` 和 `holder`，逻辑与 `launcher.m` 里的 `running_game` 相同，即锁被持有、`owner=user`、`game_pid` 和 `game_start` 都对得上。`launch()` 的规则：`running` 时把这款游戏带到前台；`otherGameRunning` 时显示 `"另一款游戏（<名字>）正在运行，请先退出它"`，什么都不做；`idle` 时启动。重试时只检查当前游戏的日志（`GamePaths.log`），不再杀任何进程。

- [ ] **Step 1：写失败的测试**：
  - `testIdleWhenNoLock`。
  - `testOtherGameRunningBlocksLaunch`：用临时 home，在 BOTW 槽位里持有锁，并写一个指向当前测试进程的 `holder`，`runState(for: .totk)` 返回 `.otherGameRunning(.botw)`。
  - `testStaleHolderIsIdle`：`game_pid` 对得上，但 `game_start` 对不上时，返回 `idle`。
- [ ] **Step 2：运行**，预期 FAIL。
- [ ] **Step 3：实现。** 删掉 `launch()` 里的 `pkill -f totk-native`。
- [ ] **Step 4：运行测试**，预期输出 `ALL PASS`。
- [ ] **Step 5：提交** `launcher: slot-based run detection; never pkill`。

### Task 9：改名、打包第二个补丁、安装命令

**Files:**
- Modify: `build.sh`（App 名 `sw-launcher.app`、可执行文件 `sw-launcher`、Bundle ID、显示名，并把 `sw-port.patch` 拷进 Resources）、`scripts/make-release.sh`（包名 `sw-launcher-v<版本>-arm64.zip`）、`Launcher.swift`（窗口标题、关于页、`Model.projectInstallCommand` 和 `makeDeps` 里的 “Mac 兼容补丁” 项）
- Test: `Tests/CoreTests.swift`

**Interfaces:**
- Produces: `func installCommand(project: String, patches: [String]) -> String`：按顺序对每个补丁执行 `git apply -p1`；所有路径都用单引号转义。“Mac 兼容补丁”这一项检查的是两个补丁都已打上（`git apply -p1 --reverse --check`）。
- 已经装好、只打了第一个补丁的旧构建工具目录，要提示“需要更新构建工具”，并给出一个按钮，只补打 `sw-port.patch`。

- [ ] **Step 1：写失败的测试**：`testInstallCommandAppliesBothPatchesInOrder`（第一个补丁先出现）、`testInstallCommandQuotesPaths`（路径含有 `'` 时，命令能被 `/bin/sh -n` 解析）。
- [ ] **Step 2：运行**，预期 FAIL。
- [ ] **Step 3：实现。**
- [ ] **Step 4：运行测试**，预期输出 `ALL PASS`；`./build.sh` 生成 `sw-launcher.app`，`codesign -v` 通过。
- [ ] **Step 5：提交** `rename to sw-launcher; ship sw-port.patch`。

### Task 10：导出补丁、README 和端到端验收

**Files:**
- Create: `sw-port.patch`（`cd ~/Games/Switch/sw-upstream && git diff base..sw > ~/Games/Switch/TOTK-macos-launcher/sw-port.patch`，`base` 是 Task 1 Step 1 的提交）
- Modify: `README.md`（中英文）：改名；支持两款游戏；BOTW 标为实验性，写明现状（能启动、能出开场画面、光照不完整、未经长时间游玩验证）以及需要 1.9.0 更新和已知损坏的说明；Mods 一节改成使用说明（两种目录结构、开关和顺序、冲突规则、不支持新增文件、不支持 ExeFS 补丁和金手指）；重要声明保持不变。`docs/*.png` 用 `--demo` 重新截图。

- [ ] **Step 1：干净复现。** 新建一个空目录，用新 App 的“构建工具”安装按钮装好（两个补丁都要能打上）。
- [ ] **Step 2：TOTK 回归。** 构建并启动 TOTK：以原生 2K 启动，能读取已有存档。另外，用 v1.0.1 的设置文件启动新启动器，设置要自动迁移，旧的 TOTK App 不用重新构建也能直接启动。
- [ ] **Step 3：BOTW。** 用作者的文件构建（要看到已知损坏的提示），然后启动：能看到开场光芒和复苏神庙。再用改坏一个别处字节的副本构建，必须被拦下并报出文件名。
- [ ] **Step 4：Mods。** 两款游戏各验证一次：开关生效；冲突提示正确；有新增文件的 mod 显示警告，游戏照常启动。
- [ ] **Step 5：互斥。** BOTW 运行时点 TOTK 的启动，要看到提示，BOTW 不受影响。
- [ ] **Step 6：发布包检查。** 运行 `scripts/make-release.sh 1.1.0`，用 `unzip -l` 看包里只有 App；`grep -c` 确认两个补丁里没有 `prod.keys` 的内容、没有游戏数据。
- [ ] **Step 7：提交** `release 1.1.0: sw-launcher with BOTW (experimental) and RomFS mods`。不推送，也不发布 Release，这两步留给用户自己做。
