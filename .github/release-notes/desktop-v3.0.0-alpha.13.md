# 开物Praxis Desktop 3.0.0-alpha.13

本次收窄 Profile 私有依赖嵌套：只保留一层，避免打包时 Node 堆溢出和 Windows 准备超时。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- Profile 根依赖物化仍为需要隔离的包（例如 `signal-exit` 3.x）保留各自版本，但不再递归拷贝整棵私有依赖树。
- 修复 `desktop-v3.0.0-alpha.12` 在 macOS electron-builder 堆内存溢出、Windows 准备 Profile 超过 60 分钟被取消的问题。

## 验证

- 源码侧覆盖 Profile 模块物化单测（含仅一层嵌套）。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.0-alpha.13-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.0-alpha.13-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.0-alpha.13-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

当前产品仍为 Alpha。升级前请备份本地配置和数据。
