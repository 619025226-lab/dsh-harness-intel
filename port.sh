#!/bin/bash
# DeepSeek Harness：把官方 macOS arm64 DMG 移植成 Intel（x64）可运行的 DMG。
#
#   ./port.sh /path/to/deepseek-harness-<ver>-mac-arm64.dmg
#   ./port.sh <dmg> --out ./dist --keep          # 保留中间产物，便于排查
#   ./port.sh <dmg> --no-dmg                     # 只产出 .app，不打包 DMG
#   ./port.sh <dmg> --install                    # 额外安装到 /Applications（会覆盖同名 App）
#   ./port.sh <dmg> --no-hardened                # 不启用 hardened runtime（默认启用并沿用原版 entitlements）
#
# 产物：<out>/DeepSeek Harness.app 与 <out>/deepseek-harness-<ver>-mac-x64.dmg
# 打包形态：app.asar + 原生模块 app.asar.unpacked + ElectronAsarIntegrity 校验
# 全部工作在 work 目录完成，不会改动正在运行的 App。
# 磁盘：开始前可用空间低于 3 GB 时先删掉上次产物与中间目录（仍不足则报错退出），打包前再释放约 0.7 GB 的下载目录。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

DMG=""
OUT_DIR="$SCRIPT_DIR/dist"
WORK_DIR=""
KEEP=0
NO_DMG=0
INSTALL=0
FORCE=0
HARDENED=1
NPM_REGISTRY="https://registry.npmmirror.com"
PIP_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
ELECTRON_BASE="https://cdn.npmmirror.com/binaries/electron"
NODE_BASE="https://nodejs.org/dist"
PYTHON_MIRROR="https://mirrors.nju.edu.cn/github-release/astral-sh/python-build-standalone"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="${2:?--out 需要一个目录}"; shift 2 ;;
    --work) WORK_DIR="${2:?--work 需要一个目录}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --no-dmg) NO_DMG=1; shift ;;
    --install) INSTALL=1; shift ;;
    --no-hardened) HARDENED=0; shift ;;
    --force) FORCE=1; shift ;;
    --registry) NPM_REGISTRY="${2:?}"; shift 2 ;;
    --pip-index) PIP_INDEX="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf "%s未知参数：%s%s\n" "$RED" "$1" "$RESET" >&2; usage; exit 2 ;;
    *) DMG="$1"; shift ;;
  esac
done

log()  { printf "\n${BOLD}==> %s${RESET}\n" "$*"; }
info() { printf "  %s\n" "$*"; }
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "\n${RED}✗ %s${RESET}\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 前置检查

log "检查环境"
for tool in curl ditto hdiutil plutil python3 clang node npm xcrun; do
  command -v "$tool" >/dev/null 2>&1 || die "缺少命令：$tool"
done
ok "命令行工具齐全"

[[ -n "$DMG" ]] || die "用法：./port.sh /path/to/…-mac-arm64.dmg（-h 查看全部参数）"
[[ -f "$DMG" ]] || die "找不到 DMG：$DMG"
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"
[[ "$(uname -s)" == "Darwin" ]] || die "只能在 macOS 上运行"

WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/port-work}"
mkdir -p "$WORK_DIR/downloads" "$WORK_DIR/tools" "$OUT_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# ---------------------------------------------------------------- 磁盘预检

free_mb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4 / 1024)}'; }
NEED_MB=3000
AVAILABLE_MB="$(free_mb "$OUT_DIR")"
if [[ -z "$AVAILABLE_MB" ]]; then
  warn "无法读取磁盘可用空间，跳过预检"
elif (( AVAILABLE_MB < NEED_MB )); then
  warn "可用空间 ${AVAILABLE_MB} MB，低于建议的 ${NEED_MB} MB；先清理上次产物和中间目录"
  rm -rf "$OUT_DIR/DeepSeek Harness.app" "$OUT_DIR"/*.dmg 2>/dev/null || true
  rm -rf "$WORK_DIR/app" "$WORK_DIR/stage" "$WORK_DIR/downloads" "$WORK_DIR/dmg"
  AVAILABLE_MB="$(free_mb "$OUT_DIR")"
  if (( AVAILABLE_MB < NEED_MB )); then
    die "清理后仍只有 ${AVAILABLE_MB} MB；请手动清理磁盘（建议 ≥ ${NEED_MB} MB），或用 --out 指到空间更大的卷"
  fi
  ok "清理后可用 ${AVAILABLE_MB} MB"
else
  ok "可用空间 ${AVAILABLE_MB} MB"
fi

# hdiutil / 编译缓存对 TMPDIR 敏感（某些受限环境不可写）
export TMPDIR="$WORK_DIR/tmp"
mkdir -p "$TMPDIR" "$WORK_DIR/module-cache"

MNT="$WORK_DIR/mnt"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" -eq 1 ]]; then
    hdiutil detach "$MNT" >/dev/null 2>&1 || true
    MOUNTED=0
  fi
  if [[ "$KEEP" -eq 0 ]]; then
    rm -rf "$WORK_DIR/app" "$WORK_DIR/stage" "$WORK_DIR/dmg" "$WORK_DIR/src" \
           "$WORK_DIR/DeepSeek Harness.app" "$WORK_DIR/module-cache" "$WORK_DIR/tmp"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- 挂载源 DMG

log "挂载官方 DMG"
# 同一张 DMG 可能已经被挂在别处（例如上一次调试遗留），这种情况下复用它，
# 不再重复 attach，也不负责在退出时卸载。
EXISTING_MNT="$(hdiutil info 2>/dev/null | python3 -c '
import sys
image = sys.argv[1]
current = None
for line in sys.stdin.read().splitlines():
    if line.startswith("image-path"):
        current = line.split(":", 1)[1].strip()
    elif current == image and line.startswith("/dev/disk"):
        parts = line.split("\t")
        if len(parts) >= 3 and parts[-1].startswith("/"):
            print(parts[-1])
            break
' "$DMG")"

if [[ -n "$EXISTING_MNT" && -d "$EXISTING_MNT" ]]; then
  MNT="$EXISTING_MNT"
  MOUNTED=0
  ok "复用已挂载的镜像：$MNT"
else
  mkdir -p "$MNT"
  hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null 2>&1 \
    || die "无法挂载 $DMG（如果它已在别处挂载，请先 hdiutil detach）"
  MOUNTED=1
fi
SRC_APP="$(find "$MNT" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$SRC_APP" ]] || die "DMG 里没有 .app"
ok "$(basename "$SRC_APP")"

PLIST="$SRC_APP/Contents/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
EXEC_NAME="$(plutil -extract CFBundleExecutable raw "$PLIST")"
ELECTRON_VER="$(plutil -extract CFBundleVersion raw \
  "$SRC_APP/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist")"
RES="$SRC_APP/Contents/Resources"
RES_REL="Contents/Resources"
RUNTIME_JSON="$RES/runtime/primary-runtime/runtime.json"
RUNTIME_REL="$RES_REL/runtime/primary-runtime/runtime.json"
[[ -f "$RUNTIME_JSON" ]] || die "找不到 runtime.json"
NODE_VER="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['node'])" "$RUNTIME_JSON")"
PY_VER="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['python'])" "$RUNTIME_JSON")"

info "版本 $VERSION · Electron $ELECTRON_VER · Node $NODE_VER · Python $PY_VER"

# ---------------------------------------------------------------- 解包 app

log "解包 app.asar"
ASAR="$RES/app.asar"
[[ -f "$ASAR" ]] || die "这个包没有 app.asar（结构已变化，需要调整脚本）"
ASAR_CLI="$WORK_DIR/tools/node_modules/@electron/asar/bin/asar.mjs"
if [[ ! -f "$ASAR_CLI" ]]; then
  npm install --prefix "$WORK_DIR/tools" @electron/asar \
    --registry="$NPM_REGISTRY" --cache "$WORK_DIR/npm-cache" --logs-dir "$WORK_DIR/npm-logs" \
    --no-audit --no-fund --loglevel=error >/dev/null
fi
rm -rf "$WORK_DIR/app"
node "$ASAR_CLI" extract "$ASAR" "$WORK_DIR/app"
APP_DST="$OUT_DIR/DeepSeek Harness.app"
rm -rf "$APP_DST"
ditto "$SRC_APP" "$APP_DST"
ok "已解包 $(find "$WORK_DIR/app" -type f | wc -l | tr -d ' ') 个文件"

NM="$WORK_DIR/app/dsh/node_modules"
[[ -d "$NM" ]] || die "找不到 dsh/node_modules"

# ---------------------------------------------------------------- 平台包清单

log "识别 arm64 平台包"
PKG_SPECS=()
ARCH_PKG_DIRS=()
if [[ -d "$NM" ]]; then
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    pkgjson="$dir/package.json"
    [[ -f "$pkgjson" ]] || { warn "跳过无 package.json 的 $(basename "$dir")"; continue; }
    read -r name ver < <(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('name',''),d.get('version',''))" "$pkgjson")
    [[ -n "$name" ]] || continue
    x64="${name%-darwin-arm64}-darwin-x64"
    PKG_SPECS+=("$x64@$ver")
    ARCH_PKG_DIRS+=("$name")
    info "$name@$ver → $x64@$ver"
  done < <(find "$NM" -maxdepth 2 -type d -name '*-darwin-arm64' 2>/dev/null | sort)
fi

NODE_PTY_VER="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" \
  "$NM/node-pty/package.json" 2>/dev/null || true)"
if [[ -n "$NODE_PTY_VER" ]]; then info "node-pty@$NODE_PTY_VER → prebuilds/darwin-x64"; fi

[[ "${#PKG_SPECS[@]}" -gt 0 ]] || die "没有发现任何 arm64 平台包，包结构可能已变化"

# ---------------------------------------------------------------- 下载 x64 组件

DL="$WORK_DIR/downloads"

log "下载 Electron $ELECTRON_VER (darwin-x64)"
if [[ ! -d "$DL/electron/Electron.app" ]]; then
  rm -rf "$DL/electron" "$DL/electron.zip"
  curl -sS -fL --retry 3 --connect-timeout 20 --max-time 1800 -o "$DL/electron.zip" \
    "$ELECTRON_BASE/$ELECTRON_VER/electron-v$ELECTRON_VER-darwin-x64.zip" \
    || curl -sS -fL --retry 2 --connect-timeout 20 --max-time 1800 -o "$DL/electron.zip" \
       "https://github.com/electron/electron/releases/download/v$ELECTRON_VER/electron-v$ELECTRON_VER-darwin-x64.zip" \
    || die "Electron 下载失败"
  mkdir -p "$DL/electron"
  ditto -x -k "$DL/electron.zip" "$DL/electron"
  rm -f "$DL/electron.zip"
fi
ok "$(file -b "$DL/electron/Electron.app/Contents/MacOS/Electron" | head -1)"

log "下载 Node $NODE_VER (darwin-x64)"
if [[ ! -f "$DL/node/bin/node" ]]; then
  rm -rf "$DL/node" "$DL/node.tar.gz"
  curl -sS -fL --retry 3 --connect-timeout 20 --max-time 1800 -o "$DL/node.tar.gz" \
    "$NODE_BASE/v$NODE_VER/node-v$NODE_VER-darwin-x64.tar.gz" \
    || curl -sS -fL --retry 2 --connect-timeout 20 --max-time 1800 -o "$DL/node.tar.gz" \
       "https://cdn.npmmirror.com/binaries/node/v$NODE_VER/node-v$NODE_VER-darwin-x64.tar.gz" \
    || die "Node 下载失败"
  mkdir -p "$DL/node"
  tar -xzf "$DL/node.tar.gz" -C "$DL/node" --strip-components=1
  rm -f "$DL/node.tar.gz"
fi
ok "$("$DL/node/bin/node" -v)"

log "下载 Python $PY_VER (x86_64)"
if [[ ! -x "$DL/python/python/bin/python3" ]]; then
  rm -rf "$DL/python" "$DL/python.tar.gz"

  # 先在 GitHub API 里找对应的 release tag，失败则退回镜像目录列表探测。
  PY_RELEASE=""
  for attempt in 1 2 3; do
    BODY="$(curl -sS -f --retry 2 --connect-timeout 15 --max-time 90 \
      "https://api.github.com/repos/astral-sh/python-build-standalone/releases?per_page=50" 2>/dev/null || true)"
    [[ -n "$BODY" ]] || { sleep 2; continue; }
    PY_RELEASE="$(printf '%s' "$BODY" | python3 -c '
import json, sys
version = sys.argv[1]
try:
    releases = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for release in releases:
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        if name.startswith("cpython-" + version + "+") and name.endswith("-x86_64-apple-darwin-install_only.tar.gz"):
            print(release["tag_name"])
            raise SystemExit(0)
raise SystemExit(1)
' "$PY_VER" 2>/dev/null || true)"
    [[ -n "$PY_RELEASE" ]] && break
    sleep 2
  done

  if [[ -z "$PY_RELEASE" ]]; then
    warn "GitHub API 不可用，改为探测镜像目录"
    LISTING="$(curl -sS -f --max-time 45 "$PYTHON_MIRROR/" 2>/dev/null || true)"
    for tag in $(printf '%s' "$LISTING" | grep -oE '20[0-9]{6}' | sort -ru | head -12); do
      if curl -sS -fI --max-time 20 \
        "$PYTHON_MIRROR/$tag/cpython-$PY_VER%2B$tag-x86_64-apple-darwin-install_only.tar.gz" >/dev/null 2>&1; then
        PY_RELEASE="$tag"
        break
      fi
    done
  fi
  [[ -n "$PY_RELEASE" ]] || die "找不到 Python $PY_VER 的 x64 构建（GitHub API 与镜像都不可用）"

  ASSET_URL="$PYTHON_MIRROR/$PY_RELEASE/cpython-$PY_VER%2B$PY_RELEASE-x86_64-apple-darwin-install_only.tar.gz"
  curl -sS -fL --retry 3 --connect-timeout 20 --max-time 1800 -o "$DL/python.tar.gz" "$ASSET_URL" \
    || curl -sS -fL --retry 2 --connect-timeout 20 --max-time 1800 -o "$DL/python.tar.gz" \
       "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_RELEASE/cpython-$PY_VER%2B$PY_RELEASE-x86_64-apple-darwin-install_only.tar.gz" \
    || die "Python 下载失败"
  mkdir -p "$DL/python"
  tar -xzf "$DL/python.tar.gz" -C "$DL/python" --strip-components=1
  rm -f "$DL/python.tar.gz"
fi
ok "$("$DL/python/bin/python3" -V 2>&1)"

log "安装 x64 平台包（$NPM_REGISTRY）"
rm -rf "$WORK_DIR/stage"
npm install --prefix "$WORK_DIR/stage" "${PKG_SPECS[@]}" ${NODE_PTY_VER:+"node-pty@$NODE_PTY_VER"} \
  --registry="$NPM_REGISTRY" --cache "$WORK_DIR/npm-cache" --logs-dir "$WORK_DIR/npm-logs" \
  --no-audit --no-fund --loglevel=error >/dev/null || die "npm 安装 x64 平台包失败"
ok "$(ls "$WORK_DIR/stage/node_modules" | wc -l | tr -d ' ') 个包"

# ---------------------------------------------------------------- 替换运行时

log "替换 Electron"
EL_APP="$DL/electron/Electron.app/Contents"
cp -f "$EL_APP/MacOS/Electron" "$APP_DST/Contents/MacOS/$EXEC_NAME"
chmod 755 "$APP_DST/Contents/MacOS/$EXEC_NAME"

for fw in "Electron Framework" "Squirrel" "Mantle" "ReactiveObjC"; do
  if [[ -d "$EL_APP/Frameworks/$fw.framework" ]]; then
    rm -rf "$APP_DST/Contents/Frameworks/$fw.framework"
    ditto "$EL_APP/Frameworks/$fw.framework" "$APP_DST/Contents/Frameworks/$fw.framework"
  fi
done

for helper in "$APP_DST/Contents/Frameworks/"*" Helper"*.app; do
  [[ -d "$helper" ]] || continue
  base="$(basename "$helper" .app)"
  suffix="${base#*Helper}"
  src="$EL_APP/Frameworks/Electron Helper${suffix}.app/Contents/MacOS/Electron Helper${suffix}"
  dst="$helper/Contents/MacOS/$base"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dst"
    chmod 755 "$dst"
    ok "$base"
  else
    warn "找不到对应的 x64 Helper：$suffix"
  fi
done

log "替换 Node"
NODE_DST="$APP_DST/$RES_REL/runtime/primary-runtime/dependencies/node"
mkdir -p "$NODE_DST"
cp -f "$DL/node/bin/node" "$NODE_DST/bin/node"
chmod 755 "$NODE_DST/bin/node"
ok "$("$NODE_DST/bin/node" -v)"

log "替换 Python"
PY_DST="$APP_DST/$RES_REL/runtime/primary-runtime/dependencies/python"
rm -rf "$PY_DST"
ditto "$DL/python" "$PY_DST"
PIP_SPECS=()
while IFS=$'\t' read -r name ver; do
  [[ -n "$name" ]] && PIP_SPECS+=("$name==$ver")
done < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1])).get("pythonPackages",{})
for k,v in d.items(): print(f"{k}\t{v}")
' "$RUNTIME_JSON")
if [[ "${#PIP_SPECS[@]}" -gt 0 ]]; then
  "$PY_DST/bin/python3" -m pip install --no-cache-dir --disable-pip-version-check \
    --index-url "$PIP_INDEX" "${PIP_SPECS[@]}" >"$WORK_DIR/pip.log" 2>&1 \
    || "$PY_DST/bin/python3" -m pip install --no-cache-dir --disable-pip-version-check \
       --index-url https://pypi.org/simple "${PIP_SPECS[@]}" >>"$WORK_DIR/pip.log" 2>&1 \
    || { tail -20 "$WORK_DIR/pip.log"; die "Python 依赖安装失败（见 $WORK_DIR/pip.log）"; }
fi
ok "$("$PY_DST/bin/python3" -V 2>&1)"

log "替换 dsh 原生模块"
for spec in "${PKG_SPECS[@]}"; do
  name="${spec%@*}"
  [[ -d "$WORK_DIR/stage/node_modules/$name" ]] || { warn "stage 里缺 $name"; continue; }
  rm -rf "$NM/$name"
  ditto "$WORK_DIR/stage/node_modules/$name" "$NM/$name"
done
if [[ -n "$NODE_PTY_VER" && -d "$WORK_DIR/stage/node_modules/node-pty/prebuilds/darwin-x64" ]]; then
  ditto "$WORK_DIR/stage/node_modules/node-pty/prebuilds/darwin-x64" \
    "$NM/node-pty/prebuilds/darwin-x64"
  ok "node-pty prebuilds/darwin-x64"
fi
for name in "${ARCH_PKG_DIRS[@]}"; do
  rm -rf "$NM/$name"
done
rm -rf "$NM/node-pty/prebuilds/darwin-arm64"
ok "arm64 平台包已移除"

# 运行时与 Electron 都已替换完毕，下载目录不再需要；打包阶段最吃磁盘，先释放
rm -rf "$WORK_DIR/downloads"
ok "已删除下载目录，释放空间"
log "重新打包 app.asar"
ASAR_OUT="$APP_DST/$RES_REL/app.asar"
rm -rf "$APP_DST/$RES_REL/app" "$ASAR_OUT" "$ASAR_OUT.unpacked"

# 解包目录沿用官方包的 app.asar.unpacked 布局（把 darwin-arm64 换成 darwin-x64），
# 这样原生模块、LibreOffice、ripgrep、sherpa 等的位置与官方一致。
UNPACK_LIST="$(python3 - "$SRC_APP" <<'PY'
import os, sys
root = os.path.join(sys.argv[1], "Contents/Resources/app.asar.unpacked")
dirs = set()
if os.path.isdir(root):
    for dirpath, _, files in os.walk(root):
        for name in files:
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            parent = os.path.dirname(rel)
            # 嵌套在别的包里的 node_modules 副本保持打包（官方包偶尔会解包，
            # 但参考版并没有放出来，排除后解包数量才能对齐）
            if parent and parent.count("/node_modules/") <= 1:
                dirs.add(parent.replace("darwin-arm64", "darwin-x64"))
print("\n".join(sorted(set(dirs))))
PY
)"
# 参考版还把各个 x64 平台包整目录解包（package.json / LICENSE / index.cjs 等也在外面）
for spec in "${PKG_SPECS[@]}"; do
  UNPACK_LIST+=$'\n'"dsh/node_modules/${spec%@*}"
done
# 参考版把 node-pty 整个包都放在 asar 外（含 prebuilds 与 JS）
if [[ -d "$NM/node-pty" ]]; then
  UNPACK_LIST+=$'\n'"dsh/node_modules/node-pty"
fi
UNPACK_DIRS="{$(printf '%s\n' "$UNPACK_LIST" | awk 'NF' | sort -u | paste -sd, -)}"
if [[ "$UNPACK_DIRS" == "{}" ]]; then
  warn "官方包里没有 app.asar.unpacked，退回最小解包集合"
  UNPACK_DIRS='{dsh/node_modules/@vscode/ripgrep-darwin-x64,dsh/node_modules/@deepseek-ai/libreoffice-kit-darwin-x64,dsh/node_modules/sherpa-onnx-darwin-x64,dsh/node_modules/@img/sharp-libvips-darwin-x64,dsh/node_modules/@koromix/koffi-darwin-x64,dsh/node_modules/node-addon-require-builtin-darwin-x64,dsh/node_modules/@deepseek-ai/node-addon-system-darwin-x64,dsh/node_modules/node-pty/prebuilds}'
fi
ok "解包目录 $(printf '%s' "$UNPACK_DIRS" | tr ',' '\n' | wc -l | tr -d ' ') 个（沿用官方布局）"

node "$ASAR_CLI" pack "$WORK_DIR/app" "$ASAR_OUT" \
  --unpack '{*.node,*.dylib}' \
  --unpack-dir "$UNPACK_DIRS" \
  >/dev/null || die "asar 打包失败"
[[ -f "$ASAR_OUT" ]] || die "asar 没有生成"
ok "app.asar $(du -h "$ASAR_OUT" | cut -f1)，unpacked $(find "$ASAR_OUT.unpacked" -type f 2>/dev/null | wc -l | tr -d ' ') 个文件"
[[ "$KEEP" -eq 0 ]] && rm -rf "$WORK_DIR/app"

log "修正元数据"
python3 - "$APP_DST/$RUNTIME_REL" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)
data["arch"] = "x64"
with open(path, "w") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
PY
ok "runtime.json arch = x64"

rm -f "$APP_DST/$RES_REL/app-update.yml"
ok "已关闭自动更新"

log "写入 asar 完整性校验"
python3 - "$APP_DST/$RES_REL/app.asar" "$APP_DST/Contents/Info.plist" <<'PY'
import hashlib, plistlib, struct, sys
asar_path, plist_path = sys.argv[1], sys.argv[2]
with open(asar_path, "rb") as handle:
    head = handle.read(16)
    size = struct.unpack("<I", head[12:16])[0]
    header = handle.read(size)
digest = hashlib.sha256(header).hexdigest()
with open(plist_path, "rb") as handle:
    info = plistlib.load(handle)
info.setdefault("ElectronAsarIntegrity", {})["Resources/app.asar"] = {
    "algorithm": "SHA256",
    "hash": digest,
}
with open(plist_path, "wb") as handle:
    plistlib.dump(info, handle)
print("  sha256:", digest)
PY
ok "ElectronAsarIntegrity 已写入"

log "重建 link-entry"
clang -arch x86_64 -mmacosx-version-min=13.0 -O2 "$SCRIPT_DIR/tools/link-entry.c" \
  -o "$APP_DST/$RES_REL/runtime/cli/link-entry" || die "link-entry 编译失败"
chmod 755 "$APP_DST/$RES_REL/runtime/cli/link-entry"
ok "$(file -b "$APP_DST/$RES_REL/runtime/cli/link-entry" | head -1)"

# ---------------------------------------------------------------- 签名

log "预编译 Python 字节码"
"$PY_DST/bin/python3" -m compileall -q -f "$PY_DST/lib/python3.12" >/dev/null 2>&1 \
  && ok "已预编译（避免运行时往 App 里写 .pyc 破坏签名封印）" \
  || warn "预编译有部分失败，运行时可能会新增 .pyc"

log "签名"
xattr -cr "$APP_DST" 2>/dev/null || true
ENT_PLIST="$WORK_DIR/entitlements.plist"
SIGN_ARGS=(--force --deep --sign -)
if [[ "$HARDENED" -eq 1 ]]; then
  rm -f "$ENT_PLIST"
  codesign -d --entitlements :- "$SRC_APP" 2>/dev/null | sed -n '/<?xml/,$p' >"$ENT_PLIST" || true
  if [[ -s "$ENT_PLIST" ]] && plutil -lint "$ENT_PLIST" >/dev/null 2>&1; then
    SIGN_ARGS=(--force --deep --options runtime --entitlements "$ENT_PLIST" --sign -)
    ok "沿用原版 entitlements（hardened runtime）"
  else
    warn "读不到原版 entitlements，退回普通 ad-hoc 签名"
  fi
fi
codesign "${SIGN_ARGS[@]}" "$APP_DST" 2>/dev/null || codesign --force --deep --sign - "$APP_DST" || die "签名失败"
codesign --verify --deep --strict "$APP_DST" || die "签名校验失败"
ok "签名完成"

# ---------------------------------------------------------------- 自检

if [[ -x "$SCRIPT_DIR/verify.sh" ]]; then
  log "自检"
  if ! "$SCRIPT_DIR/verify.sh" --quick "$APP_DST"; then
    die "自检未通过，产物保留在 $APP_DST"
  fi
fi

# ---------------------------------------------------------------- 打包 DMG

if [[ "$NO_DMG" -eq 0 ]]; then
  log "打包 DMG"
  DMG_STAGE="$WORK_DIR/dmg"
  rm -rf "$DMG_STAGE"
  mkdir -p "$DMG_STAGE"
  ditto "$APP_DST" "$DMG_STAGE/$(basename "$APP_DST")"
  ln -s /Applications "$DMG_STAGE/Applications"
  for meta in .DS_Store .background.tiff .VolumeIcon.icns; do
    if [[ -f "$MNT/$meta" ]]; then cp "$MNT/$meta" "$DMG_STAGE/" 2>/dev/null || true; fi
  done
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  MOUNTED=0
  OUT_DMG="$OUT_DIR/deepseek-harness-${VERSION}-mac-x64.dmg"
  rm -f "$OUT_DMG"
  hdiutil create -volname "$(basename "$SRC_APP" .app)" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO -imagekey zlib-level=9 "$OUT_DMG" >/dev/null \
    || die "DMG 打包失败（需要挂载权限，请在普通终端里运行）"
  ok "$OUT_DMG（$(du -h "$OUT_DMG" | cut -f1)）"
fi

# ---------------------------------------------------------------- 安装

if [[ "$INSTALL" -eq 1 ]]; then
  log "安装到 /Applications"
  if pgrep -f "/Applications/$(basename "$SRC_APP" .app).app/Contents/MacOS/" >/dev/null 2>&1; then
    die "目标 App 正在运行，请先退出再 --install（或手动替换）"
  fi
  rm -rf "/Applications/$(basename "$SRC_APP" .app)"
  ditto "$APP_DST" "/Applications/$(basename "$SRC_APP" .app)"
  ok "已安装"
fi

log "完成"
info "App：$APP_DST"
if [[ "$NO_DMG" -eq 0 ]]; then info "DMG：$OUT_DIR/deepseek-harness-${VERSION}-mac-x64.dmg"; fi
info "提示：官方发新版后重跑本脚本即可；--install 前请先退出正在运行的 App。"
