# 开物Praxis Desktop 3.5.0

在 `3.2.0`（默认随包企业连接）基线上，将 Desktop / Web 官方 DeepSeek Harness 升级到 **0.2.2-rc.5**，并保留完整安装包内置企业连接的交付方式。

## 本包变更

- Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.2-rc.5`。
- 适配 strip-only Node 与 agent-team 相关配置；无 TTY 环境下的插件安装修复随基线保留。
- 基础安装包已内置企业连接：客户只需安装 Setup/DMG，入口即可直接「企业登录」；个人模式仍不启用企业身份与协作。
- 版本号推进到 `3.5.0`。

## 验证

- 源码侧保留随包企业连接解析与 lifecycle 单测，以及 `0.2.2-rc.5` 对齐门禁。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收；请以本机首次进入、企业登录与个人工作区为准。

## 下载与升级

- Windows x64：`kaiwu-3.5.0-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.5.0-arm64.dmg`。
- macOS Intel：`kaiwu-3.5.0-x64.dmg`。
- 基础安装包已内置企业连接；Release 中的企业连接独立归档仅供应急补装或单独升级，不是常规交付步骤。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.2-rc.5`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

升级前请备份本地配置和数据。
