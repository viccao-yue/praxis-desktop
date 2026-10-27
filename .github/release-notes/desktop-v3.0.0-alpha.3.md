# 开物Praxis Desktop 3.0.0-alpha.3

本次为产品默认项与常青云内置技能重建版本，基于 `main` 最新提交。继续使用官方 DeepSeek Harness **0.2.1-rc.2**，保留完整原生对话与工作台并排布局。

## 本包变更

- 界面显示名统一为 **开物Praxis**（macOS `CFBundleDisplayName` / Windows 快捷方式）。
- 默认隐藏「预览版说明」首次弹窗。
- 新工作区默认本机端口改为 **15200**（已有工作区仍保留原端口）。
- 默认隐藏 IM 机器人侧栏入口（设置页仍可管理）。
- 基础安装包以 optional 方式附带 **企业连接** 插件归档；个人模式不激活企业身份 / 协作包。
- 内置并默认配备常青云技能：`kubercon-deploy`、`kubercon-kubectl`（常青云容器运维顾问可冻结挂载）。

## 验证

- 源码侧已覆盖本地运行时端口、IM 侧栏隐藏、企业连接 inventory 与技能内置生成检查。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.0-alpha.3-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.0-alpha.3-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.0-alpha.3-x64.dmg`。
- 企业连接另提供独立 `workdsh-enterprise-connection` 归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

当前产品仍为 Alpha。升级前请备份本地配置和数据。

开源上游参考：[github.com/techflag/workdsh](https://github.com/techflag/workdsh)
