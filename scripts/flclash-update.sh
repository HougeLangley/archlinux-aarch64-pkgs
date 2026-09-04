#!/usr/bin/env bash
# flclash-bin 自维护更新器 (aarch64 / OrionO6)
# 上游: github.com/chen08209/FlClash
# 用法: flclash-update.sh [--force]
# 退出码: 0=无更新或安装成功  1=基础设施错误  2=构建失败
# 状态文件: ~/.hermes/builds/flclash-bin/last-run.json
set -uo pipefail

BUILD_DIR="$HOME/.hermes/builds/flclash-bin"
PKG_SRC="$HOME/flclash-bin"           # PKGBUILD 所在（自维护副本）
LOG_DIR="$HOME/.hermes/logs"
LOG="$LOG_DIR/flclash-update.log"
STATE="$BUILD_DIR/last-run.json"
GH_REL_BASE="https://github.com/chen08209/FlClash/releases"

FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1
mkdir -p "$BUILD_DIR" "$LOG_DIR"
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
state(){
  jq -n --arg ts "$(date -Is)" --arg st "$1" --arg ov "${2:-}" \
       --arg nv "${3:-}" --arg msg "${4:-}" \
    '{timestamp:$ts, status:$st, old_version:$ov, new_version:$nv, message:$msg}' > "$STATE"
}

# ---- 1. 查上游最新版（linux-arm64.deb 资产）----
NEW=""
if JSON=$(curl -sf --max-time 30 'https://api.github.com/repos/chen08209/FlClash/releases/latest' 2>/dev/null); then
  NEW=$(jq -r '.tag_name // empty' <<<"$JSON" | sed 's/^v//')
else
  NEW=$(curl -sfI --max-time 30 "$GH_REL_BASE/latest" 2>/dev/null \
        | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' | sed 's|.*/tag/||;s|^v||')
fi
if [[ -z "$NEW" ]]; then
  log "ERROR: 上游版本查询失败"; state error "" "" "GitHub API 查询失败"
  echo "上游版本查询失败"; exit 1
fi

# ---- 2. 与本地比对 ----
INSTALLED=$(pacman -Q flclash-bin 2>/dev/null | awk '{print $2}'); INSTALLED="${INSTALLED%%-*}"
if [[ $FORCE -eq 0 && -n "$INSTALLED" && "$(vercmp "$NEW" "$INSTALLED")" -le 0 ]]; then
  log "无更新 (上游 $NEW <= 本地 $INSTALLED)"
  state no-update "$INSTALLED" "$NEW"
  echo "无更新 (本地 $INSTALLED)"; exit 0
fi
log "开始更新: $INSTALLED -> $NEW (force=$FORCE)"

# ---- 3. 下载 arm64 deb（复用已有文件）----
DEB="flclash-${NEW}-aarch64.deb"
if [[ ! -f "$BUILD_DIR/$DEB" ]]; then
  URL="$GH_REL_BASE/download/v${NEW}/FlClash-${NEW}-linux-arm64.deb"
  log "下载 $URL"
  if ! curl -fL --retry 3 --retry-delay 5 --max-time 300 -o "$BUILD_DIR/$DEB" "$URL" >> "$LOG" 2>&1; then
    rm -f "$BUILD_DIR/$DEB"
    log "ERROR: deb 下载失败"; state error "$INSTALLED" "$NEW" "deb 下载失败"
    echo "下载失败"; exit 1
  fi
fi
SHA=$(sha256sum "$BUILD_DIR/$DEB" | awk '{print $1}')

# ---- 4. 同步到 PKGBUILD 目录并更新版本/校验和 ----
cp "$BUILD_DIR/$DEB" "$PKG_SRC/$DEB"
cd "$PKG_SRC" || exit 1
sed -i "s|^pkgver=.*|pkgver=${NEW}|" PKGBUILD
sed -i "s|^pkgrel=.*|pkgrel=1|" PKGBUILD
sed -i "s|^sha256sums_aarch64=('.*')|sha256sums_aarch64=('${SHA}')|" PKGBUILD
log "PKGBUILD 已更新: pkgver=$NEW sha256=${SHA:0:12}..."

# ---- 5. 构建 ----
rm -f flclash-bin-*.pkg.tar.*
if ! makepkg -sf --noconfirm >> "$LOG" 2>&1; then
  log "ERROR: makepkg 构建失败"
  state build-failed "$INSTALLED" "$NEW" "makepkg 失败，见 $LOG"
  echo "构建失败"; exit 2
fi
PKG=$(ls -t flclash-bin-*.pkg.tar.* 2>/dev/null | head -1)
[[ -z "$PKG" ]] && { state build-failed "$INSTALLED" "$NEW" "未找到构建产物"; echo "未找到产物"; exit 2; }

# ---- 6. 安装 + 校验 ----
if ! sudo pacman -U --noconfirm "$PKG" >> "$LOG" 2>&1; then
  log "ERROR: pacman -U 失败"; state error "$INSTALLED" "$NEW" "pacman -U 失败"
  echo "安装失败"; exit 1
fi
QV=$(pacman -Q flclash-bin | awk '{print $2}' | cut -d- -f1)
[[ "$QV" != "$NEW" ]] && { log "ERROR: 版本校验失败 $QV != $NEW"; state error "$INSTALLED" "$NEW" "版本校验失败"; exit 1; }
[[ -x /usr/bin/flclash ]] || { state error "$INSTALLED" "$NEW" "/usr/bin/flclash 缺失"; exit 1; }

# ---- 7. 清理旧文件 ----
find "$BUILD_DIR" -maxdepth 1 -name 'flclash-*-aarch64.deb' ! -name "$DEB" -delete
rm -f "$PKG_SRC"/flclash-*.deb.old 2>/dev/null
ls -t "$PKG_SRC"/flclash-bin-*.pkg.tar.* 2>/dev/null | tail -n +2 | xargs -r rm -f

log "OK: $INSTALLED -> $NEW ($PKG)"
state updated "$INSTALLED" "$NEW" "已安装 $PKG"
echo "已更新 $INSTALLED -> $NEW"
