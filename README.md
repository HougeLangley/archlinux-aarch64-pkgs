# archlinux-aarch64-pkgs

Arch Linux ARM (aarch64) 自维护软件包仓库。目标设备：**Radxa Orion O6**（CIX CD8180/Sky1 SoC，8×Cortex-A720 + 4×Cortex-A520，62GB RAM）。

这些包因 AUR 官方不支持 aarch64、官方构建未启用所需特性、或上游打包缺陷而自维护。每个包目录包含完整的 PKGBUILD 及配套文件，可直接 `makepkg` 构建。

## 包列表

| 包 | 说明 | 为什么自维护 |
|---|---|---|
| [`obsidian-appimage`](packages/obsidian-appimage/) | Obsidian 笔记（AppImage 版） | AUR split 包的 `obsidian-bin` 子包仅 x86_64，arm64 构建必败；1.13.7 起 desktop 文件改名导致官方 PKGBUILD 全架构构建失败 |
| [`linux-aarch64-rt`](packages/linux-aarch64-rt/) | RT 实时抢占内核（Clang ThinLTO 构建） | ALARM 官方内核无 PREEMPT_RT、无 sched-ext、无 FTRACE（scx BPF 调度器需要）、GCC 构建 |
| [`flclash-bin`](packages/flclash-bin/) | FlClash 代理客户端（ClashMeta） | AUR 官方包的 aarch64 支持被注释掉；quickjs 桥接库 blob 仅 x86_64 |

## 快速开始

### 前置依赖

```bash
sudo pacman -S --needed base-devel git
# linux-aarch64-rt 额外需要 LLVM 工具链：
sudo pacman -S --needed clang llvm lld pahole
```

### 构建并安装（通用模式）

```bash
cd packages/<包名>
makepkg -sf
sudo pacman -U <包名>-*.pkg.tar.*
```

### 各包特殊说明

#### obsidian-appimage

- 自动从 GitHub Releases 下载 arm64 AppImage
- desktop 文件名自动探测（兼容 1.13.7 前后的 `obsidian.desktop` / `md.obsidian.Obsidian.desktop` 命名）
- 与 AUR 的关系：建议在 `/etc/pacman.conf` 设置 `IgnorePkg = obsidian-appimage`，防止 AUR helper（paru/yay）用未修复的 AUR 版本覆盖

#### linux-aarch64-rt

- **构建时间**：12 核满载约 90 分钟（Clang + ThinLTO）
- 与官方 `linux-aarch64` 内核**共存**：模块目录 `7.2.2-2-aarch64-rt-ARCH` 独立，GRUB 双条目可回退
- 安装后需要重新生成 GRUB 配置：`sudo grub-mkconfig -o /boot/grub/grub.cfg`
- 启用 sched-ext 调度器（可选）：`sudo pacman -S scx-scheds scx-tools`，然后 `scxctl start --sched bpfland`
  - ⚠️ RT 内核禁用 `bpf_timer` → `scx_lavd`/`scx_p2dq` 不可用，**`scx_bpfland` 是 RT 兼容的低延迟选择**
- 配置改动明细（相对官方 config）：`PREEMPT_RT=y`、`SCHED_CLASS_EXT=y`、`DEBUG_INFO_BTF=y`、FTRACE 全家桶、`LTO_CLANG_THIN=y`

#### flclash-bin

- 使用官方 `linux-arm64.deb`，无需任何二进制补丁
- quickjs 桥接库仅在 x86_64 安装（AUR 维护者的 blob 补丁）；arm64 上 flutter_js 是 dlopen 运行时加载，缺失仅影响 JS 扩展功能

## 自动更新机制（Orion O6 本机部署）

本仓库的包由 Hermes Agent cron 任务自动维护：

| 包 | 检查频率 | 更新动作 | 重启 |
|---|---|---|---|
| obsidian-appimage | 每 12h | 检测新版 → 自动下载/构建/安装 | 不需要 |
| linux-aarch64-rt | 每 12h | 跟踪 ALARM 上游 pkgver 变化 → 重新编译 → 安装 | **需要**（Telegram 通知用户） |
| flclash-bin | 每 12h | 检测新版 → 自动下载/构建/安装 | 不需要 |

更新脚本位于 [`scripts/`](scripts/)，状态文件在 `~/.hermes/builds/<包名>/last-run.json`。

## 目录结构

```
packages/<包名>/     # PKGBUILD + 构建所需全部文件（补丁、config、preset、install 脚本）
scripts/            # 自动更新脚本（Hermes cron 调用）
```

## 许可证

各包遵循其上游许可证（Obsidian: custom、Linux: GPL-2.0、FlClash: GPL-3.0）。本仓库的打包脚本（PKGBUILD、更新脚本）以 MIT 发布。
