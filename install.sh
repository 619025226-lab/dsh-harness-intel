#!/bin/bash
# 下载并校验 DeepSeek Harness Intel（x64）安装包
#
#   ./install.sh                     # 下载到 ~/Downloads，校验后自动打开
#   DEST=/tmp ./install.sh           # 指定下载目录
#   CHECK_ONLY=1 DEST=. ./install.sh # 只校验已存在的文件，不下载、不打开
#   TAG=v0.2.2-rc.1 ./install.sh     # 指定版本
#
# 校验失败会以非 0 退出，不会打开安装包。
set -euo pipefail

TAG="${TAG:-v0.2.2-rc.1}"
VERSION="${TAG#v}"
REPO="${REPO:-619025226-lab/dsh-harness-intel}"
FILE="deepseek-harness-${VERSION}-mac-x64.dmg"
EXPECT_SHA="${EXPECT_SHA:-ca7ed0f6dfe06e78b2766aa210009e6d4153bccf7c58f7b91380c08ab7c1b329}"
EXPECT_SIZE="${EXPECT_SIZE:-448895877}"
DEST="${DEST:-$HOME/Downloads}"
OPEN_AFTER="${OPEN_AFTER:-1}"
CHECK_ONLY="${CHECK_ONLY:-0}"
[[ "$CHECK_ONLY" = "1" ]] && OPEN_AFTER=0

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
log() { printf "\n${BOLD}==> %s${RESET}\n" "$*"; }
ok()  { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
die() { printf "\n${RED}✗ %s${RESET}\n" "$*" >&2; exit 1; }

mkdir -p "$DEST"
cd "$DEST" || die "无法进入 $DEST"

if [[ "$CHECK_ONLY" != "1" ]]; then
  log "下载 $FILE"
  curl -fL --retry 3 --connect-timeout 20 --max-time 1800 -o "$FILE" \
    "https://github.com/$REPO/releases/download/$TAG/$FILE" \
    || die "下载失败：https://github.com/$REPO/releases/tag/$TAG"
  ok "$(du -h "$FILE" | cut -f1)"
fi

[[ -f "$FILE" ]] || die "找不到 $FILE（当前目录：$(pwd)）"

log "校验大小"
SIZE="$(stat -f %z "$FILE" 2>/dev/null || wc -c < "$FILE" | tr -d ' ')"
if [[ "$SIZE" = "$EXPECT_SIZE" ]]; then
  ok "$SIZE 字节"
else
  die "大小不符：实际 $SIZE，期望 $EXPECT_SIZE"
fi

log "校验 sha256"
ACTUAL="$(shasum -a 256 "$FILE" | awk '{print $1}')"
if [[ "$ACTUAL" = "$EXPECT_SHA" ]]; then
  ok "$ACTUAL"
else
  die "哈希不符：实际 $ACTUAL，期望 $EXPECT_SHA（请重新下载）"
fi

log "去掉隔离属性"
xattr -dr com.apple.quarantine "$FILE" 2>/dev/null || true
ok "已清理 com.apple.quarantine"

if [[ "$OPEN_AFTER" = "1" ]]; then
  log "打开安装包"
  open "$FILE"
  echo "  把「DeepSeek Harness」拖进「应用程序」"
  echo "  首次打开若被拦：系统设置 → 隐私与安全性 → 仍要打开"
fi

log "完成"
echo "  文件：$(pwd)/$FILE"
