> 本仓库只发布**构建工具与文档**，不分发安装包；`dist/` 下的产物由 `port.sh` 在本地生成，请自行校验与保存。

2026-11-09

基于官方 `deepseek-harness-0.2.2-rc.1-mac-arm64.dmg` 移植到 Intel Mac 的构建工具与说明。
本仓库**不提供二进制下载**——请用 `port.sh` 从官方 DMG 自行构建，再用 `verify.sh` / `triage.sh` 校验。

### 构建

```bash
git clone https://github.com/619025226-lab/dsh-harness-intel
cd dsh-harness-intel
./port.sh ~/Downloads/deepseek-harness-0.2.2-rc.1-mac-arm64.dmg
```

产物在 `dist/`：`DeepSeek Harness.app` 与 `deepseek-harness-0.2.2-rc.1-mac-x64.dmg`。
构建需要可用空间 ≥ 3 GB，脚本会自行清理旧产物与下载目录。

### 校验

```bash
./verify.sh "dist/DeepSeek Harness.app"   # 全量体检
./triage.sh "dist/DeepSeek Harness.app"   # 8 类坑位逐条排查
```

### 安装（自行构建后）

```bash
xattr -dr com.apple.quarantine "/Applications/DeepSeek Harness.app"
```

**换机后首次打开（macOS 15）**

1. 双击 DMG，把「DeepSeek Harness」拖进「应用程序」；
2. 双击 App。若提示"无法打开，因为 Apple 无法验证…"，打开
   **系统设置 → 隐私与安全性**，在「安全性」区域点 **仍要打开**，输入密码确认；
   > macOS 15 起右键「打开」已不再能绕过，必须走这一步。
3. 若提示"已损坏，应将其移到废纸篓"，先执行上面的 `xattr -dr`，再重试第 2 步；
4. 首次启动按提示允许 TCC 授权（文档 / 下载 / 麦克风）；
5. 打开设置确认工作区正确，发一条消息验证。

### 本次变更

- 运行时全部替换为 x86_64：Electron 44.7.0、Node 24.21.0、Python 3.12.14（含 numpy / pandas / lxml / Pillow 等 Office 依赖）；
- 8 个平台包换成同版本 `*-darwin-x64`，补 `node-pty` 的 darwin-x64 prebuild；
- 保留 `app.asar` 并重写 `ElectronAsarIntegrity`（与实际归档一致，启动时校验）；
- 解包布局与官方一致：`app.asar.unpacked` 1,616 个文件；整包 0 个 arm64 二进制；
- hardened runtime 签名，沿用原版 entitlements（JIT / 可执行内存 / 库校验 / 麦克风）；
- 删除 `app-update.yml` 关闭自动更新（避免被官方 feed 拉回 arm64）；
- `runtime.json` 的 `arch` 改为 `x64`。

### 已知限制

- **ad-hoc 签名、无公证**：本机可直接运行；换机器或经网盘传输会被 Gatekeeper 拦，按上面的步骤放行；
- **无自动更新**：每次官方发新版需重新构建，不能直接升级；
- **仅 Intel**：Apple Silicon 上需经 Rosetta 运行，建议直接用官方原版；
- **不随仓库分发二进制**：构建产物请自行保存与校验。

---

完整变更、构建流程与校验脚本见仓库中的 `README.md`、`RELEASE-CHECKLIST.md` 与 `triage.sh`。
