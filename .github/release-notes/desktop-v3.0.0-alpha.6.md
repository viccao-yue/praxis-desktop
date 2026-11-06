# 开物Praxis Desktop 3.0.0-alpha.6

默认 Profile 调整社区插件：预装联网搜索，移除默认邮件 `dsh-email`。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- 默认 Profile 预装 **`dsh-free-search` 0.9.31**（免费联网搜索工具；个人区与企业区同一清单）。
- **不再默认预装 `dsh-email`**（设置里纸飞机图标「邮件」）。需要邮件时请显式安装 **`@lucagiftzek/dsh-mail`**（设置里齿轮图标「邮件」）。
- 打包期可选对已安装的 `@lucagiftzek/dsh-mail` 叠中文与按钮对比度补丁（未安装时跳过）。
- 保留语音输入 `@bittersmilezzz/dsh-asr-voice`，以及 Windows Profile 根依赖 `resolve.exports` 修复。

## 验证

- 源码侧覆盖 Desktop 包边界、运行时准备补丁与相关校验。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.0-alpha.6-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.0-alpha.6-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.0-alpha.6-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

当前产品仍为 Alpha。升级前请备份本地配置和数据。
