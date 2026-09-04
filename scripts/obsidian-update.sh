#!/usr/bin/env bash
# obsidian-appimage 自维护更新器 (aarch64 / OrionO6)
# 上游: github.com/obsidianmd/obsidian-releases
# 用法: obsidian-update.sh [--force]   (--force = 同版本也重建重装)
# 退出码: 0=无更新或安装成功  1=基础设施错误(网络/API/安装)  2=构建失败(需修补 PKGBUILD)
# 状态文件: ~/.hermes/builds/obsidian/last-run.json
# 完整日志: ~/.hermes/logs/obsidian-update.log
set -uo pipefail

BUILD_DIR="$HOME/.hermes/builds/obsidian"
LOG_DIR="$HOME/.hermes/logs"
LOG="$LOG_DIR/obsidian-update.log"
STATE="$BUILD_DIR/last-run.json"
API="https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest"
GH_REL_BASE="https://github.com/obsidianmd/obsidian-releases/releases"

FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1
mkdir -p "$LOG_DIR"
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
state(){ # $1=status $2=old $3=new $4=message
  jq -n --arg ts "$(date -Is)" --arg st "$1" --arg ov "${2:-}" \
       --arg nv "${3:-}" --arg msg "${4:-}" \
    '{timestamp:$ts, status:$st, old_version:$ov, new_version:$nv, message:$msg}' > "$STATE"
}

# ---- 1. 查询上游最新桌面版（跳过移动-only 发布如 v1.13.8 只有 .apk；
#         API 限流 403 时回退 redirect 解析 latest 完整版）----
NEW=""; DL_URL=""
if JSON=$(curl -sf --max-time 30 'https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=30' 2>/dev/null); then
  # 取第一个带 arm64 AppImage 资产的 release
  while IFS=$'\t' read -r tag url; do
    if [[ -n "$tag" && -n "$url" ]]; then NEW="${tag#v}"; DL_URL="$url"; break; fi
  done < <(jq -r '.[] | select([.assets[].name | test("arm64.*\\.AppImage$|aarch64.*\\.AppImage$")] | any) | .tag_name as $t | (.assets[] | select(.name | test("arm64.*\\.AppImage$|aarch64.*\\.AppImage$")) | .browser_download_url) as $u | "\($t)\t\($u)"' <<<"$JSON")
else
  NEW=$(curl -sfI --max-time 30 "$GH_REL_BASE/latest" 2>/dev/null \
        | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' | sed 's|.*/tag/||;s|^v||')
  [[ -n "$NEW" ]] && DL_URL="$GH_REL_BASE/download/v${NEW}/Obsidian-${NEW}-arm64.AppImage"
fi
if [[ -z "$NEW" || -z "$DL_URL" ]]; then
  log "ERROR: 上游版本查询失败 (GitHub API 与 redirect 均失败)"
  state error "" "" "上游版本查询失败"
  echo "上游版本查询失败"; exit 1
fi

# ---- 2. 与本地已装版本比对 ----
INSTALLED=$(pacman -Q obsidian-appimage 2>/dev/null | awk '{print $2}'); INSTALLED="${INSTALLED%%-*}"
if [[ $FORCE -eq 0 && -n "$INSTALLED" && "$(vercmp "$NEW" "$INSTALLED")" -le 0 ]]; then
  log "无更新 (上游 $NEW <= 本地 $INSTALLED)"
  state no-update "$INSTALLED" "$NEW"
  echo "无更新 (本地 $INSTALLED)"; exit 0
fi
log "开始更新: $INSTALLED -> $NEW (force=$FORCE)"

# ---- 3. 下载 arm64 AppImage（已有同版本文件则复用，避免 --force 重复下载）----
AIF="obsidian-${NEW}-aarch64.AppImage"
if [[ ! -f "$BUILD_DIR/$AIF" ]]; then
  log "下载 $DL_URL"
  if ! curl -fL --retry 3 --retry-delay 5 --max-time 540 -o "$BUILD_DIR/$AIF" "$DL_URL" >> "$LOG" 2>&1; then
    rm -f "$BUILD_DIR/$AIF"
    log "ERROR: AppImage 下载失败"
    state error "$INSTALLED" "$NEW" "AppImage 下载失败"
    echo "下载失败"; exit 1
  fi
fi
SHA=$(sha256sum "$BUILD_DIR/$AIF" | awk '{print $1}')

# ---- 4. 更新 PKGBUILD（版本 + aarch64 校验和 + pkgrel 归 1）----
cd "$BUILD_DIR" || exit 1
sed -i "s|^pkgver=.*|pkgver=${NEW}|" PKGBUILD
sed -i "s|^pkgrel=.*|pkgrel=1|" PKGBUILD
sed -i "s|^sha256sums_aarch64=('.*')|sha256sums_aarch64=('${SHA}')|" PKGBUILD
log "PKGBUILD 已更新: pkgver=$NEW sha256=${SHA:0:12}..."

# ---- 5. 构建（makepkg 自动跳过 x86_64-only 的 obsidian-bin 子包）----
rm -f obsidian-appimage-*.pkg.tar.*
if ! makepkg -C -f >> "$LOG" 2>&1; then
  log "ERROR: makepkg 构建失败 — 大概率上游结构变化，需修补 PKGBUILD"
  state build-failed "$INSTALLED" "$NEW" "makepkg 失败，见 $LOG"
  echo "构建失败"; exit 2
fi
PKG=$(ls -t obsidian-appimage-*.pkg.tar.* 2>/dev/null | head -1)
if [[ -z "$PKG" ]]; then
  state build-failed "$INSTALLED" "$NEW" "makepkg 成功但未找到产物"
  echo "未找到构建产物"; exit 2
fi

# ---- 6. 安装 + 校验 ----
if ! sudo pacman -U --noconfirm "$BUILD_DIR/$PKG" >> "$LOG" 2>&1; then
  log "ERROR: pacman -U 安装失败"
  state error "$INSTALLED" "$NEW" "pacman -U 失败"
  echo "安装失败"; exit 1
fi
QV=$(pacman -Q obsidian-appimage | awk '{print $2}' | cut -d- -f1)
if [[ "$QV" != "$NEW" ]]; then
  log "ERROR: 安装后版本不符: $QV != $NEW"
  state error "$INSTALLED" "$NEW" "安装后版本校验失败 ($QV)"
  echo "版本校验失败"; exit 1
fi
[[ -x /usr/bin/obsidian ]] || { log "ERROR: /usr/bin/obsidian 缺失"; state error "$INSTALLED" "$NEW" "/usr/bin/obsidian 缺失"; exit 1; }

# ---- 7. 清理旧 AppImage 与旧包产物（各保留当前一份）----
find "$BUILD_DIR" -maxdepth 1 -name 'obsidian-*-aarch64.AppImage' ! -name "$AIF" -delete
ls -t obsidian-appimage-*.pkg.tar.* 2>/dev/null | tail -n +2 | xargs -r rm -f

log "OK: $INSTALLED -> $NEW ($PKG)"
state updated "$INSTALLED" "$NEW" "已安装 $PKG"
echo "已更新 $INSTALLED -> $NEW"
