# 开物Praxis Desktop 3.0.4

默认记忆能力从 `dsh-living-memory` 切换为 `dsh-mnemon`，覆盖安装时会自动迁移；并更新数字员工默认人物头像。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- 个人与企业默认 Profile 启用 `dsh-mnemon@0.5.47`（分层记忆与技能进化），不再默认安装 `dsh-living-memory`。
- 覆盖升级已有 Home 时：自动卸下 living-memory、启用 mnemon；个人区与企业区策略一致。用户自行安装的其他插件保留。
- 六类数字员工默认头像更换为人物形象资源。
- 版本号推进到 `3.0.4`。

## 验证

- 源码侧补充 Profile 覆盖升级迁移单测（living-memory → mnemon）。
- 运行时准备校验默认组成包含 `mnemon`，且不得再出现 `living-memory`。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收；请以本机首次进入与记忆页为准。

## 下载与升级

- Windows x64：`kaiwu-3.0.4-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.4-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.4-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

升级前请备份本地配置和数据。升级后记忆页应进入 mnemon「记忆系统」；原 living-memory 本地库不会自动迁移到 mnemon。
