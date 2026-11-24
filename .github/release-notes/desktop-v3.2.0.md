# 开物Praxis Desktop 3.2.0

在正式版 `3.0.4` 基线上修复企业/个人首次装载插件时，桌面端无终端确认导致依赖重建失败的问题。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- 内置 pnpm 调用增加 `--config.confirmModulesPurge=false`，避免无 TTY 时出现 `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY`。
- 企业插件组合安装同样传入该配置，并在无交互环境设置 `CI=true`。
- 失败诊断文案补充可操作的现场处理说明。
- 版本号推进到 `3.2.0`。

## 验证

- 单测覆盖无 TTY 清理依赖目录失败的诊断文案，以及 pnpm 固定参数含 `confirmModulesPurge=false`。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收；请以本机企业登录与个人工作区首次进入为准。

## 下载与升级

- Windows x64：`kaiwu-3.2.0-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.2.0-arm64.dmg`。
- macOS Intel：`kaiwu-3.2.0-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

升级前请备份本地配置和数据。若旧版企业登录出现「插件依赖更新失败 / NO_TTY」，请改用本版安装包覆盖安装。
