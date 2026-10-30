# 开物Praxis Desktop 3.0.0-alpha.4

本次为默认 Profile 对齐版本：个人区与企业区共用同一套社区默认插件，并补上邮件设置入口。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- 默认 Profile 预装 **`dsh-email` 0.19.0**（设置 → 邮件）；侧栏不保留独立「邮件」入口，与现有 Praxis 原生页签补丁一致。
- 默认 Profile 保留 **`dsh-playwright-browser` 0.1.3**（本机 browser_* 工具）。
- Remotion 运行记录收进任务状态行；邮件 / Remotion 设置侧栏图标与其它第三方设置项区分。
- 连接器管理默认预置并启用远程 MCP **LibTV**（个人区与企业区共用种子；未填令牌时提示配置后再用）。

## 验证

- 源码侧覆盖 Desktop 包边界、运行时准备补丁与连接器种子检查。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.0-alpha.4-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.0-alpha.4-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.0-alpha.4-x64.dmg`。
- 企业连接另提供独立 `workdsh-enterprise-connection` 归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

当前产品仍为 Alpha。升级前请备份本地配置和数据。

开源上游参考：[github.com/techflag/workdsh](https://github.com/techflag/workdsh)
