#!/bin/bash
# 第 8 节「已知坑」的一键排查：只读检查，逐条给出 PASS / WARN / FAIL。
#
#   ./triage.sh                          # 默认检查 /Applications/DeepSeek Harness.app
#   ./triage.sh "/path/to/DeepSeek Harness.app"
#   REF_APP="/path/to/旧版.app" ./triage.sh   # 额外对比解包文件数
#
# 全部通过时退出码 0；出现 FAIL 时退出码 1。
set -uo pipefail

APP="${1:-/Applications/DeepSeek Harness.app}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASAR_CLI="$SCRIPT_DIR/tools/node_modules/@electron/asar/bin/asar.mjs"

BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
FAILS=0; WARNS=0

pass() { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; WARNS=$((WARNS + 1)); }
fail() { printf "  ${RED}✗${RESET} %s\n" "$*"; FAILS=$((FAILS + 1)); }
info() { printf "  ${DIM}%s${RESET}\n" "$*"; }
section() { printf "\n${BOLD}%s${RESET}\n" "$*"; }

if [[ ! -d "$APP" ]]; then
  printf "${RED}✗${RESET} 找不到 %s\n" "$APP"
  exit 2
fi
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
RES="$APP/Contents/Resources"
EXEC_NAME="$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist" 2>/dev/null || echo "DeepSeek Harness")"

printf "${BOLD}排查目标${RESET}\n  %s\n" "$APP"

# ---------------------------------------------------------------- 8.1
section "8.1 自动更新 / 架构"
if [[ -f "$RES/app-update.yml" ]]; then
  fail "app-update.yml 仍存在：官方 feed 会把 arm64 装回来 → 删除后重装 x64 包"
else
  pass "app-update.yml 不存在（自动更新已关）"
fi
MAIN_ARCH="$(file -b "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || echo "missing")"
if [[ "$MAIN_ARCH" == *x86_64* && "$MAIN_ARCH" != *arm64* ]]; then
  pass "主程序：$MAIN_ARCH"
else
  fail "主程序架构异常：$MAIN_ARCH"
fi

# ---------------------------------------------------------------- 8.2
section "8.2 primary runtime 架构"
RUNTIME_JSON="$RES/runtime/primary-runtime/runtime.json"
if [[ -f "$RUNTIME_JSON" ]]; then
  ARCH="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('arch','?'))" "$RUNTIME_JSON" 2>/dev/null)"
  [[ "$ARCH" == "x64" ]] && pass "runtime.json arch = x64" || fail "runtime.json arch = ${ARCH:-?}（应为 x64）"
else
  fail "找不到 runtime.json（官方包结构可能已变化）"
fi
NODE_BIN="$RES/runtime/primary-runtime/dependencies/node/bin/node"
if [[ -x "$NODE_BIN" ]]; then
  NODE_ARCH="$(file -b "$NODE_BIN")"
  [[ "$NODE_ARCH" == *x86_64* && "$NODE_ARCH" != *arm64* ]] && pass "Node 二进制：x86_64" || fail "Node 二进制架构异常：$NODE_ARCH"
else
  fail "缺少 Node 二进制"
fi

# ---------------------------------------------------------------- 8.3
section "8.3 asar 与原生模块"
if [[ -f "$RES/app.asar" ]]; then
  pass "app.asar 存在（$(du -h "$RES/app.asar" | cut -f1)）"
else
  warn "没有 app.asar（可能是 app/ 目录形态）"
fi
UNPACKED_DIR="$RES/app.asar.unpacked"
if [[ -d "$UNPACKED_DIR" ]]; then
  NODE_COUNT="$(find "$UNPACKED_DIR" -name '*.node' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$NODE_COUNT" -ge 6 ]]; then
    pass "unpacked 内 .node 数量：$NODE_COUNT"
  else
    fail "unpacked 内 .node 只有 $NODE_COUNT 个（期望 ≥6）"
  fi
  if [[ -e "$UNPACKED_DIR/dsh/node_modules/@vscode/ripgrep-darwin-x64/bin/rg" ]]; then
    pass "ripgrep 二进制在 unpacked 内"
  else
    warn "ripgrep 不在 unpacked 内（搜索功能可能异常）"
  fi
else
  fail "缺少 app.asar.unpacked"
fi

# ---------------------------------------------------------------- 8.4
section "8.4 签名封印"
if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  pass "codesign 校验通过"
else
  fail "codesign 校验失败"
  ADDED="$(codesign --verify --verbose=2 "$APP" 2>&1 | grep -c 'file added' || true)"
  if [[ "$ADDED" -gt 0 ]]; then
    info "检测到 $ADDED 个签名后新增的文件，典型原因是运行时写入 .pyc"
    codesign --verify --verbose=2 "$APP" 2>&1 | grep 'file added' | head -5 | sed 's/^/      /'
  fi
fi
SIG_FLAGS="$(codesign -dvv "$APP" 2>&1 || true)"
[[ "$SIG_FLAGS" == *runtime* ]] && pass "hardened runtime 已开启" || warn "未开启 hardened runtime"
[[ "$SIG_FLAGS" == *adhoc* ]] && info "ad-hoc 签名：无 Developer ID / 公证，换机器需手动放行"

# ---------------------------------------------------------------- 8.5
section "8.5 Gatekeeper"
SPCTL="$(spctl --assess --type execute "$APP" 2>&1 | tail -1)"
info "spctl: ${SPCTL:-无输出}"
if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
  warn "带 quarantine 属性：从别处拷来时会拦截，可 xattr -dr com.apple.quarantine \"$APP\""
else
  pass "无 quarantine 属性（本机可直接打开）"
fi

# ---------------------------------------------------------------- 8.6
section "8.6 磁盘空间"
AVAILABLE_MB="$(df -Pk "$(dirname "$APP")" 2>/dev/null | awk 'NR==2 {print int($4 / 1024)}')"
if [[ -n "$AVAILABLE_MB" && "$AVAILABLE_MB" -ge 3000 ]]; then
  pass "可用空间 ${AVAILABLE_MB} MB（构建需要 ≥ 3000 MB）"
else
  warn "可用空间 ${AVAILABLE_MB:-?} MB，低于 3000 MB，构建前建议清理"
fi

# ---------------------------------------------------------------- 8.7
section "8.7 解包数量"
if [[ -d "$UNPACKED_DIR" ]]; then
  FILES="$(find "$UNPACKED_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
  info "unpacked 文件数：$FILES（0.2.2-rc.1 参考值 1616）"
fi
if [[ -f "$RES/app.asar" && -f "$ASAR_CLI" ]]; then
  ENTRIES="$(node "$ASAR_CLI" list "$RES/app.asar" 2>/dev/null | wc -l | tr -d ' ')"
  info "asar 条目数：$ENTRIES（0.2.2-rc.1 参考值 25422）"
fi
if [[ -n "${REF_APP:-}" && -d "$REF_APP" ]]; then
  REF_UNPACKED="$REF_APP/Contents/Resources/app.asar.unpacked"
  if [[ -d "$REF_UNPACKED" ]]; then
    REF_FILES="$(find "$REF_UNPACKED" -type f | wc -l | tr -d ' ')"
    if [[ "${FILES:-0}" -eq "$REF_FILES" ]]; then
      pass "与参考版一致（$REF_FILES 个）"
    else
      fail "与参考版不一致：本版 ${FILES:-0} vs 参考 $REF_FILES"
    fi
  fi
fi

# ---------------------------------------------------------------- 8.8
section "8.8 包结构"
if [[ -f "$RES/app.asar" || -d "$RES/app" ]]; then
  pass "应用入口存在（app.asar 或 app/）"
else
  fail "既没有 app.asar 也没有 app/ 目录"
fi
[[ -x "$RES/runtime/cli/link-entry" ]] && pass "link-entry 可执行" || warn "link-entry 缺失"
[[ -d "$RES/runtime/primary-runtime/dependencies/python" ]] && pass "Python 运行时存在" || warn "Python 运行时缺失"

# ---------------------------------------------------------------- 汇总
section "结果"
if [[ "$FAILS" -eq 0 ]]; then
  printf "  ${GREEN}全部通过${RESET}（警告 %d 项）\n" "$WARNS"
  exit 0
else
  printf "  ${RED}失败 %d 项${RESET}（警告 %d 项）\n" "$FAILS" "$WARNS"
  exit 1
fi
