# Stacer → loong64 移植

把 [acdcGGE/Stacer](https://github.com/acdcGGE/Stacer) v1.8.0（`fab4e5ee…`，2026-10-27）移植到 **LoongArch64**。首验 Deepin 25 / Qt 6.8.0，复验 Debian sid / Qt 6.11.2（Arch Linux Loong64 亦曾构建验证）。

本配方目录**不内嵌上游源码**，只保存 pinned commit、补丁、构建脚本与验证证据；`./build.sh` 从零拉源码、打补丁、编译、安装、验证。既可独立作为配方仓库，也可作为上游仓库的 `ports/loong64/` 子目录（此时父仓库即源码）。

## 验证环境

| | 内核 / 系统 | 编译器 / CMake | Qt |
|---|---|---|---|
| 首验 2026-11-11 | `6.18.48-loong64-desktop-rolling` / Deepin 25 (crimson) | GCC 12.3.0 / CMake 3.31.4 | 6.8.0（`+dfsg-0deepin42`） |
| 复验 2026-11-12 | `6.18.57-loong64-gxde-desktop` / Debian forky/sid | GCC 16.2.0 / CMake 4.3.4 | 6.11.2（`t64` 包名经版本化 `Provides` 满足旧名） |

两台均为 Loongson-3A5000 4 核 @2300 MHz；复验机 GPU 为 AMD Oland PRO（GCN 1.0 / SI，`amdgpu`）。源码 208 个文件在 Qt 6.8 与 6.11 下**首次编译即通过**，无 API 差异——移植的实质问题是依赖、CPU 字段假设、一个 Qt 6.8 运行时崩溃，以及老 A 卡读不出 GPU 占用。

## 快速开始

```bash
./build.sh                      # 免 root，产出 dist/bin/stacer
./packaging/make-deb.sh         # Deepin/Debian 系 .deb
./packaging/make-portable.sh    # 通用 Linux tar 包（同架构跨发行版）
cd packaging/archlinux && makepkg -s    # Arch 系

./scripts/check-target-compat.sh /usr/bin/stacer --json   # 拷到别的机器先自检

LD_LIBRARY_PATH=$PWD/.deps/root/usr/lib/loongarch64-linux-gnu \
QT_QPA_PLATFORM=wayland ./dist/bin/stacer
```

系统已 `apt install qt6-charts-dev qt6-tools-dev` 时脚本自动用 `/usr`，无需 `LD_LIBRARY_PATH`。

## 四组补丁

### 0001 — CPU 信息层适配（`stacer-core/Info/`）

上游把 x86 的 `/proc/cpuinfo` 字段写死，龙芯内核字段不同：`physical id`/`core id` → `package`/`core`/`global_id`；`cpu MHz` → `CPU MHz`（大写）；`lscpu` 无 `CPU max MHz`，只有 `Model name`。

补丁：拓扑解析同时接受两套字段，无拓扑时回退 `lscpu` 的 `Socket(s)`×`Core(s) per socket`，再回退 `^processor` 计数；频率正则改为大小写兼容 `^[Cc][Pp][Uu] MHz`；`getCpuCoreCount()` 的 `quint8` 改 `int`（>255 核溢出，且静态 `QVector` 以它为尺寸）。

**实测**（`tests/run.sh` 链接 `libstacer-core.a` 直接取数）：

| 指标 | 补丁前 | 补丁后 |
|---|---|---|
| `physicalCoreCount` / `sysCpuCore` | 0 / `"0"` | **4** / `"4"` |
| `avgClockMHz` / `clocksMHz` | 0 / `[]` | **2300** / `[2300×4]` |
| `sysCpuSpeed` | `"unknown"` | **"2.3 GHz"** |

原始数据见 `evidence/before.json` / `after.json`。

### 0002 — Qt 6.8 QtSvg 动画崩溃（`stacer/Pages/`）

**现象**：GUI 启动 ~1 秒内 `realloc(): invalid pointer` → SIGABRT（首现还有 SIGBUS），`minimal`/`offscreen`/`xcb`/`wayland` 四种 QPA 全复现。

**定位**（每步带对照）：① 原始源码重编译同样崩 → 非移植补丁引入；② 最小 `QChartView` 程序链同一份 staging `libQt6Charts.so.6` 正常跑 4 秒 → 非 Charts ABI；③ gdb 抓栈（免 root，从 Deepin 源 `apt download` 解包 gdb）：`realloc` ← `QArrayData::reallocateUnaligned` ← **`QSvgTransformStyle::apply`** ← `QSvgTinyDocument::draw` ← `renderScanner()` ← `QTimer::timeout`；④ **最小复现**：不含任何 Stacer 代码的程序只加载 `scanning.svg`（5 个 `<animateTransform>`）并 `setFramesPerSecond(60)`，3 秒内同样 SIGABRT，改 `setAnimationEnabled(false)` 后稳定存活 → **Qt 6.8.0 的 QtSvg 动画渲染路径在 loong64 上堆损坏**，上游 CI 用 6.11 故未暴露，Deepin 源只有 6.8.0。

**修复**：新增 `stacer/Pages/Helpers/svg_loader_compat.h`，统一配置 3 处 loader（`SystemCleanerPage` 两个、`SearchPage` 一个），按 Qt 版本自适应：

| Qt | 行为 |
|---|---|
| `< 6.8` | 无动画 API，不配置 |
| `6.8.x` | 默认 `setAnimationEnabled(false)`，渲染静态帧 |
| `>= 6.9` | 保留上游 60 fps |

6.9 是保守推断，可用 `-DSTACER_ENABLE_SVG_ANIMATION` / `-DSTACER_DISABLE_SVG_ANIMATION`（经 `EXTRA_CMAKE_ARGS` 传）覆盖。**这是编译期决定**：6.8 编出的包搬到 6.11 系统不会恢复动画（也不会崩），要 60 fps 只能在目标机重编。其余补丁对 x86_64 / aarch64 无回归。

### 0003 — 打包依赖（`debian/control`）

Deepin 25 loong64 源里 `libqt6opengl6-dev` **候选版本为「无」**（`apt-cache policy` 确认），上游 `Build-Depends` 写死它会让 `dpkg-buildpackage` 直接失败。其头文件/CMake config 由 `qt6-base-dev` 提供、`libOpenGL.so` 由 `libgl-dev` 提供，二者已在依赖列表，故移除该行。

### 0004 — 温度 / GPU 监控（`stacer-core/Info/` + Dashboard/Resources 页）

新增 `SensorInfo` 传感器层并接入 UI：

- **CPU/GPU 温度**：遍历 `/sys/class/hwmon`，按芯片名分类（`coretemp`/`k10temp`/`zenpower`/`cpu_hwmon` → CPU，`amdgpu`/`radeon`/`nouveau` → GPU），读 `temp*_input`、`temp*_label`。
- **磁盘温度**：hwmon 的 `drivetemp`/`nvme` 优先；否则对整盘块设备（`sd[a-z]`/`hd[a-z]`/`vd[a-z]`/`nvmeXnY`）跑 `smartctl -A` 解析，未装 `smartmontools` 则静默跳过。
- **GPU 占用**，按优先级回退：① amdgpu `gpu_busy_percent`（GCN 2.0+）→ ② `/proc/*/fdinfo` 的 `drm-engine-gfx`/`drm-engine-compute` 纳秒差值（**免 root**）→ ③ `nvidia-smi` → ④ `radeontop -d - -l 1`。
- **显存/频率**：amdgpu 读 `mem_info_vram_used/_total` 与 hwmon `freq*_input`（radeon 报 Hz、amdgpu 报 kHz，统一换算 MHz），显存频率取 `mclk` 标签通道，无 hwmon mclk 的旧机回退 `pp_dpm_mclk` 当前档；NVIDIA 走 `nvidia-smi` 的 `clocks.current.*`。
- **UI**：Dashboard 新增 GPU 圆环（与 CPU/内存/磁盘同列），Resources 页新增 GPU 占用历史曲线（60 秒窗口），温度面板显示 GPU 温度/频率/显存频率三行；CPU 与磁盘温度不再上页面但传感器 API 保留。均挂在页面已有的 1 秒 `QTimer` 上。

**为什么需要 fdinfo 回退**：本机 Oland（GCN 1.0/SI）的 amdgpu 用旧式 DPM，`gpu_busy_percent` 返回 `EOPNOTSUPP`（内核未实现 `GPU_LOAD` 查询），顺序 ① 永远失败。fdinfo 统计每个进程 DRM fd 的引擎纳秒数，两次采样差值 ÷ 时间差即占用率。两个关键细节：

1. **按 `drm-client-id` 去重**：dup 出来的 fd 共享同一 `drm_file`，不去重会把同一客户端重复累加（实测虚高 4 倍、被钳到 100%）。
2. **只能读到同用户的客户端**：`/proc/<pid>/fdinfo` 受 ptrace 权限约束，其他用户（含 root 的显示服务器）读不到——桌面场景误差可接受。

采样用 `QElapsedTimer` 维护：首次内置 100 ms 种子采样，之后按真实经过时间算差值，不假设调用间隔。实测空闲 ≈0%、`glxgears` 下 35–46%（随窗口大小变化），Dashboard 圆环逐秒跳动。探针：`tests/run-sensors.sh`。

### 依赖准备的坑（脚本已处理）

- Qt6 的 `Qt6Config.cmake` 只在**系统 Qt 前缀**下找组件，光给 `CMAKE_PREFIX_PATH` 无效，必须显式传 `-DQt6Charts_DIR` 与 `-DQt6LinguistTools_DIR`。
- `qt6-tools-dev` 解包的 `Qt6LinguistToolsTargets.cmake` 会校验 `lib/qt6/bin/{lconvert,lrelease,lupdate}` 与 `libexec/{lprodump,lrelease-pro,lupdate-pro}` 是否存在，这些由系统 `qt6-l10n-tools` / `qt6-tools-dev-tools` 提供，脚本软链进 staging，无需 root。

## 验证

```bash
./scripts/90-verify.sh     # build.sh 末尾自动调用
./tests/run-sensors.sh     # 传感器探针（0004）
```

检查项：ELF 为 LoongArch、`ldd` 无 `not found`、CPU 探针 5 项断言、offscreen GUI 存活 5 秒；结果写 `evidence/verification.json`。补丁后 `minimal`/`offscreen`/`xcb` 三平台均存活到 5 秒超时（rc=124），无 abort。

## 跨发行版交付

### 1. `.deb`（Debian / Deepin / UOS）

```bash
./packaging/make-deb.sh    # 免 root，dpkg-deb 直接构建 → dist/stacer_1.8.0-5_loong64.deb
```

当前包在 Debian sid / Qt 6.11.2 上构建，`Depends` 手写但已按 ELF 实测加下限（`libc6 (>= 2.36)`、`libqt6* (>= 6.11.0~)`），并补齐 NEEDED 里漏掉的 `libqt6opengl6`/`libglx0`/`libopengl0`；`qt6-wayland`、`qt6-gtk-platformtheme` 降为 `Recommends`。**下限随编译机走**：在 Deepin（Qt 6.8）重编后须用 `readelf -V dist/bin/stacer` 重测并把 `make-deb.sh` 的下限改回 `6.8.0~`，否则包拒绝安装在 Deepin 上。sid 的 `t64` 包名通过版本化 `Provides` 满足旧名依赖。正式发布建议装 `qt6-charts-dev qt6-tools-dev debhelper` 后走 `dpkg-buildpackage`，让 `dh_shlibdeps` 自动算依赖。

### 2. 便携包（`tar.gz`）

```bash
./packaging/make-portable.sh                    # 纯二进制 + 启动脚本
./packaging/make-portable.sh --bundle-charts    # 附带 libQt6Charts.so.6
```

两个包各带 `.sha256`：`stacer-1.8.0-loong64-linux-portable.tar.gz`（864 K）与 `...-bundled.tar.gz`（1.7 M）。解压执行 `./stacer-run.sh`：自动在 multiarch 路径探测 `libQt6Charts.so.6`、按 `WAYLAND_DISPLAY`/`DISPLAY` 选 QPA 插件、给出缺包安装提示。`README-portable.txt` 里的 Qt/glibc 下限**从二进制 ELF 动态生成**，换编译机不会过时。两者均实测启动存活 5 秒；bundled 版在完全不设 `LD_LIBRARY_PATH` 时也能启动。

**这是跨发行版，不是跨 CPU 架构**——二进制是 `loongarch64`。

### 3. Arch（`PKGBUILD`）

```bash
cd packaging/archlinux && makepkg -s
makepkg --printsrcinfo > .SRCINFO    # 上传 AUR 时
```

`arch=('loong64' 'x86_64' 'aarch64')`；依赖用 Arch 包名 `qt6-base qt6-charts qt6-svg qt6-tools`，无需 Deepin 的 staging 技巧。`prepare()` 直接读 `../../patches/*.patch`，故**必须在本配方目录内执行 makepkg**。上游 `.gitattributes` 有 `debian export-ignore`，archive tarball 里没有 `debian/control`，0003 自动跳过；0001/0002 已用 GNU `patch -p1` 在真实 archive 上验证可应用。上游 AUR 已有同名 `stacer` 包，冲突时改 `pkgname` 或调 `conflicts`。

另有 **`PKGBUILD.bin`**：不编译，直接把 `dist/` 已构建产物打成 pacman 包（`makepkg -p PKGBUILD.bin --nodeps`，`STACER_DIST` 可指向别的输出），包内权限归一为 0755。

**验证边界**：源码 `PKGBUILD` 尚未在 Arch 上完整跑过 `makepkg -s`（本机 Deepin/sid 无 makepkg），已等价验证 archive sha256 实测、`patch -p1` 应用、CMake 编译与 `cmake --install` 全流程。`PKGBUILD.bin` 已在 **Arch Linux Loong64（Qt 6.12.0 / GCC 16.2.1 / makepkg 7.1.0）** 实测出包；该机编出的二进制要求 `Qt_6.12` 符号版本，不能搬回 Qt 6.11 的 sid。

## 跨 Qt 版本兼容边界

**一句话**：`.deb` 是 `loongarch64` 二进制，只能装在同架构 Debian 系；运行时 Qt 必须 **≥ 编译机的 Qt 版本**，下限由 ELF 符号版本决定，换编译机就要重测。

| 条件 | 要求 | 证据 |
|---|---|---|
| CPU 架构 | `loongarch64` / dpkg `loong64` | `readelf -h` → LoongArch；x86_64 上 `dpkg` 直接拒绝 |
| Qt Core | **≥ 6.11**（sid 包；Deepin 重编则 ≥ 6.8） | `.gnu.version_r` 要求 `Qt_6.11`，6.0–6.10 报 `version 'Qt_6.11' not found` |
| 其它 Qt 库 | 只需 `Qt_6`，但须与 Core 同版本 | 混 minor 时 Qt Charts 用到的 QtGui 私有 API 有风险 |
| glibc | ≥ 2.36 | 二进制最高符号版本 `GLIBC_2.36` |
| libstdc++ | `GLIBCXX_3.4` / `CXXABI_1.3.13` | GCC 16.2 |
| QPA 插件 | 与系统 Qt 同一次构建 | 插件与 QtGui 是私有 ABI 绑定 |

Qt 官方只承诺同一主版本下**向后**兼容，且限定「相同工具链、相同系统环境、相同构建配置」+ 动态构建。从 Deepin 的 `6.8.0+dfsg-0deepin42` 跨到 Debian 官方 `6.11`（不同发行版/裁剪/编译器）严格说落在保证范围之外，因此当前做法是直接在 sid 重编（同机编译同机运行），而非搬运 Deepin 二进制赌兼容。

**四个具体的坑**：

1. **Depends 的版本下限必须随编译机走**。sid 包为 `>= 6.11.0~`，已用 `dpkg --compare-versions` 验证：`6.8.0+dfsg-0deepin42` / `6.4.2` 被拒、`6.11.2+dfsg-7` 通过；装到 Deepin 上会在安装前被 dpkg 挡住（这是正确行为，该二进制确实跑不了）。
2. **QtSvg 规避是编译期开关**，要动画只能在目标机重编。
3. **不要混 Qt minor 版本**。bundled 便携包原 launcher 会优先加载自带 6.8 `libQt6Charts.so.6`，在 6.11 系统上就是混版；已改为**优先系统同版本 Charts**，自带库仅兜底，`STACER_FORCE_BUNDLED_LIBS=1` 可强制。
4. **包名是 Debian 系专用**，`libqt6charts6` / `qt6-qpa-plugins` 在 Arch/Fedora 不存在。

**目标机自检**：`./scripts/check-target-compat.sh --json`（便携包内亦自带）。单文件、免 root，检查 7 项（架构 / 所需 Qt 符号版本节点 / glibc / ELF / DT_NEEDED / QPA 插件 / Qt 模块版本一致性），`exit 0` 兼容、`1` 不兼容。Qt 与 glibc 需求值**从被测 ELF 的 `.gnu.version_r` 动态读取**，不硬编码。自检全绿但仍想对齐系统 Qt 并恢复动画，最稳是在目标机跑 `./build.sh` 或 `makepkg -s`。

## 目录结构

```
meta.env                          pinned commit / 目标环境常量
build.sh                          一键入口
scripts/00-deps.sh                免 root 准备 Qt6Charts + LinguistTools staging
scripts/10-fetch-src.sh           浅克隆 pinned commit 到 .cache/Stacer
scripts/20-apply-patches.sh       幂等应用补丁
scripts/90-verify.sh              构建后验证
scripts/check-target-compat.sh    目标机运行时自检（单文件，也打进便携包）
patches/0001…0004                 四组最小补丁（git apply 格式）
tests/run.sh / run-sensors.sh     硬件信息探针（C++，链接 stacer-core）
packaging/make-deb.sh             Debian 系 .deb（免 root）
packaging/make-portable.sh        通用 Linux tar 包
packaging/archlinux/PKGBUILD      源码打包；PKGBUILD.bin 二进制打包
evidence/                         before/after JSON、gdb 栈、最小复现、ABI 需求
```

`.deps/`、`.cache/`、`dist/`、`.packaging/` 均在 `.gitignore` 中。

## 已知限制

- Qt 6.8 下 loader 动画降级为静态帧（编译期生效，搬二进制不改行为）；Qt ≥ 6.9 保留动画。
- 便携包与 `.deb` 都是 `loongarch64`，跨发行版但**不跨 CPU 架构**；其它架构用 PKGBUILD 或源码构建。
- `.deb` 的 Qt 下限随编译机：当前 sid 包要求 Qt ≥ 6.11 / glibc ≥ 2.36，装不到 Deepin（Qt 6.8）。
- fdinfo GPU 占用只能统计**同用户** DRM 客户端（ptrace 限制），且依赖内核暴露 `drm-engine-*` 字段；SI 老卡走的就是这条回退。
- 上游按发行版检测决定按钮显隐（`app.cpp` 只认 `ubuntu`），Deepin 上 GNOME 设置页隐藏——属上游行为，未改。
- 单实例 `QLocalServer`、托盘图标在 `offscreen` 下有 Qt 警告，不影响运行。

## 许可证

上游 Stacer 为 **GPL-3.0**。本仓库 `patches/` 是对上游源码的修改，按 GPL-3.0 发布；构建脚本、打包配方、自检脚本与验证证据同样沿用 GPL-3.0。作为上游子目录合并时沿用仓库根 `LICENSE` 即可；独立发布需把上游 `LICENSE` 复制到新仓库根目录。
