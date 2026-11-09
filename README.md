# Intel（x64）版移植说明

官方 `deepseek-harness-0.2.2-rc.1-mac-arm64.dmg` 只有 arm64。这个目录里的
`deepseek-harness-0.2.2-rc.1-mac-x64.dmg` 是把同一份应用改造成 Intel Mac 可运行、可安装的版本。

产物：

| 文件 | 说明 |
| --- | --- |
| `dist/deepseek-harness-0.2.2-rc.1-mac-x64.dmg` | 可双击安装的 DMG（约 431 MB，卷名与官方一致） |
| `dist/DeepSeek Harness.app` | 同内容的未打包 App，便于 `verify.sh` 直接检查 |
| `/Applications/DeepSeek Harness.app` | 已安装好的同版本应用 |

> Release 附件是本地构建产物；也可以按下方流程自行构建，并用 `verify.sh` / `triage.sh` 校验。

发版操作清单：[RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md)（准备 → 构建 → 校验 → 抽检 → 归档 → 回滚）
发布页更新日志：[RELEASE-NOTES.md](RELEASE-NOTES.md)（安装说明、变更、产物哈希、已知限制）


## 快速开始

三个脚本覆盖「构建 → 体检 → 排坑」，都在本目录下执行：

```bash
# 使用者：下载发行包、校验大小与 sha256、清理 quarantine 并打开
./install.sh
MIRRORS="https://ghproxy.net" ./install.sh   # GitHub 不可达时走镜像

# 官方发新版后，一条命令产出 Intel 安装包
./port.sh ~/Downloads/deepseek-harness-<版本>-mac-arm64.dmg
#   --out <目录>      产物目录（默认 ./dist）
#   --keep            保留中间产物，便于排查
#   --no-dmg          只产出 .app
#   --install         额外装到 /Applications（目标 App 必须先退出）
#   --registry/--pip-index  换镜像源

# 对任意一份产物做体检（只读）
./verify.sh "/Applications/DeepSeek Harness.app"
./verify.sh --quick "/path/to/DeepSeek Harness.app"   # 跳过 3 万文件的全量架构扫描

# 第 8 节「已知坑」的逐条排查（只读，PASS/WARN/FAIL；全绿退出码 0，有 FAIL 退出码 1）
./triage.sh "/Applications/DeepSeek Harness.app"
REF_APP="/path/to/旧版.app" ./triage.sh "dist/DeepSeek Harness.app"   # 额外对比解包数量，同样返回 0/1
```

跑起来是这样（退出码 0）：

```text
$ ./triage.sh "/Applications/DeepSeek Harness.app"
8.7 解包数量
  unpacked 文件数：1616 / asar 条目数：25422
结果
  全部通过（警告 0 项）          # 退出码 0
```

失败时（退出码 1）：

```text
$ ./triage.sh "/Applications/DeepSeek Harness.app"
8.4 签名封印
  ✗ codesign 校验失败
结果
  失败 1 项（警告 0 项）          # 退出码 1
```

> 脚本已在 `0.2.2-rc.1` 上完整跑通：解包 → 下载 → 替换 → 预编译 → 签名 → 自检 → 打包 DMG，
> 产物通过 `verify.sh` 全量检查（唯一警告是 ad-hoc 签名本身）。

构建前后有两道磁盘保护，日志只占一行：

```text
✓ 可用空间 7654 MB                                  # 继续构建（最终退出码 0）
! 可用空间 2140 MB，低于 3000 MB → ✓ 清理后 5120 MB  # 自动删旧产物，继续（退出码 0）
✗ 清理后仍只有 2600 MB，请手动清理或用 --out 换卷     # die → 退出码 1
```

打包前还会删掉下载目录：`✓ 已删除下载目录，释放空间`。

- **磁盘**：开始前可用空间低于 3 GB 时先删掉上次产物与中间目录（仍不足则报错退出），打包前再释放约 0.7 GB 的下载目录。

`port.sh` 会自动从包里读取版本号、Electron/Node/Python 版本和 8 个平台包的精确版本，
再从镜像下载对应的 x64 组件，因此不需要每次手工改脚本。它做这几件事：

1. 挂载官方 DMG，解包 `app.asar`；
2. 下载 x64 的 Electron / Node / Python，并从 `runtime.json` 读出 Office 依赖的精确版本重装；
3. 把 `*-darwin-arm64` 平台包换成同版本 `*-darwin-x64`，补 `node-pty` 的 x64 prebuild；
4. 移除 arm64 包、`app-update.yml`，修正 `runtime.json` 的 `arch`；
5. **重新打包 `app.asar`**：解包目录不是手写清单，而是**从官方包的 `app.asar.unpacked` 推导**（`darwin-arm64 → darwin-x64`），再补上 8 个 x64 平台包的根目录和 `node-pty` 整包；嵌套在别的包里的 `node_modules` 副本保持打包；`.node` / `.dylib` 兜底解包，其余保持打包；
6. **写回 `ElectronAsarIntegrity`**：`sha256(asar 头部 16..16+jsonSize)`，与实际归档一致（Electron 启动时会校验）；
7. 预编译 Python 字节码（否则运行时写入 `.pyc` 会破坏签名封印），用 C 重新编译 `link-entry`；
8. **hardened runtime 签名**：沿用原版包的 entitlements（JIT / 库校验 / 麦克风 / 可执行内存），`--deep --options runtime`；读不到 entitlements 时自动退回普通 ad-hoc；
9. 调 `verify.sh` 自检，通过后打包成同款 DMG。

**退出码**：构建成功为 `0`；参数错误为 `2`（例如未知选项）；依赖缺失、磁盘不足、
官方包结构变化、自检不通过等失败一律为 `1`（`-h` 帮助为 `0`）。`--no-dmg` 只影响是否打包，成功仍是 `0`。

如果不想要 hardened runtime，加 `--no-hardened`。

`verify.sh` 检查：主程序/Electron/Node/Python 架构、全包 arm64 残留、打包形态（`app.asar` 或 `app/`）、
`app.asar.unpacked` 里的原生模块数量、**`ElectronAsarIntegrity` 与实际 asar 是否一致**、
更新开关、`runtime.json` 架构、Node/Python 能否运行、Office 依赖能否导入、签名有效性与 hardened runtime，
并把 Gatekeeper 结论标成警告而不是失败。

> 注意：挂载 DMG 和创建 DMG 都需要普通终端权限。如果在受限沙箱里运行，
> 可能会在 `hdiutil create` 这一步失败——用 `--no-dmg` 先产出 .app 即可。

## 安装与首次启动

把 DMG 里的 App 拖进「应用程序」后，如果它来自别的机器或网盘，先去掉隔离属性：

```bash
xattr -dr com.apple.quarantine "/Applications/DeepSeek Harness.app"
```

macOS 15 起右键「打开」不再能绕过 Gatekeeper，正确路径是：双击 App 被拦 →
**系统设置 → 隐私与安全性 → 仍要打开**。首次启动按提示允许文档 / 下载 / 麦克风权限。
完整步骤见 [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md) 第 5 节。

## 本轮实测（0.2.2-rc.1，2026-11-08 ~ 09）

| 指标 | 结果 |
| --- | --- |
| `app.asar` | 154 MB；`app.asar.unpacked` **1,616** 个文件（含 6 个 `.node`） |
| 解包布局 | 与参考版**逐文件一致**：1,616 = 1,616，缺失 0，多出 0 |
| 与官方文件清单对比 | 两边各 25,422 条，**非平台包差异 0 条**，仅 892 条 `darwin-arm64 → darwin-x64` 重命名 |
| 关键文件 | `main.js` / `package.json` / `dsh/package.json` 等 sha256 与官方一致 |
| 完整性校验 | `ElectronAsarIntegrity` 声明值 = 实际 asar 头 sha256 |
| 签名 | ad-hoc + hardened runtime，4 个 entitlements（JIT、可执行内存、库校验、麦克风） |
| 原生模块 | 用构建出的 Electron 以 node 模式加载 `sharp` / `koffi` / `node-pty` / `sherpa-onnx` / `require-builtin` 全部成功 |
| DMG | 431 MB（重打后 424 MB），挂载后 `verify.sh` 通过 |
| 磁盘预检 | 判定：可用空间 **< 3000 MB** → 删 `dist` 旧产物与 `work` 中间目录；复查仍低于 3000 MB 则 `die`（退出码 1）。实测 2723 MB 触发，清理后 3737 MB，构建继续并成功 |
| 下载重试 | 判定：`curl` 退出码非 0（如 56 写失败、28 超时）→ 单个 URL `--retry 3`，仍失败再回退 GitHub（`--retry 2`），两者皆失败则 `die`（退出码 1）。实测首次遇 56 + 回退超时，CDN 恢复后重跑成功 |
| `--no-dmg` 退出码 | 实跑完整构建，日志末尾 `EXIT_CODE=0`，只产出 `.app`、不生成 DMG |

> 解包布局以官方包为基准自动推导，所以官方发新版后不需要手工维护目录清单。
> 解包文件数与参考版**完全一致（1,616）**：嵌套 `node_modules` 里的副本（例如
> `dsh-session-log-export/node_modules/fflate`）统一保持打包，这一条是通用规则，不是写死某条路径。

## 官方包里原本有哪些 arm64

| 组件 | 原架构 | 处理方式 |
| --- | --- | --- |
| Electron 44.7.0（主程序 + Framework + 4 个 Helper） | arm64 | 换成 electron-v44.7.0-darwin-x64（npmmirror 镜像） |
| Node.js 24.21.0（`runtime/primary-runtime/dependencies/node`） | arm64 | 换成 node-v24.21.0-darwin-x64 |
| CPython 3.12.14 + numpy 2.3.5 / pandas 3.0.1 / lxml 6.1.3 / Pillow 12.3.0 等 | arm64 | 换成 cpython-3.12.14+20260929-x86_64-apple-darwin，并按 `runtime.json` 里锁定的版本重装 x64 wheel |
| `@img/sharp-darwin-arm64` + `sharp-libvips` 0.35.5 / 1.3.4 | arm64 | 换成 `*-darwin-x64` 同名同版本 |
| `@koromix/koffi-darwin-arm64` 3.1.1 | arm64 | 换成 `koffi-darwin-x64@3.1.1` |
| `@vscode/ripgrep-darwin-arm64` 1.18.0 | arm64 | 换成 `ripgrep-darwin-x64@1.18.0` |
| `node-addon-require-builtin-darwin-arm64` 0.1.9 | arm64 | 换成 `-darwin-x64@0.1.9` |
| `@deepseek-ai/node-addon-system-darwin-arm64` 0.1.2 | arm64 | 换成 `-darwin-x64@0.1.2` |
| `sherpa-onnx-darwin-arm64` 1.13.8 | arm64 | 换成 `-darwin-x64@1.13.8` |
| `node-pty` 1.2.0-beta.15 的 `prebuilds/darwin-arm64` | arm64 | 补上 `prebuilds/darwin-x64/pty.node` |
| `runtime/cli/link-entry`（安装 `/usr/local/bin/dsh` 用的小工具） | arm64 | 用 C 重写等价实现并编译为 x64（见 `tools/link-entry.c`） |

改造后整包 **0 个 arm64 Mach-O**，`codesign -v --deep --strict` 通过（ad-hoc 签名）。

## 另外改了三处

1. **保留 `app.asar`，并重写完整性校验**
   解包 → 替换 x64 组件 → 用 `@electron/asar` 重新打包；`.node` / `.dylib` 与原生目录走
   `app.asar.unpacked`，解包集合从官方包的 `app.asar.unpacked` 推导。
   打包后把 `sha256(asar 头 16..16+jsonSize)` 写进 `Info.plist` 的 `ElectronAsarIntegrity`，
   Electron 启动时会校验；不写或写错会直接拒绝启动。

2. **关闭自动更新**
   删除 `Contents/Resources/app-update.yml`。该文件存在时，`electron-updater` 会从官方
   `mac-arm64` feed 拉取更新；对 Intel 版来说那等于把自己换回不能运行的 arm64 包。
   代码里的开关条件是 `existsSync(resourcesPath + "/app-update.yml")`，删掉即彻底停用。

3. **`runtime.json` 的 `arch` 改为 `x64`**
   `dsh-tool-workspace-dependencies` 会校验 `manifest.arch === process.arch`，不改会直接报
   “primary runtime: incompatible platform or architecture”。

## 复现步骤（下次官方发版时照做）

见 [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md)，核心只有一条命令：

```bash
./port.sh ~/Downloads/deepseek-harness-<版本>-mac-arm64.dmg
```

## 已知限制

- **非官方改造**：没有 Apple 开发者签名和公证，只能本机 ad-hoc 运行；通过网盘/邮件传播会被 Gatekeeper 拦截。
- **无自动更新**：每次官方发新版，需要按上面的步骤重新移植（不能直接升级，否则会被替换成 arm64）。
- **仅 Intel**：这一份是 thin x86_64；Apple Silicon 请用官方原版。
- 改造只涉及运行时二进制，业务代码（`app/`、`runtime/cli`、`office-skills`）与官方完全一致。
- 语音识别（sherpa-onnx）、LibreOffice 导出、ripgrep 搜索、终端（node-pty）都已换成 x64 版本；
  Python 侧已验证 `numpy / pandas / docx / pptx / openpyxl / PIL / lxml` 可导入。
