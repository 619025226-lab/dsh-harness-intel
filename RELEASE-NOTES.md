2026-11-09

基于官方 `deepseek-harness-0.2.2-rc.1-mac-arm64.dmg` 移植到 Intel Mac 的可运行版本。
业务代码与官方逐字节一致，只替换了运行时二进制与打包形态。

推荐用仓库里的 `install.sh` 一键下载、校验并打开安装包；也可以手动下载附件，或自行构建。

### 安装（推荐）

```bash
git clone https://github.com/619025226-lab/dsh-harness-intel
cd dsh-harness-intel
./install.sh
```

`install.sh` 会依次：下载 DMG → 校验大小与 sha256 → 清除 quarantine → 打开安装包。
任一校验失败都会以非 0 退出，不会打开安装包。

把「DeepSeek Harness」拖进「应用程序」后，首次打开按下面处理：

**换机后首次打开（macOS 15）**

1. 双击 App。若提示"无法打开，因为 Apple 无法验证…"，打开
   **系统设置 → 隐私与安全性**，在「安全性」区域点 **仍要打开**，输入密码确认；
   > macOS 15 起右键「打开」已不再能绕过，必须走这一步。
2. 若提示"已损坏，应将其移到废纸篓"，执行
   `xattr -dr com.apple.quarantine "/Applications/DeepSeek Harness.app"`，再重试第 1 步；
3. 首次启动按提示允许 TCC 授权（文档 / 下载 / 麦克风）；
4. 打开设置确认工作区正确，发一条消息验证。

### 手动下载与校验

| 项目 | 值 |
| --- | --- |
| 文件名 | `deepseek-harness-0.2.2-rc.1-mac-x64.dmg` |
| 大小 | 448,895,877 字节（428 MB） |
| sha256 | `ca7ed0f6dfe06e78b2766aa210009e6d4153bccf7c58f7b91380c08ab7c1b329` |
| 架构 | thin x86_64（macOS 14+） |

```bash
shasum -a 256 deepseek-harness-0.2.2-rc.1-mac-x64.dmg   # 应与上表一致
xattr -dr com.apple.quarantine deepseek-harness-0.2.2-rc.1-mac-x64.dmg
open deepseek-harness-0.2.2-rc.1-mac-x64.dmg
```

### 自行构建（可选）

```bash
./port.sh ~/Downloads/deepseek-harness-0.2.2-rc.1-mac-arm64.dmg
./verify.sh "dist/DeepSeek Harness.app"
./triage.sh "dist/DeepSeek Harness.app"
```

构建需要可用空间 ≥ 3 GB，脚本会自行清理旧产物与下载目录。

### 本次变更

- 运行时全部替换为 x86_64：Electron 44.7.0、Node 24.21.0、Python 3.12.14（含 numpy / pandas / lxml / Pillow 等 Office 依赖）；
- 8 个平台包换成同版本 `*-darwin-x64`，补 `node-pty` 的 darwin-x64 prebuild；
- 保留 `app.asar` 并重写 `ElectronAsarIntegrity`（与实际归档一致，启动时校验）；
- 解包布局与官方一致：`app.asar.unpacked` 1,616 个文件；整包 0 个 arm64 二进制；
- hardened runtime 签名，沿用原版 entitlements（JIT / 可执行内存 / 库校验 / 麦克风）；
- 删除 `app-update.yml` 关闭自动更新（避免被官方 feed 拉回 arm64）；
- `runtime.json` 的 `arch` 改为 `x64`。

### 附件

- `deepseek-harness-0.2.2-rc.1-mac-x64.dmg` — Intel（x64）安装包，428 MB（448,895,877 字节）

### 已知限制

- **ad-hoc 签名、无公证**：本机可直接运行；换机器或经网盘下载会被 Gatekeeper 拦，按上面的步骤放行；
- **无自动更新**：每次官方发新版需重新移植，不能直接升级（会被替换成 arm64）；
- **仅 Intel**：Apple Silicon 上需经 Rosetta 运行，建议直接用官方原版。

---

完整变更、构建流程与校验脚本见仓库中的 `README.md`、`RELEASE-CHECKLIST.md` 与 `triage.sh`。
