#!/usr/bin/env bash
# linux-aarch64-rt 内核自维护更新器 (aarch64 / OrionO6)
# 跟踪 ALARM 上游 linux-aarch64 包的版本变化，自动重编译 RT 内核
# 用法: kernel-rt-update.sh [--force]
# 退出码: 0=无更新或安装成功  1=基础设施错误  2=构建失败
# ⚠️ 内核更新需要重启才生效——安装成功后必须通知用户重启（cron agent 负责 telegram 通知）
# 状态文件: ~/.hermes/builds/kernel-rt/last-run.json
set -uo pipefail

BUILD_DIR="$HOME/.hermes/builds/kernel-rt"
PKG_SRC="$HOME/vllm/kernel-rt"        # PKGBUILD 所在（自维护副本）
REPO_DIR="$HOME/GitHub/archlinux-aarch64-pkgs"
LOG_DIR="$HOME/.hermes/logs"
LOG="$LOG_DIR/kernel-rt-update.log"
STATE="$BUILD_DIR/last-run.json"
ALARM_PKGBUILD_URL="https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/linux-aarch64/PKGBUILD"
ALARM_CONFIG_URL="https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/master/core/linux-aarch64/config"

FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1
mkdir -p "$BUILD_DIR" "$LOG_DIR"
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
state(){
  jq -n --arg ts "$(date -Is)" --arg st "$1" --arg ov "${2:-}" \
       --arg nv "${3:-}" --arg msg "${4:-}" --argjson reboot "${5:-false}" \
    '{timestamp:$ts, status:$st, old_version:$ov, new_version:$nv, message:$msg, needs_reboot:$reboot}' > "$STATE"
}

# ---- 1. 查上游版本（ALARM PKGBUILD 的 pkgver+pkgrel）----
UPSTREAM=$(curl -sf --max-time 30 "$ALARM_PKGBUILD_URL" 2>/dev/null)
if [[ -z "$UPSTREAM" ]]; then
  log "ERROR: ALARM PKGBUILD 获取失败"; state error "" "" "上游查询失败"
  echo "上游查询失败"; exit 1
fi
UP_VER=$(grep -m1 '^pkgver=' <<<"$UPSTREAM" | cut -d= -f2)
UP_REL=$(grep -m1 '^pkgrel=' <<<"$UPSTREAM" | cut -d= -f2)
UPSTREAM_FULL="${UP_VER}-${UP_REL}"

# ---- 2. 与本地比对（当前运行的 RT 内核版本）----
RUNNING=$(uname -r)  # 如 7.2.2-2-aarch64-rt-ARCH
# 提取上游对应版本号：去掉 -aarch64-rt-ARCH 后缀部分
INSTALLED_PKG=$(pacman -Q linux-aarch64-rt 2>/dev/null | awk '{print $2}')
if [[ $FORCE -eq 0 && "$INSTALLED_PKG" == "$UPSTREAM_FULL" ]]; then
  log "无更新 (上游 $UPSTREAM_FULL == 已装 $INSTALLED_PKG)"
  state no-update "$INSTALLED_PKG" "$UPSTREAM_FULL"
  echo "无更新 (本地 $INSTALLED_PKG)"; exit 0
fi
log "检测到上游更新: $INSTALLED_PKG -> $UPSTREAM_FULL"

# ---- 3. 下载上游 config + 补丁，合并 RT 改动 ----
cd "$PKG_SRC" || exit 1
# 下载上游最新 config
if ! curl -sf --max-time 60 -o config.upstream "$ALARM_CONFIG_URL" >> "$LOG" 2>&1; then
  log "ERROR: 上游 config 下载失败"; state error "$INSTALLED_PKG" "$UPSTREAM_FULL" "config 下载失败"
  echo "config 下载失败"; exit 1
fi

# 基于上游 config 重新生成 config-rt（保持我们的 RT 改动）
cp config.upstream config-rt
python3 - <<'PYEOF'
import re
s=open('config-rt').read()
def sub(pat,rep):
    global s
    s2,n=re.subn(pat,rep,s,count=1,flags=re.M)
    if n==0: print(f"WARN not found: {pat}"); return
    s=s2
# RT 抢占
sub(r'^CONFIG_PREEMPT=y$','# CONFIG_PREEMPT is not set')
sub(r'^CONFIG_PREEMPT_DYNAMIC=y$','# CONFIG_PREEMPT_DYNAMIC is not set')
sub(r'^# CONFIG_PREEMPT_RT is not set$','CONFIG_PREEMPT_RT=y')
# sched-ext
if 'CONFIG_SCHED_CLASS_EXT' not in s:
    s=s.replace('# CONFIG_PREEMPT_DYNAMIC is not set\n','# CONFIG_PREEMPT_DYNAMIC is not set\nCONFIG_SCHED_CLASS_EXT=y\n')
# BTF
sub(r'^CONFIG_DEBUG_INFO_NONE=y$','# CONFIG_DEBUG_INFO_NONE is not set\nCONFIG_DEBUG_INFO_DWARF5=y\nCONFIG_DEBUG_INFO_BTF=y\nCONFIG_DEBUG_INFO_BTF_MODULES=y')
# ThinLTO
sub(r'^CONFIG_LTO_NONE=y$','# CONFIG_LTO_NONE is not set\nCONFIG_LTO_CLANG=y\nCONFIG_LTO_CLANG_THIN=y')
# FTRACE（sched-ext BPF 程序附着点需要）
sub(r'^# CONFIG_FTRACE is not set$','''CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_FTRACE_SYSCALLS=y
CONFIG_FUNCTION_PROFILER=y
CONFIG_KPROBE_EVENTS=y
CONFIG_BPF_EVENTS=y
CONFIG_STACKTRACE=y''')
# 清理重复行
lines=s.splitlines(True)
seen=set(); out=[]
for l in lines:
    key=l.strip()
    if key.startswith('#') and 'is not set' in key:
        sym=key.split()[1]
        if sym in seen: continue
        seen.add(sym)
    out.append(l)
open('config-rt','w').writelines(out)
print("config-rt regenerated from upstream")
PYEOF

# 更新 PKGBUILD 版本号与校验和
sed -i "s|^pkgver=.*|pkgver=${UP_VER}|" PKGBUILD
sed -i "s|^pkgrel=.*|pkgrel=${UP_REL}|" PKGBUILD
sed -i "s|^         '[0-9a-f]\{64\}'$|         'SKIP'|" PKGBUILD 2>/dev/null  # 临时跳过校验
makepkg -g >> "$LOG" 2>&1
# 用 makepkg -g 的输出替换 md5sums
python3 - <<'PYEOF'
import re, subprocess
sums = subprocess.run(['makepkg','-g'], capture_output=True, text=True, cwd='.').stdout
s = open('PKGBUILD').read()
# 替换整个 md5sums 数组
s = re.sub(r"md5sums=\([^)]*\)", sums.strip(), s, count=1)
open('PKGBUILD','w').write(s)
print("md5sums updated")
PYEOF

# ---- 4. 构建（ThinLTO 全量，约 90 分钟）----
log "开始构建 linux-aarch64-rt ${UPSTREAM_FULL}（预计 60-90 分钟）"
rm -f linux-aarch64-rt-*.pkg.tar.*
if ! makepkg -sf --noconfirm >> "$LOG" 2>&1; then
  log "ERROR: 内核构建失败"; state build-failed "$INSTALLED_PKG" "$UPSTREAM_FULL" "makepkg 失败，见 $LOG"
  echo "构建失败"; exit 2
fi
PKG=$(ls -t linux-aarch64-rt-*.pkg.tar.* 2>/dev/null | grep -v headers | head -1)
HDR=$(ls -t linux-aarch64-rt-headers-*.pkg.tar.* 2>/dev/null | head -1)
[[ -z "$PKG" ]] && { state build-failed "$INSTALLED_PKG" "$UPSTREAM_FULL" "未找到构建产物"; exit 2; }

# ---- 5. 安装 + 校验 ----
if ! sudo pacman -U --noconfirm "$PKG" ${HDR:+"$HDR"} >> "$LOG" 2>&1; then
  log "ERROR: pacman -U 失败"; state error "$INSTALLED_PKG" "$UPSTREAM_FULL" "pacman -U 失败"
  echo "安装失败"; exit 1
fi
QV=$(pacman -Q linux-aarch64-rt | awk '{print $2}')
[[ "$QV" != "$UPSTREAM_FULL" ]] && { log "ERROR: 版本校验失败 $QV != $UPSTREAM_FULL"; state error "$INSTALLED_PKG" "$UPSTREAM_FULL" "版本校验失败"; exit 1; }
[[ -f "/boot/vmlinuz-linux-aarch64-rt" ]] || { state error "$INSTALLED_PKG" "$UPSTREAM_FULL" "vmlinuz 未安装"; exit 1; }

# ---- 6. 同步到 GitHub 仓库 ----
if [[ -d "$REPO_DIR" ]]; then
  cp PKGBUILD config-rt linux-aarch64-rt.preset linux-aarch64-rt.install "$REPO_DIR/packages/linux-aarch64-rt/"
  cd "$REPO_DIR" && git add -A && git commit -m "linux-aarch64-rt: 更新到 ${UPSTREAM_FULL}（上游 ALARM 同步）" >> "$LOG" 2>&1 && git push >> "$LOG" 2>&1 && log "GitHub 已同步" || log "WARN: GitHub 同步失败"
  cd "$PKG_SRC"
fi

# ---- 7. 清理旧构建产物 ----
ls -t linux-aarch64-rt-*.pkg.tar.* 2>/dev/null | grep -v headers | tail -n +2 | xargs -r rm -f
ls -t linux-aarch64-rt-headers-*.pkg.tar.* 2>/dev/null | tail -n +2 | xargs -r rm -f

log "OK: $INSTALLED_PKG -> $UPSTREAM_FULL（需重启生效）"
state updated "$INSTALLED_PKG" "$UPSTREAM_FULL" "已安装 $PKG，GRUB 默认锁定 RT，重启后生效" true
echo "已更新 $INSTALLED_PKG -> $UPSTREAM_FULL（需重启）"
