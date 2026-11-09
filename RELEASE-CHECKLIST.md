# 发版操作清单：官方 arm64 → Intel（x64）

适用：官方发布新的 `deepseek-harness-<版本>-mac-arm64.dmg`，需要产出可在 Intel Mac 安装的 x64 版本。
预计耗时：**10 分钟（构建）＋ 5 分钟（抽检安装）**。上一次 0.2.2-rc.1 的实测参考：`app.asar` 154 MB、
解包 1,616 个文件、DMG 431 MB。

---

## 1. 发布前检查

- [ ] 拿到官方 DMG，确认版本号（文件名里的 `<版本>`）与官方发布页一致
- [ ] 磁盘可用 **≥ 3 GB**：`df -h .`（低于 3 GB 时脚本会自动删上次产物，再不够会直接报错退出）
- [ ] 在**普通终端**里运行，不要在受限沙箱里跑（`hdiutil create` 需要挂载权限）
- [ ] 网络可访问镜像：npmmirror（Electron/npm）、nodejs.org、NJU（python-build-standalone）、PyPI TUNA
- [ ] 备好上一版 DMG 用于回滚
- [ ] 构建阶段**不需要**退出正在使用的 App；只有最后安装替换时才需要

---

## 2. 一条命令构建

```bash
cd Harness桌面版/x64build
./port.sh ~/Downloads/deepseek-harness-<版本>-mac-arm64.dmg
```

常用参数：

| 参数 | 用途 |
| --- | --- |
| `--out <目录>` | 产物目录（默认 `./dist`） |
| `--keep` | 保留中间产物，便于排查 |
| `--no-dmg` | 只产出 `.app` |
| `--no-hardened` | 不启用 hardened runtime（默认启用） |
| `--registry` / `--pip-index` | 换 npm / pip 镜像 |

构建日志的关键节点，出现即说明该阶段正常：

```text
==> 识别 arm64 平台包        # 应列出 8 个 → 对应 x64 包
==> 下载 Electron/Node/Python
==> 替换 Electron/Node/Python
==> 重新打包 app.asar        # 显示解包目录数量（上次 258）
==> 写入 asar 完整性校验
==> 重建 link-entry
==> 预编译 Python 字节码
==> 签名                     # hardened runtime
==> 自检                     # 通过才会继续
==> 打包 DMG
```

---

## 3. 自动校验（脚本已执行，看日志即可）

- [ ] 整包 **0 个 arm64** 二进制
- [ ] `app.asar` 存在，`app.asar.unpacked` 内有原生模块（`.node`）
- [ ] `ElectronAsarIntegrity` 声明值与实际 asar 头 sha256 一致
- [ ] `runtime.json` 的 `arch` 为 `x64`
- [ ] `app-update.yml` 不存在（自动更新已关）
- [ ] Node / Python 可执行，Office 依赖可导入
- [ ] `codesign --verify --deep --strict` 通过，hardened runtime 已开启
- [ ] 唯一允许的警告：**ad-hoc 签名**（无 Developer ID / 公证）

也可以单独复检任意产物：

```bash
./verify.sh "/Applications/DeepSeek Harness.app"
./verify.sh --quick "dist/DeepSeek Harness.app"
```

---

## 4. 人工抽检（每次发版必做）

- [ ] 挂载 DMG，App 能启动，界面完整渲染（不是白屏）
- [ ] 新建会话，发一条消息，流式输出正常结束
- [ ] 工具调用可用（读文件、跑命令）
- [ ] 打开一个历史会话（数据在 `~/.dsh`，应能看到旧记录）
- [ ] 设置里工作区、端口显示正常
- [ ] ⌘Q 退出后无残留：`pgrep -fl dsh-desktop-host` 应为空

---

## 5. 安装与切换

```bash
# 1) 完全退出旧 App（⌘Q），确认没有残留进程
pgrep -fl "DeepSeek Harness" || echo "已退出"

# 2) 拖入 /Applications 替换，或直接：
ditto "dist/DeepSeek Harness.app" "/Applications/DeepSeek Harness.app"

# 3) 从别的机器 / 网盘拷来的包，先去掉隔离属性
xattr -dr com.apple.quarantine "/Applications/DeepSeek Harness.app"
```

**换机后首次打开（macOS 15）**：

1. 双击 DMG，把「DeepSeek Harness」拖进「应用程序」；
2. 双击 App。若提示"无法打开，因为 Apple 无法验证…"，打开
   **系统设置 → 隐私与安全性**，在「安全性」区域点 **仍要打开**，输入密码确认；
   > macOS 15 起右键「打开」已不再能绕过，必须走这一步。
3. 若提示"已损坏，应将其移到废纸篓"，先执行上面的 `xattr -dr`，再重试第 2 步；
4. 首次启动按提示允许 TCC 授权（文档 / 下载 / 麦克风）；
5. 打开设置确认工作区正确，发一条消息验证。

`xattr -l` 可以查看是否还带隔离属性（有 `com.apple.quarantine` 就是没清掉）。

---

## 6. 归档

- [ ] `dist/deepseek-harness-<版本>-mac-x64.dmg` 留一份到归档目录
- [ ] 保存当次构建日志与 `verify.sh` 输出
- [ ] 在下方「发版记录」追加一行
- [ ] 旧版本 DMG 至少保留一版，用于回滚

---

## 7. 回滚

1. 退出 App；
2. 用上一版 DMG 覆盖安装；
3. 数据无需迁移（都在 `~/.dsh`）。

升级前建议备份一次：

```bash
cp -R ~/.dsh ~/.dsh.bak-$(date +%F)
```

---

## 8. 已知坑与排查命令

先设一个变量，下面所有命令都直接用 `$APP`：

```bash
APP="/Applications/DeepSeek Harness.app"
```

一次性体检（覆盖架构、asar、完整性、签名、运行时）：

```bash
cd Harness桌面版/x64build && ./verify.sh --quick "$APP"
```

8.1–8.8 的一键排查（只读，逐条 PASS / WARN / FAIL，有 FAIL 时退出码 1）：

```bash
./triage.sh "$APP"
# 想和上一版对比解包数量：
REF_APP="/path/to/上一版.app" ./triage.sh "$APP"
```

调用示例（健康状态下会看到）：

```text
$ ./triage.sh "/Applications/DeepSeek Harness.app"
  8.1 ✓ app-update.yml 不存在（自动更新已关）   ✓ 主程序：… x86_64
  8.2 ✓ runtime.json arch = x64                ✓ Node 二进制：x86_64
  8.3 ✓ app.asar 存在（154M）                  ✓ unpacked 内 .node 数量：6
  8.4 ✓ codesign 校验通过                      ✓ hardened runtime 已开启
  8.5 spctl: … rejected（预期）                ✓ 无 quarantine 属性
  8.6 ✓ 可用空间 3947 MB（构建需要 ≥ 3000 MB）
  8.7 unpacked 文件数：1616 / asar 条目数：25422
  8.8 ✓ 应用入口存在                           ✓ link-entry 可执行
  结果：全部通过（警告 0 项）                   # 退出码 0
```

### 8.1 升级后又变回 arm64、启动不了

```bash
ls "$APP/Contents/Resources/app-update.yml"     # 应该 No such file
file -b "$APP/Contents/MacOS/DeepSeek Harness"  # 应该是 x86_64
```

**原因**：`app-update.yml` 还在，官方 feed 把 arm64 版本装了回来。
**处置**：删掉该文件，用 x64 DMG 重新安装。

### 8.2 启动报 `primary runtime: incompatible platform or architecture`

```bash
python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['arch'])" \
  "$APP/Contents/Resources/runtime/primary-runtime/runtime.json"   # 应为 x64
file -b "$APP/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node"
```

**原因**：`runtime.json` 的 `arch` 没改，或 Node 二进制还是 arm64。
**处置**：重新跑 `port.sh`（这两处都会自动处理）。

### 8.3 界面白屏 / 原生模块加载失败

```bash
ls -lh "$APP/Contents/Resources/app.asar"
find "$APP/Contents/Resources/app.asar.unpacked" -name '*.node' | wc -l        # 期望 6
ls "$APP/Contents/Resources/app.asar.unpacked/dsh/node_modules/@vscode/ripgrep-darwin-x64/bin/rg"
```

**原因**：asar 解包集合缺原生目录，`.node` 被压在归档里无法 dlopen。
**处置**：用 `port.sh` 重新打包；解包目录必须从官方 `app.asar.unpacked` 推导，
并补上平台包根目录与 `node-pty`。

### 8.4 签名后自检报 `file added: …*.pyc`

```bash
codesign --verify --verbose=2 "$APP" 2>&1 | grep "file added" | head
find "$APP/Contents/Resources/runtime/primary-runtime/dependencies/python" \
  -name '*.pyc' -newer "$APP/Contents/_CodeSignature/CodeResources" | head
```

**原因**：Python 在签名之后往 App 里写了字节码，破坏签名封印。
**处置**：重新构建（脚本会在签名前 `compileall`，校验时带 `PYTHONDONTWRITEBYTECODE=1`）。

### 8.5 Gatekeeper 拒绝打开

```bash
spctl --assess --type execute -vv "$APP"
xattr -l "$APP" | grep -i quarantine        # 有输出说明带了 quarantine
```

**原因**：ad-hoc 签名、没有公证，属于预期结果。
**处置**：本机右键「打开」；如果是从别处拷来的，先
`xattr -dr com.apple.quarantine "$APP"`。

### 8.6 构建到一半 `No space left on device`

```bash
df -h .
du -sh dist/* port-work 2>/dev/null
rm -rf "dist/DeepSeek Harness.app" dist/*.dmg port-work
df -h .
```

**处置**：脚本在可用空间低于 3 GB 时会自动清理旧产物；清理后仍不足会直接报错退出，
这时换 `--out` 到更大的卷，或先清缓存。打包阶段（asar）最吃空间，脚本会先删下载目录。

### 8.7 解包文件数和参考版对不上

```bash
find "$APP/Contents/Resources/app.asar.unpacked" -type f | wc -l      # 0.2.2-rc.1 为 1616
node tools/node_modules/@electron/asar/bin/asar.mjs list \
  "$APP/Contents/Resources/app.asar" | wc -l                          # 0.2.2-rc.1 为 25422
```

**原因**：嵌套 `node_modules` 副本被解包，或平台包根目录没解包。
**处置**：对照上一版参考包逐文件比较（`comm`），确认「嵌套副本保持打包」规则生效。

### 8.8 官方包结构变了（没有 `app.asar` / `runtime.json`）

```bash
hdiutil attach -nobrowse -readonly -mountpoint /tmp/dsh-mnt "<官方DMG>"
ls "/tmp/dsh-mnt/DeepSeek Harness.app/Contents/Resources"
ls "/tmp/dsh-mnt/DeepSeek Harness.app/Contents/Resources/runtime/primary-runtime/runtime.json"
hdiutil detach /tmp/dsh-mnt
```

**处置**：脚本会以 `找不到 app.asar（结构已变化，需要调整脚本）` 之类的信息明确报错；
先按新结构调整 `port.sh`，再发版。

## 9. 不要做的事

- ❌ 改 `app/` 里的业务 JS（升级成本会指数上升）
- ❌ 打开自动更新（会把 arm64 版本装回来）
- ❌ 为了瘦身删除 LibreOffice Kit / sherpa（会丢功能）
- ❌ 在受限沙箱里打 DMG（`hdiutil` 会失败）

---

## 10. 发版记录

| 日期 | 官方版本 | 产物 | 结果 | 备注 |
| --- | --- | --- | --- | --- |
| 2026-11-08 | 0.2.2-rc.1 | `deepseek-harness-0.2.2-rc.1-mac-x64.dmg` | 通过 | asar 154 MB / 解包 1,616 / DMG 431 MB |
|  |  |  |  |  |
