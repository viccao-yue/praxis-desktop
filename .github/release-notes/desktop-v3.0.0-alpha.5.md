# 开物Praxis Desktop 3.0.0-alpha.5

本次修复 Windows 首次进入时插件依赖更新失败，并默认预装语音输入。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- Windows Profile 根依赖补上 **`resolve.exports@2.0.4`**（与 `js-yaml` / `@deepseek-ai/cosmokit` 同类），避免 NSIS 拷贝后 `dsh-app-boot` 报 `ERR_MODULE_NOT_FOUND`，导致「插件依赖更新失败 / 无法进入」。
- 默认 Profile 预装 **`@bittersmilezzz/dsh-asr-voice` 0.4.7**（会话输入框麦克风；浏览器 Web Speech 不可用时可配置云端 ASR）。
- 默认 Profile 保留邮件、Playwright 浏览器工具等既有社区插件。

## 验证

- 源码侧覆盖 Desktop 包边界、Windows 安装包根依赖校验与相关单测。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.0-alpha.5-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.0-alpha.5-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.0-alpha.5-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

当前产品仍为 Alpha。升级前请备份本地配置和数据。
