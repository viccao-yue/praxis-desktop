# 开物Praxis Desktop 3.0.2

修复 Windows 退出后本机进程易残留，以及 MinerU 拖入文档误报「请先打开一个会话」。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- Windows 退出时：兼容 PowerShell 单进程查询结果，优先对根进程 `taskkill /T` 清理，放宽确认时限；清理未完全确认时仍会退出，避免半死进程占住下次启动。
- MinerU：拖入文档改为按主视图会话判定，与回形针附件一致；启动与预制 Profile 会自动打上该补丁。
- 版本号推进到 `3.0.2`；其余个人默认能力与 `3.0.1` 一致。

## 验证

- 源码侧覆盖 Windows 进程清理单测（含单进程 CIM JSON、根进程 `/T` 优先）与 MinerU 会话补丁单测。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收；Windows 退出残留请以实际退出与任务管理器抽查为准。

## 下载与升级

- Windows x64：`kaiwu-3.0.2-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.2-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.2-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

升级前请备份本地配置和数据。若 Windows 退出后仍有残留进程、或拖入文档仍提示先打开会话，请用本版覆盖安装后再验。
