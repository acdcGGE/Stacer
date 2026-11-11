# Stacer → loong64 / Deepin 25 移植

把 [acdcGGE/Stacer](https://github.com/acdcGGE/Stacer) v1.8.0（`fab4e5ee57db9ba08ee69a222aa60434e9e1276e`，2026-10-27）移植到 **LoongArch64 / Deepin 25 / Qt 6.8.0**。

本配方目录**不内嵌上游源码**：只保存 pinned commit、补丁、构建脚本和验证证据。`./build.sh` 从零拉源码、打补丁、编译、安装、验证，可在任意 loong64 机器上复现。既可独立作为配方仓库发布，也可作为上游仓库的 `ports/loong64/` 子目录（此时父仓库即上游源码）。

## 验证环境

| 项 | 值 |
|---|---|
| 内核 / 架构 | `6.18.48-loong64-desktop-rolling` / `loongarch64`（dpkg `loong64`） |
| 系统 | Deepin 25 (crimson) |
| CPU | Loongson-3A5000，4 核，`CPU MHz : 2300.00` |
| 编译器 / CMake | GCC 12.3.0 / CMake 3.31.4 |
| Qt | 6.8.0（`libqt6core6 6.8.0+dfsg-0deepin42`，`libqt6svg6 6.8.0-0deepin6`） |
| 上游 | Stacer 1.8.0，Qt6 + CMake，无 x86 汇编/内联 SIMD |

源码 208 个文件在 Qt 6.8 下**首次编译即通过**，无 API 差异。移植的实质问题是依赖、CPU 信息字段假设，以及一个 Qt 6.8 的运行时崩溃。

## 快速开始

```bash
./build.sh                               # 免 root，产出 dist/bin/stacer
./packaging/make-deb.sh                  # Deepin/Debian 系 .deb
./packaging/make-portable.sh             # 通用 Linux tar 包（同架构跨发行版）
cd packaging/archlinux && makepkg -s     # Arch 系 PKGBUILD
```

拷到别的机器**先自检**（单文件、免 root、`--json` 出结构化结果）：

```bash
./scripts/check-target-compat.sh /usr/bin/stacer --json
```

运行：

```bash
LD_LIBRARY_PATH=$PWD/.deps/root/usr/lib/loongarch64-linux-gnu \
QT_QPA_PLATFORM=wayland ./dist/bin/stacer
```

若系统已 `apt install qt6-charts-dev qt6-tools-dev`，脚本会自动使用 `/usr`，不需要 `LD_LIBRARY_PATH`。

## 三组补丁

### 0001 — CPU 信息层适配（`stacer-core/Info/`）

上游把 x86 的 `/proc/cpuinfo` 字段写死了，龙芯内核的字段完全不同：

| 上游假设 | loong64 实际 |
|---|---|
| `physical id` / `core id` | `package` / `core` / `global_id` |
| `cpu MHz`（小写） | `CPU MHz`（大写） |
| `lscpu` 有 `CPU max MHz` | 无频率字段，只有 `Model name` |

补丁内容：拓扑解析同时接受 `package`/`core` 与 `physical id`/`core id`，无拓扑字段时回退到 `lscpu` 的 `Socket(s)` × `Core(s) per socket`，再回退到 `^processor` 计数；频率正则改为大小写兼容的 `^[Cc][Pp][Uu] MHz`；`getCpuCoreCount()` 的 `quint8` 改为 `int`（>255 核会溢出，且静态 `QVector` 以它为尺寸）。

**实测对比**（`tests/run.sh` 链接 `libstacer-core.a` 直接取数，非估算）：

| 指标 | 补丁前 | 补丁后 |
|---|---|---|
| `physicalCoreCount` | 0 | **4** |
| `sysCpuCore` | `"0"` | `"4"` |
| `avgClockMHz` | 0 | **2300** |
| `clocksMHz` | `[]` | `[2300, 2300, 2300, 2300]` |
| `sysCpuSpeed` | `"unknown"` | **"2.3 GHz"** |
| `sysCpuModel` | `Loongson-3A5000` | `Loongson-3A5000` |

原始数据在 `evidence/before.json` / `evidence/after.json`。

### 0002 — Qt 6.8 QtSvg 动画崩溃（`stacer/Pages/`）

**现象**：GUI 启动后约 1 秒内 `realloc(): invalid pointer` → SIGABRT（首次还出现过 SIGBUS）；`minimal` / `offscreen` / `xcb` / `wayland` 四种 QPA 平台全部复现。

**定位过程**（每一步都有对照）：

1. 未打补丁的原始源码重编译后同样崩溃 → 不是移植补丁引入的。
2. 最小 `QChartView` 程序链接同一份 staging `libQt6Charts.so.6` 正常运行 4 秒 → 不是 Qt6Charts ABI 不匹配。
3. gdb 抓栈（免 root，从 Deepin 源 `apt download` 解包 gdb 及其依赖）：

```
#5  realloc()                                  libc.so.6
#6  QArrayData::reallocateUnaligned()          libQt6Core.so.6
#9  QSvgTransformStyle::apply()                libQt6Svg.so.6
#14 QSvgTinyDocument::draw()                  libQt6Svg.so.6
#16 SystemCleanerPage::renderScanner()
#19 QTimer::timeout()
```

完整栈见 `evidence/pristine-crash-backtrace.txt`。

4. **最小复现**：一个不含任何 Stacer 代码的程序，只加载 `scanning.svg`（含 5 个 `<animateTransform>`）并 `setFramesPerSecond(60)`，3 秒内同样 SIGABRT；改为 `setAnimationEnabled(false)` 后稳定存活、0 动画帧。记录见 `evidence/qtsvg-minimal-repro.txt`。

**结论**：Qt 6.8.0 的 QtSvg 动画渲染路径在 loong64 上堆损坏（`QSvgTransformStyle::apply`）。上游 CI 用 Qt 6.11，所以没有暴露。Deepin 25 源里只有 6.8.0，升级 Qt 不现实。

**修复**：新增 `stacer/Pages/Helpers/svg_loader_compat.h`，统一配置 3 处 loader（`SystemCleanerPage` 两个、`SearchPage` 一个），**按 Qt 版本自适应**，避免在其他系统上误伤功能：

| Qt 版本 | 行为 |
|---|---|
| `< 6.8` | 无动画 API，不做配置 |
| `6.8.x` | 默认 `setAnimationEnabled(false)` 渲染静态帧 |
| `>= 6.9` | 保留上游 60 fps 动画 |

以 6.9 为界是保守推断（本机 6.8 复现、上游 6.11 不复现），可用两个编译开关覆盖：

```bash
EXTRA_CMAKE_ARGS="-DCMAKE_CXX_FLAGS=-DSTACER_ENABLE_SVG_ANIMATION" ./build.sh   # 强制动画
EXTRA_CMAKE_ARGS="-DCMAKE_CXX_FLAGS=-DSTACER_DISABLE_SVG_ANIMATION" ./build.sh  # 强制静态
```

代价仅是在 Qt 6.8 上加载图标不再旋转。**注意这是编译期决定**：`#if QT_VERSION` 在构建时就固化进二进制，把 6.8 编出来的包搬到 Qt 6.11 系统上不会自动恢复动画（也不会崩）；想要 60 fps 动画必须在目标机上重编译。其余补丁（0001 CPU 字段、0003 依赖）对 x86_64 / aarch64 无回归。

### 0003 — 打包依赖（`debian/control`）

Deepin 25 loong64 源里 `libqt6opengl6-dev` 的**候选版本为「无」**（`apt-cache policy` 确认），上游 `Build-Depends` 写死它会导致 `dpkg-buildpackage` 直接失败。Qt6 的 OpenGL 头文件/CMake config 由 `qt6-base-dev` 提供、`libOpenGL.so` 由 `libgl-dev` 提供，两者都已在依赖列表中，故移除该行。

### 依赖准备的坑（脚本里已处理）

- Qt6 的 `Qt6Config.cmake` 只在**系统 Qt 前缀**下找组件，光给 `CMAKE_PREFIX_PATH` 无效，必须显式传 `-DQt6Charts_DIR` 和 `-DQt6LinguistTools_DIR`。
- `qt6-tools-dev` 解包出来的 `Qt6LinguistToolsTargets.cmake` 会校验 `lib/qt6/bin/{lconvert,lrelease,lupdate}` 与 `lib/qt6/libexec/{lprodump,lrelease-pro,lupdate-pro}` 是否存在；这些二进制由系统已装的 `qt6-l10n-tools` / `qt6-tools-dev-tools` 提供，脚本把它们软链进 staging 即可，无需 root。

## 验证

`./build.sh` 末尾自动执行 `scripts/90-verify.sh`，也单独运行：

```bash
./scripts/90-verify.sh
```

检查项：ELF 为 LoongArch、`ldd` 无 `not found`、CPU 信息探针 5 项断言、offscreen GUI 存活 5 秒。结果写入 `evidence/verification.json`。

手动实测（补丁后）：`minimal` / `offscreen` / `xcb` 三种平台均存活到 5 秒超时（rc=124），无 abort。

## 跨发行版交付

三种产物，按需选用：

### 1. Debian / Deepin / UOS（`.deb`）

```bash
./packaging/make-deb.sh    # 免 root，dpkg-deb 直接构建
```

产出 `dist/stacer_1.8.0-1_loong64.deb`。这是开发预览包，`Depends` 为手写列表，但已按二进制实测的 ELF 需求加了下限：`libc6 (>= 2.36)`、各 `libqt6* (>= 6.8.0~)`，并补齐了 NEEDED 里原先漏掉的 `libqt6opengl6` / `libglx0` / `libopengl0`；`qt6-wayland`、`qt6-gtk-platformtheme` 降级为 `Recommends`（最小化系统没装也能安装）。理由见下方「跨 Qt 版本兼容边界」。正式发布建议 `sudo apt install qt6-charts-dev qt6-tools-dev debhelper` 后用 `dpkg-buildpackage` 走 `debian/`（0003 补丁已修好 `control`），让 `dh_shlibdeps` 自动算依赖。

### 2. 通用 Linux 便携包（`tar.gz`）

```bash
./packaging/make-portable.sh                 # 纯二进制 + 启动脚本
./packaging/make-portable.sh --bundle-charts # 附带 libQt6Charts.so.6
```

产出两个包（各带 `.sha256`）：`stacer-1.8.0-loong64-linux-portable.tar.gz`（819K，纯二进制）与 `...-portable-bundled.tar.gz`（1.6M，自带 `libQt6Charts.so.6`）。解压执行 `./stacer-run.sh` 即可：脚本自动在常见 multiarch 路径探测 `libQt6Charts.so.6`、按 `WAYLAND_DISPLAY`/`DISPLAY` 选择 QPA 插件，并给出各发行版缺包时的安装提示。目标系统只需有 Qt6 Base/Charts/Svg 与对应平台插件。

两种包都已实测启动存活 5 秒；其中 **bundled 版在完全不设置 `LD_LIBRARY_PATH` 的环境下也能启动**，适合目标机没装 `qt6-charts` 的场景。

**注意：这是跨发行版，不是跨 CPU 架构** —— 二进制是 `loongarch64`。x86_64 / aarch64 上请用下面的 PKGBUILD 或直接在目标机跑 `./build.sh` 从源码编译。

### 3. Arch Linux（`PKGBUILD`）

```bash
cd packaging/archlinux
makepkg -s                              # -> stacer-1.8.0-1-<CARCH>.pkg.tar.zst
makepkg --printsrcinfo > .SRCINFO       # 上传 AUR 时
```

要点：

- `arch=('loong64' 'x86_64' 'aarch64')`，覆盖 Arch 官方系与 Arch Linux Loong64 移植。
- 依赖用 Arch 包名：`qt6-base`、`qt6-charts`、`qt6-svg`、`qt6-tools`（提供 LinguistTools），无需 Deepin 那套 staging 技巧。
- `prepare()` 直接读本配方目录的 `../../patches/*.patch`，补丁不会与主线分叉，**必须在本配方目录内执行 makepkg**（作为上游子目录时即 `ports/loong64/packaging/archlinux/`）。
- 上游 `.gitattributes` 有 `debian export-ignore`，GitHub archive tarball 里没有 `debian/control`，因此 Debian 专用的 0003 补丁会被自动跳过；0001/0002 已用 GNU `patch -p1` 在真实 archive 上验证可应用（含新增文件）。
- Qt >= 6.9 自动保留动画；Qt 6.8 自动降级为静态帧。
- 上游 AUR 已有同名 `stacer` 包，若冲突请改 `pkgname` 或调整 `conflicts`。

正式发布到 AUR 前记得 `makepkg --printsrcinfo > .SRCINFO`；`sha256sums` 已按 pinned commit 的 archive 实测填写（`c254152b…`）。

**验证边界**：本机是 Deepin，没有 `makepkg`，所以 PKGBUILD 未在本机完整执行；但已等价验证：archive 的 sha256 实测、`patch -p1` 在真实 archive 上成功应用 0001/0002（含新增文件）、CMake 编译与 `cmake --install` 全流程通过。在 Arch 上首次构建如报包名差异，按本机 Qt6 包名微调 `depends` 即可。

## 跨 Qt 版本兼容边界

**一句话**：这个 `.deb` 是 `loongarch64` 二进制，只能装在同架构的 Debian 系系统上；运行时 Qt 必须 **≥ 6.8**。在 Qt 6.9 / 6.10 / 6.11 上大概率能跑，但本机只有 Qt 6.8，**没有在别的高版本 Qt 系统上实跑过**，不要当成已验证结论。

### 硬门槛（对已构建 ELF 的实测，不是推测）

| 条件 | 要求 | 证据 |
|---|---|---|
| CPU 架构 | `loongarch64` / dpkg `loong64` | `readelf -h` → `系统架构: LoongArch`；control `Architecture: loong64`。x86_64 上 `dpkg` 直接拒绝 |
| Qt Core | **≥ 6.8** | `.gnu.version_r` 对 `libQt6Core.so.6` 要求符号版本 `Qt_6.8`；Qt 6.0–6.7 会报 `version 'Qt_6.8' not found` |
| 其它 Qt 库 | 只要求 `Qt_6`，但须与 Core 同版本 | Svg/Charts/Network/Widgets/Gui 的 version needs 均为 `Qt_6`；混 minor 时 Qt Charts 用到的 QtGui 私有 API 有风险 |
| glibc | ≥ 2.36 | 二进制引用的最高符号版本 `GLIBC_2.36`（编译机 glibc 2.38） |
| libstdc++ | `GLIBCXX_3.4` / `CXXABI_1.3.13` | GCC 12.3 |
| QPA 插件 | 与系统 Qt 同一次构建 | Qt 插件与 QtGui 是私有 ABI 绑定 |

本机 `readelf -V /lib/loongarch64-linux-gnu/libQt6Core.so.6` 定义了 `Qt_6.4` → `Qt_6.8` 的累加版本节点 —— 这正是 Qt6 做向后兼容的机制，更高 minor 版本会继续保留旧节点。

### Qt 官方承诺的适用范围

[Qt Releases](https://doc.qt.io/qt/qt-releases.html)：Qt 致力于保持同一主版本号下的**向后**二进制兼容（用 6.0.0 编的程序应能在任意 6.x 上运行，反之不成立），但明确附加条件：*相同的工具链（编译器）、相同的系统环境、相同的构建配置*，且仅适用于动态构建。

从 Deepin 的 `6.8.0+dfsg-0deepin42` 跨到 Debian 官方 `6.11`（不同发行版、不同裁剪配置、不同编译器），严格说**落在官方保证范围之外**。经验上能跑，属于「高概率可用」而非「已验证」。

### 四个具体的坑

1. **旧版 deb 的 Depends 没有版本下限**（已修）。Debian 12 / Ubuntu 24.04 的 Qt 是 6.4，`libqt6core6` 存在但不含 `Qt_6.8` 节点 —— `dpkg` 会放行、运行时才炸。现在 `>= 6.8.0~` 会在安装前挡住。已用 `dpkg --compare-versions` 验证：`6.4.2` 被拒，`6.8.0+dfsg-0deepin42` 与 `6.11.1` 通过。
2. **QtSvg 规避是编译期开关**，见 0002。要在 Qt ≥ 6.9 上拿回 60 fps 动画，只能在目标机重编。
3. **不要混 Qt minor 版本**。bundled 便携包原 launcher 会优先加载自带的 6.8 `libQt6Charts.so.6`，在 Qt 6.11 系统上就是混版；已改为**优先系统同版本 Charts**，自带库仅在系统没装时兜底，`STACER_FORCE_BUNDLED_LIBS=1` 可强制。
4. **包名是 Debian 系专用**。`libqt6charts6` / `qt6-qpa-plugins` 在 Arch/Fedora 不存在，那边走 PKGBUILD 或便携包。

### 在目标机上怎么做

```bash
./check-target-compat.sh --json     # 便携包内自带；仓库里是 scripts/check-target-compat.sh
```

单文件、免 root，检查 7 项（架构 / `Qt_6.8` 节点 / glibc / ELF / DT_NEEDED / QPA 插件 / Qt 模块版本一致性），`exit 0` 兼容、`1` 不兼容。若自检全绿但仍想与系统 Qt 完全对齐并恢复动画，最稳的是在目标机跑一次 `./build.sh` 或 `makepkg -s`，0002 会按目标 Qt 版本自动选择动画行为。

## 目录结构

```
meta.env                    pinned commit / 目标环境常量
build.sh                    一键入口
scripts/00-deps.sh          免 root 准备 Qt6Charts + LinguistTools staging
scripts/10-fetch-src.sh     浅克隆 pinned commit 到 .cache/Stacer
scripts/20-apply-patches.sh 幂等应用补丁
scripts/90-verify.sh        构建后验证
scripts/check-target-compat.sh 目标机运行时兼容自检（单文件，也打进便携包）
patches/0001...0003         三组最小补丁（git apply 格式）
tests/                      硬件信息探针（C++ / 链接 stacer-core）
packaging/make-deb.sh       Deepin/Debian .deb（免 root）
packaging/make-portable.sh  通用 Linux tar 包（同架构跨发行版）
packaging/archlinux/PKGBUILD  Arch 系打包配方
evidence/                   before/after JSON、gdb 栈、最小复现记录、环境元数据
```

`.deps/`、`.cache/`、`dist/`、`.packaging/` 均在 `.gitignore` 中，不入库。

## 许可证

上游 Stacer 为 **GPL-3.0**（见上游仓库根目录 `LICENSE`）。本仓库的 `patches/` 是对上游源码的修改，按 GPL-3.0 发布；构建脚本、打包配方、自检脚本与验证证据同样沿用 GPL-3.0。若作为上游仓库的子目录合并，沿用仓库根 `LICENSE` 即可，无需额外文件；若独立发布为单独仓库，请把上游 `LICENSE` 复制到新仓库根目录。

## 已知限制

- Qt 6.8 下 loader 动画自动降级为静态帧；Qt >= 6.9 保留动画，见 0002 的开关。**开关在编译期生效**，搬运二进制不会改变行为。
- 便携包与 `.deb` 都是 `loongarch64` 二进制，跨发行版但**不跨 CPU 架构**；其它架构请用 PKGBUILD 或 `./build.sh` 从源码构建。
- 运行时 Qt 必须 ≥ 6.8、glibc ≥ 2.36；高版本 Qt 上属于「理论兼容、未实机验证」，详见「跨 Qt 版本兼容边界」。
- 上游按发行版检测决定按钮显隐（`app.cpp` 里只认 `ubuntu`），Deepin 上 GNOME 设置页会隐藏 —— 属上游行为，未改动。
- 单实例 QLocalServer、托盘图标等在 `offscreen` 下有 Qt 警告，不影响运行。
