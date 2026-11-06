# 开物Praxis Desktop 3.0.0-alpha.7

修复 Windows 安装向导与应用仍显示旧版「W」图标的问题，统一为开物品牌开关标。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- 更新 Windows / 跨平台应用图标源与 NSIS `installerIcon` / `uninstallerIcon`（`build/app-icon.png`、`build/app-icon.ico`）。
- 托盘矢量与衍生位图改为开物开关简标（不再使用 W/鲸鱼轮廓）。
- 承接 alpha.6：默认预装 `dsh-free-search`；不再默认预装 `dsh-email`。

## 验证

- 本地已按仓库脚本重新生成 ICO / Mac inset / tray 位图。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.0-alpha.7-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.0-alpha.7-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.0-alpha.7-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

当前产品仍为 Alpha。升级前请备份本地配置和数据。
