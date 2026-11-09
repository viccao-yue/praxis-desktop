# 开物Praxis Desktop 3.0.1

修复 Windows 上「设置 → 企业账号 → 连接企业」点了无反应的回归。继续使用官方 DeepSeek Harness **0.2.1-rc.2**。

## 本包变更

- Profile 根目录物化时，保留 `企业连接` 包内嵌套的身份与协作插件；此前 Windows 安装包会把这两层丢掉，设置页仍显示「企业插件已安装」，但壳层判定插件不可用，按钮点击被拦下。
- 版本号推进到 `3.0.1`；其余个人默认能力与 `3.0.0` 一致。

## 验证

- 源码侧覆盖 Profile 物化单测：根目录下的企业连接包仍带有嵌套身份与协作插件。
- 本次版本通过标签触发重新构建；发行工作流还会核对版本、来源提交、随包运行时、企业插件来源及附件 SHA-256。自动检查不代表各平台全部真实交互均已验收。

## 下载与升级

- Windows x64：`kaiwu-3.0.1-x64-Setup.exe`。
- macOS Apple Silicon：`kaiwu-3.0.1-arm64.dmg`。
- macOS Intel：`kaiwu-3.0.1-x64.dmg`。
- 企业连接另提供独立归档；基础包内为 optional 附带，个人模式不启用企业身份与协作。
- 附件名称带构建平台前缀；下载后可依据 `SHA256SUMS` 核对完整性。本次 macOS DMG 未签名。

Desktop 与 Web 的 DSH Host、Client 和 SDK npm 包统一为 `0.2.1-rc.2`。Intel 的 Node、pnpm、Python、Office 资源及预编译工具仍来自单独校验的官方 `0.2.1-rc.1` Intel 归档。

升级前请备份本地配置和数据。若已装 `3.0.0` 的 Windows 客户端出现「连接企业」点不动，请改用本版安装包覆盖安装。
