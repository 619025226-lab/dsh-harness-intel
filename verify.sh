#!/bin/bash
# DeepSeek Harness x64 移植自检
#
#   ./verify.sh "/Applications/DeepSeek Harness.app"
#   ./verify.sh --quick "/path/to/DeepSeek Harness.app"   # 跳过逐文件架构扫描
#
# 只读检查，不会修改被检查的 App。全部通过时退出码为 0。
set -uo pipefail

export PYTHONDONTWRITEBYTECODE=1

QUICK=0
APP=""
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) APP="$arg" ;;
  esac
done

if [[ -z "$APP" ]]; then
  APP="/Applications/DeepSeek Harness.app"
fi

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
FAILURES=0
WARNINGS=0

pass() { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf "  ${RED}✗${RESET} %s\n" "$*"; FAILURES=$((FAILURES + 1)); }
section() { printf "\n${BOLD}%s${RESET}\n" "$*"; }

section "目标"
if [[ ! -d "$APP" ]]; then
  printf "  ${RED}✗${RESET} 找不到 %s\n" "$APP"
  exit 2
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
printf "  %s\n" "$APP"

PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  printf "  ${RED}✗${RESET} 缺少 Info.plist\n"
  exit 2
fi
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PLIST" 2>/dev/null || echo "?")"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null || echo "?")"
EXEC="$(plutil -extract CFBundleExecutable raw "$PLIST" 2>/dev/null || echo "?")"
printf "  bundle: %s  version: %s  executable: %s\n" "$BUNDLE_ID" "$VERSION" "$EXEC"

section "架构"
MAIN_BIN="$APP/Contents/MacOS/$EXEC"
if [[ -f "$MAIN_BIN" ]]; then
  MAIN_ARCH="$(file -b "$MAIN_BIN" | head -1)"
  if [[ "$MAIN_ARCH" == *x86_64* && "$MAIN_ARCH" != *arm64* ]]; then
    pass "主程序是 x86_64"
  else
    fail "主程序架构异常：$MAIN_ARCH"
  fi
else
  fail "缺少主程序 $MAIN_BIN"
fi

check_arch() {
  local label="$1" path="$2" want="$3"
  [[ -e "$path" ]] || { fail "$label 不存在：$path"; return; }
  local info; info="$(file -b "$path")"
  if [[ "$info" == *"$want"* && "$info" != *arm64* ]]; then
    pass "$label 是 $want"
  else
    fail "$label 架构异常：$info"
  fi
}

check_arch "Electron Framework" \
  "$APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework" "x86_64"
check_arch "Node 运行时" \
  "$APP/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node" "x86_64"
check_arch "Python 运行时" \
  "$APP/Contents/Resources/runtime/primary-runtime/dependencies/python/bin/python3.12" "x86_64"
check_arch "link-entry" \
  "$APP/Contents/Resources/runtime/cli/link-entry" "x86_64"

if [[ "$QUICK" -eq 0 ]]; then
  printf "  ${DIM}扫描全部可执行文件…${RESET}\n"
  ARM64_LIST="$(find "$APP" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0 2>/dev/null \
    | xargs -0 file 2>/dev/null | grep 'arm64' || true)"
  ARM64_COUNT="$(printf '%s' "$ARM64_LIST" | grep -c . || true)"
  if [[ "$ARM64_COUNT" -eq 0 ]]; then
    pass "整包 0 个 arm64 Mach-O"
  else
    fail "仍有 $ARM64_COUNT 个 arm64 二进制"
    printf '%s\n' "$ARM64_LIST" | head -10 | sed 's/^/      /'
  fi
else
  warn "已跳过全量扫描（--quick）"
fi

section "打包形态"
RES="$APP/Contents/Resources"
if [[ -f "$RES/app.asar" ]]; then
  pass "使用 app.asar（$(du -h "$RES/app.asar" | cut -f1)）"
  if [[ -d "$RES/app.asar.unpacked" ]]; then
    UNPACKED="$(find "$RES/app.asar.unpacked" -type f 2>/dev/null | wc -l | tr -d ' ')"
    NODES="$(find "$RES/app.asar.unpacked" -name '*.node' 2>/dev/null | wc -l | tr -d ' ')"
    pass "unpacked 目录内 $UNPACKED 个文件（含 $NODES 个 .node）"
  else
    fail "缺少 app.asar.unpacked（原生模块无法加载）"
  fi

  INTEG_RESULT="$(python3 - "$RES/app.asar" "$APP/Contents/Info.plist" <<'PY'
import hashlib, plistlib, struct, sys
asar_path, plist_path = sys.argv[1], sys.argv[2]
try:
    with open(asar_path, "rb") as handle:
        head = handle.read(16)
        size = struct.unpack("<I", head[12:16])[0]
        header = handle.read(size)
    computed = hashlib.sha256(header).hexdigest()
    with open(plist_path, "rb") as handle:
        info = plistlib.load(handle)
    declared = info.get("ElectronAsarIntegrity", {}).get("Resources/app.asar", {}).get("hash", "")
    print("match" if declared and declared == computed else "mismatch:" + (declared or "missing"))
except Exception as error:
    print("error:" + str(error))
PY
)"
  case "$INTEG_RESULT" in
    match) pass "ElectronAsarIntegrity 与实际 asar 一致" ;;
    mismatch:*) fail "ElectronAsarIntegrity 不一致（${INTEG_RESULT#mismatch:}）" ;;
    *) warn "无法校验 asar 完整性（${INTEG_RESULT#error:}）" ;;
  esac
else
  warn "使用 app/ 目录（未打包 asar）"
  if [[ -d "$RES/app" ]]; then
    FILES="$(find "$RES/app" -type f 2>/dev/null | wc -l | tr -d ' ')"
    pass "app/ 内含 $FILES 个文件"
  else
    fail "既没有 app.asar 也没有 app/ 目录"
  fi
fi

if [[ -f "$RES/app-update.yml" ]]; then
  fail "app-update.yml 仍存在 —— 自动更新会拉回 arm64"
else
  pass "自动更新已关闭"
fi

RUNTIME_JSON="$RES/runtime/primary-runtime/runtime.json"
if [[ -f "$RUNTIME_JSON" ]]; then
  RUNTIME_ARCH="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('arch','?'))" "$RUNTIME_JSON" 2>/dev/null)"
  if [[ "$RUNTIME_ARCH" == "x64" ]]; then
    pass "runtime.json arch = x64"
  else
    fail "runtime.json arch = $RUNTIME_ARCH（dsh 会拒绝启动）"
  fi
fi

section "运行时可用性"
NODE_BIN="$RES/runtime/primary-runtime/dependencies/node/bin/node"
if [[ -x "$NODE_BIN" ]]; then
  NODE_VERSION="$("$NODE_BIN" -v 2>/dev/null)"
  pass "node $NODE_VERSION"
else
  fail "node 不可执行"
fi

PY_BIN="$RES/runtime/primary-runtime/dependencies/python/bin/python3"
if [[ -x "$PY_BIN" ]]; then
  PY_VERSION="$("$PY_BIN" -V 2>&1)"
  pass "$PY_VERSION"
  if "$PY_BIN" -c "import numpy, pandas, docx, pptx, openpyxl, PIL, lxml" >/dev/null 2>&1; then
    pass "Office 相关 Python 依赖可导入"
  else
    fail "Python 依赖导入失败"
  fi
else
  fail "python3 不可执行"
fi

section "签名"
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  pass "codesign 校验通过"
else
  fail "codesign 校验失败"
fi
SIG_FLAGS="$(codesign -dvv "$APP" 2>&1 || true)"
if [[ "$SIG_FLAGS" == *runtime* ]]; then
  pass "hardened runtime 已开启"
else
  warn "未开启 hardened runtime"
fi
SIG_INFO="$(codesign -dv "$APP" 2>&1)"
if printf '%s' "$SIG_INFO" | grep -q "Signature=adhoc"; then
  warn "ad-hoc 签名（无 Developer ID / 公证，换机器需手动放行）"
else
  pass "签名类型：$(printf '%s' "$SIG_INFO" | grep -m1 'Authority=' || echo '未知')"
fi
printf "  ${DIM}Gatekeeper: %s${RESET}\n" \
  "$(spctl --assess --type execute "$APP" 2>&1 | tail -1)"

section "结果"
if [[ "$FAILURES" -eq 0 ]]; then
  printf "  ${GREEN}通过${RESET}（警告 %d 项）\n" "$WARNINGS"
  exit 0
else
  printf "  ${RED}失败 %d 项${RESET}（警告 %d 项）\n" "$FAILURES" "$WARNINGS"
  exit 1
fi
