# scripts/praxis — 开物 Praxis / kaiwu 品牌覆盖层

本目录是 **在官方 WorkDSH / DSH 之上的品牌与体验覆盖**。升级上游时：先合入新版本，再按下方清单核对，避免被上游改回 `WorkDSH` 字样或丢失 Praxis 补丁。

目标分工：

| 对外 | 对内（可暂留） |
| --- | --- |
| 产品名 / 可执行文件 / 安装包：`kaiwu` | npm 包名：`workdsh-*` |
| 窗口与菜单显示名：`开物Praxis` | 资源目录：`workdsh-runtime/` |
| 连接页协议：`praxis://` | 环境变量：`WORKDSH_*` |
| Profile 目录名：`profiles/kaiwu` | Yarn workspace：`dsh-plugin-desktop` |

---

## 升级上游时的核对清单

合入新的 WorkDSH / Desktop / DSH 版本后，按项检查；被冲掉的改动按本表恢复。

### A. 打包身份（安装后别人一眼能看到）

文件：`apps/desktop/package.json` → `build`

| 字段 | 应保持为 |
| --- | --- |
| `appId` | `io.kaiwu.desktop` |
| `productName` | `开物Praxis`（DMG / 应用程序包显示名 → `开物Praxis.app`） |
| `executableName` | `kaiwu`（二进制仍为 `Contents/MacOS/kaiwu`、`kaiwu.exe`） |
| `mac.extendInfo.CFBundleDisplayName` / `CFBundleName` | `开物Praxis`（Dock / 访达显示名） |
| `nsis.shortcutName` | `开物Praxis` |
| `mac.artifactName` | `kaiwu-${version}-${arch}.${ext}` |
| `win.artifactName` / `nsis.artifactName` | `kaiwu-...` |
| `repository.url` | `https://github.com/viccao-yue/praxis-desktop.git`（本 fork，勿指回 techflag/workdsh） |

产物应为：`开物Praxis.app` / `kaiwu.exe` / `kaiwu-*-Setup.exe` / `kaiwu-*.dmg` 等，**不要**再出现 `WorkDSH.app` / `WorkDSH.exe`。

相关脚本与测试若硬编码了旧 `.app` 名，改到 `开物Praxis.app`（`verify-mac-*.ts`、`accept-*.mjs` 等）；可执行文件名仍为 `kaiwu`。

### B. 运行时显示与用户目录

文件：`apps/desktop/src/workdsh-main.ts`、`apps/desktop/src/command-cli.ts`

| 项 | 应保持为 |
| --- | --- |
| `app.setName(...)` | `开物Praxis` |
| 窗口默认 `title` | `开物Praxis` |
| 标题清洗 | 将 `WorkDSH` / `kaiwu` / `workdsh` 显示为 `开物Praxis` |
| 连接导航协议 | `praxis:`（含返回入口 `praxis://entry`） |
| 默认 userData（无 `WORKDSH_DESKTOP_USER_DATA` 时） | macOS：`~/Library/Application Support/kaiwu`；Windows：`%APPDATA%/kaiwu` |
| `PROFILE_NAME` / 物化 Profile | `kaiwu`（与 `local-runtime` 的 `profiles/kaiwu` 一致） |
| 打包 Profile 目录 | `workdsh-runtime/profiles/kaiwu`（`BUNDLED_PROFILE_NAME`） |

注意：改 userData / `appId` 后，旧 `WorkDSH` 数据目录不会自动迁移；这是有意为之。

### C. 连接页（登录壳）

| 文件 | 要点 |
| --- | --- |
| `apps/desktop/src/connection-entry.ts` | 品牌文案「开物成务 / 开物Praxis」；链接与 CSP 使用 `praxis://` / `form-action praxis:` |
| `apps/desktop/src/connection-ui/shell-css.ts` | 员工端品牌壳样式 |
| `apps/desktop/src/connection-brand-logo.ts` | 读取 `build/connection-ui/praxis-wordmark.png` |
| `apps/desktop/src/connection-preload.ts` | 企业登录 IPC；空账号/空密码校验 |
| `apps/desktop/package.json` → `build.files` | 必须包含 `build/connection-ui/praxis-wordmark.png`，否则打包连接页会崩 |

### D. prepare 阶段 Praxis 补丁（装进 Profile 的官方 UI）

`apps/desktop/scripts/prepare-workdsh-runtime.mjs` 在 Profile 装好后调用：

| 文件 | 作用 |
| --- | --- |
| `patch-account-menu.mjs` | 设置菜单：去掉联系我们/登录；未登录显示「设置」并打开设置 |
| `patch-signin-waiting.mjs` | 去掉「开始使用 / 等待登录」弹窗；跳过强制登录引导 |
| `patch-welcome-notice.mjs` | 去掉官方「预览版说明」首屏弹窗 |
| `patch-sidebar-icons.mjs` | 左侧栏插件、自动化任务图标 |
| `patch-skillhub-plaza.mjs` | 插件广场改为侧栏页，去掉重复技能页 |
| `patch-plugin-display-names.mjs` | 插件管理 UI 去掉技术前缀 `workdsh-` |
| `AccountMenu.tsx` | 设置菜单参考实现，**不参与打包** |

上游若更新了对应官方 client 文件，补丁可能对不上：以各脚本内的 marker / 失败报错为准，按新字节重写补丁，**不要删掉调用**。

### E. 产品边界（勿在升级时带回）

- 企业连接 `workdsh-enterprise-connection` 可作为 optionalDependency 打进安装包，便于「插件」里默认可见；**不要**把它写进个人 `dsh.profile.bundles`，也不要默认启用身份/协作。
- 企业登录仍须成员认证；个人模式不得自动激活协作。
- 个人默认可保留非企业的官方 bundle（例如 `@deepseek-ai/dsh-experimental-auto-review`），见 `apps/desktop/scripts/workdsh-package-boundary.mjs` 的 `PERSONAL_DEFAULT_EXTRA_BUNDLES`。
- 社区默认插件钉在同文件的 `CATALOG_PACKAGES`（含 mineru / `@liustack/modsearch` / video-lens / video-studio 等）；侧栏 Git/Diff 默认关闭见 `apps/desktop/scripts/praxis-default-sidebar.patch.yml`。
- LibTV CLI 以内置技能 `libtv-skill` 交付（源：https://github.com/libtv-labs/libtv-skills），需配置 `LIBTV_ACCESS_KEY`；不预装旗舰套件其它物料。
- 默认本机端口为 `15200`（`apps/desktop/src/runtime-port.ts`）。仍记录官方默认 `3080` 的旧工作区会一次性迁到 `15200`，避免与官方 DSH 抢端口；其他已有端口记录仍保留。
- IM 机器人默认隐藏侧栏入口（`integrations/dsh-im/sidebar-settings.json` → `hide`），入口仍在设置中。

### F. 刻意未改（升级时一般不用动）

这些仍可含 `workdsh`，以免大范围改依赖图：

- 包名：`workdsh-plugin-*`、`workdsh-provider-*`、`workdsh-contracts` 等
- 资源路径：`workdsh-runtime/`、`workdsh-config.json`
- 环境变量：`WORKDSH_DESKTOP_USER_DATA`、`WORKDSH_DEPLOYMENT_CONFIG`、`WORKDSH_BUNDLED_PROFILE` 等
- workspace 名：`dsh-plugin-desktop`（根 `package.json` / `scripts/verify-layout.mjs` 有约束）

若以后要连这些也改成 kaiwu，单独做一轮迁移，不要和 DSH 版本升级混在同一提交里。

---

## 建议升级步骤

1. 合入上游（或更新 `upstream.json` 锁定的官方 DSH / 归档）。
2. 跑 `corepack yarn check:desktop-dsh-alignment` 与 Desktop / Web 对齐门禁。
3. 对照 **A–E** 扫一遍 diff：搜索 `WorkDSH`、`techflag/workdsh`、`kaiwu:`（旧协议）、`profiles/workdsh`。
4. `corepack yarn workspace dsh-plugin-desktop prepare:workdsh-runtime`：确认 Praxis 五个 patch 都成功。
5. 相关单测：`connection-*`、`verify-mac-*`、`verify-win-*`、`verify-electron-fuses`、`verify-profile-release`。
6. 有条件再做一次打包安装，确认产物文件名是 `kaiwu*`，连接页 Logo 正常。

---

## 相关提交（本 fork 品牌线）

便于在 `praxis-desktop` 上溯源（以实际 Git 历史为准）：

- 连接页员工端品牌壳与个人 prepare 刷新
- Profile 路径对齐 `kaiwu`、`praxis://`、撤回个人预装企业连接
- CI：可执行文件名与 workbenches `source-directory` 引用修复
- 打包产品身份 `WorkDSH` → `kaiwu`
